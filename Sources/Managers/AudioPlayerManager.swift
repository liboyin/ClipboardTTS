// swiftlint:disable file_length
// AudioPlayerManager keeps the buffer-queue and main-queue confinement rules and their
// documentation in one cohesive file; splitting it would separate invariants from the code
// they describe.
import Foundation
import AVFoundation
/// Buffers streamed PCM, drives the playback engine, and publishes playback state to the menu bar.
///
/// Marked `@unchecked Sendable` because network callbacks schedule audio from the URLSession
/// delegate queue while the UI and Services flows drive it from the main queue; concurrent
/// scheduling entry is covered by `AudioPlayerManagerTests`. The pre-existing confinement rules:
/// - Buffer state (`pcmData`, `bufferedPCMFrameCount`, `audioFormat`, and the scheduling
///   generations) is read and written only on `bufferQueue`.
/// - The `@Published` properties, audio engine, `engineStarter`, `baseProgressOffset`, and the
///   progress timer are confined to the main queue.
/// - `playerNode` scheduling and control run on `bufferQueue` or the main queue, matching the
///   threading pattern this class has always used for `AVAudioPlayerNode`.
final class AudioPlayerManager: ObservableObject, @unchecked Sendable {
    static let defaultSampleRate = 24_000.0
    static let supportedSampleRateRange = 8_000.0...48_000.0
    private static let automaticPlaybackPrebufferDuration: TimeInterval = 0.1
    /// How often playback republishes its position while a stream plays.
    private static let progressTickInterval: TimeInterval = 0.1
    enum SampleRateUpdateResult: Equatable {
        case unchanged
        case updated
        case invalid
        case engineStartFailed
    }
    @Published var isPlaying = false
    @Published var playbackProgress: Double = 0.0
    @Published var bufferDuration: Double = 0.0
    @Published var hasAudio = false
    /// How the request feeding the current stream ended, or nil while that stream is still open.
    ///
    /// It is set only by `finishStream(streamGeneration:termination:)`, and cleared by `stop()`, so
    /// it always describes the session the buffered PCM belongs to rather than an earlier one.
    @Published private(set) var streamTermination: SpeechStreamTermination?
    @Published private(set) var sampleRate: Double = defaultSampleRate
    /// Why the requested PCM format cannot be used, or nil when the graph holds a usable format.
    @Published private var formatError: String?
    /// Why the most recent engine start failed, or nil once an engine start has succeeded since.
    ///
    /// Kept apart from `formatError` because the two recover differently: a format is fixed by
    /// choosing another rate, while a stopped engine is fixed by starting it again, which any later
    /// Play, automatic start, or new session attempts on its own.
    @Published private var engineStartError: String?
    @Published private(set) var hasValidSampleRateInput = true
    /// Whether the graph holds a supported PCM format. An engine that failed to start does not make
    /// it false: the format is still right, and the next start attempt can still play it.
    @Published private(set) var hasValidSampleRateConfiguration = true
    /// The audio failure shown to the user. A format failure wins, because no engine start can make
    /// an unusable format playable.
    var sampleRateError: String? {
        formatError ?? engineStartError
    }
    private static let unsupportedSampleRateMessage = "PCM sample rate must be a finite value from 8,000 to 48,000 Hz."
    private static let unconfigurableSampleRateMessage = "Couldn't configure the PCM sample rate. Try again."
    private static let engineStartFailureMessage = "Couldn't start audio playback. Try again."
    @Published var playbackRate: Float = 1.0 {
        didSet {
            timePitch.rate = playbackRate
        }
    }
    private var engine = AVAudioEngine()
    private var playerNode = AVAudioPlayerNode()
    private var timePitch = AVAudioUnitTimePitch()
    private var audioFormat: AVAudioFormat?
    // pcmData is written from the network delegate's background queue (scheduleAudio) and
    // read/cleared from the main thread (seek/stop). All access MUST
    // go through bufferQueue to avoid a data race.
    private let bufferQueue = DispatchQueue(label: "com.clipboardtts.audiobuffer")
    private var pcmData = (accumulated: Data(), unprocessed: Data())
    private var bufferedPCMFrameCount = 0
    private var baseProgressOffset: Double = 0.0
    private var scheduleGeneration: Int = 0
    private var automaticPlaybackGeneration: Int?
    private var automaticPlaybackSuppressedGeneration: Int?
    /// The stream whose playback stopped because its buffered PCM ran out while its request was
    /// still open, or nil when nothing is waiting on more PCM.
    ///
    /// It is what separates an underrun from the three other ways playback stops: a Pause the user
    /// asked for, a seek they chose, and the end of a request that has already terminated. Only an
    /// underrun is resumed by the PCM that arrives behind it, and only for the stream that stopped.
    private var underrunSuspendedGeneration: Int?
    private let scheduledBufferObserver: (AVAudioPCMBuffer) -> Void
    private let engineStarter: (AVAudioEngine) throws -> Void
    /// Defers the automatic-playback start; the action it is given crosses to the main queue.
    private let automaticPlaybackScheduler: (TimeInterval, @escaping @Sendable () -> Void) -> Void
    /// Reads the position the node has rendered, in frames of the active format, for one progress
    /// tick. It takes the node rather than capturing it so a caller can state a rendered position
    /// instead of depending on live audio output.
    private let renderedSampleTime: (AVAudioPlayerNode) -> AVAudioFramePosition?
    /// Schedules the repeating progress timer the manager built. Production adds it to the main run
    /// loop; a caller that keeps the timer instead can fire the manager's own callback where it
    /// wants a tick, rather than waiting the cadence out.
    private let progressTimerScheduler: (Timer) -> Void
    private let audioObservers: (processed: () -> Void, statePublished: () -> Void)
    private var progressTimer: Timer?
    /// Creates the audio graph. The buffer observer is notified after each buffer is passed to the node.
    /// The scheduler defers automatic playback after the first complete PCM frame. The rendered-sample-time
    /// reader supplies each progress tick its position, and the timer scheduler decides where the timer
    /// driving those ticks runs. The processing observer runs after the audio queue handles a
    /// packet or a terminal event, and the state observer runs after publication.
    init(sampleRate: Double = AudioPlayerManager.defaultSampleRate,
         scheduledBufferObserver: @escaping (AVAudioPCMBuffer) -> Void = { _ in },
         engineStarter: @escaping (AVAudioEngine) throws -> Void = { try $0.start() },
         automaticPlaybackScheduler: @escaping (TimeInterval, @escaping @Sendable () -> Void) -> Void = { delay, action in
             DispatchQueue.main.asyncAfter(
                 deadline: .now() + delay,
                 execute: action
             )
         },
         renderedSampleTimeReader: @escaping (AVAudioPlayerNode) -> AVAudioFramePosition? = { node in
             guard let nodeTime = node.lastRenderTime,
                   let playerTime = node.playerTime(forNodeTime: nodeTime) else { return nil }
             return playerTime.sampleTime
         },
         progressTimerScheduler: @escaping (Timer) -> Void = { timer in
             RunLoop.main.add(timer, forMode: .default)
         },
         audioDataProcessingObserver: @escaping () -> Void = {},
         audioStateObserver: @escaping () -> Void = {}) {
        self.scheduledBufferObserver = scheduledBufferObserver
        self.engineStarter = engineStarter
        self.automaticPlaybackScheduler = automaticPlaybackScheduler
        self.renderedSampleTime = renderedSampleTimeReader
        self.progressTimerScheduler = progressTimerScheduler
        self.audioObservers = (processed: audioDataProcessingObserver, statePublished: audioStateObserver)
        let hasValidInitialSampleRate = Self.isSupportedSampleRate(sampleRate)
        let initialSampleRate = hasValidInitialSampleRate ? sampleRate : Self.defaultSampleRate
        setupEngine(sampleRate: initialSampleRate)
        if !hasValidInitialSampleRate {
            hasValidSampleRateInput = false
            hasValidSampleRateConfiguration = false
            formatError = Self.unsupportedSampleRateMessage
        }
    }
    private func setupEngine(sampleRate: Double) {
        engine.attach(playerNode)
        engine.attach(timePitch)
        guard let standardFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            formatError = Self.unconfigurableSampleRateMessage
            return
        }
        self.sampleRate = sampleRate
        bufferQueue.sync {
            audioFormat = standardFormat
        }
        engine.connect(playerNode, to: timePitch, format: standardFormat)
        engine.connect(timePitch, to: engine.mainMixerNode, format: standardFormat)
        startEngineIfStopped()
    }

    /// Starts the engine when it is not running and publishes the outcome, on the main queue.
    ///
    /// Every start attempt goes through here or through `attemptEngineStart` paired with
    /// `publishEngineStart`, so a success always clears the failure an earlier attempt left
    /// behind. An engine already running counts as a success for the same reason: whoever started
    /// it resolved that failure.
    @discardableResult
    private func startEngineIfStopped() -> Bool {
        let started = attemptEngineStart()
        publishEngineStart(succeeded: started)
        return started
    }

    /// Starts the engine when it is not running, without publishing, and answers whether it runs.
    ///
    /// Separate from the publication so a caller holding `bufferQueue` can start the engine there
    /// and publish only after it has left the queue.
    private func attemptEngineStart() -> Bool {
        guard !engine.isRunning else { return true }
        do {
            try engineStarter(engine)
            return true
        } catch {
            return false
        }
    }

    private func publishEngineStart(succeeded: Bool) {
        engineStartError = succeeded ? nil : Self.engineStartFailureMessage
    }

    /// Starts a stopped engine for a new session, answering whether that session may begin.
    ///
    /// A session refused here would otherwise stay refused until something else happened to start
    /// the engine, with the menu offering a "Try again" that did nothing. Asking at the start of each
    /// session makes that retry real, and a failure is published so the user sees why nothing began.
    func prepareForNewStream() -> Bool {
        guard hasValidSampleRateConfiguration else { return false }
        return startEngineIfStopped()
    }
    /// Changes the PCM sample rate after clearing all audio that was decoded with the previous format.
    @discardableResult
    func setSampleRate(_ sampleRate: Double) -> SampleRateUpdateResult {
        guard Self.isSupportedSampleRate(sampleRate) else {
            hasValidSampleRateInput = false
            hasValidSampleRateConfiguration = false
            formatError = Self.unsupportedSampleRateMessage
            return .invalid
        }
        hasValidSampleRateInput = true
        guard changesAudioFormat(to: sampleRate) else {
            hasValidSampleRateConfiguration = true
            formatError = nil
            return startEngineIfStopped() ? .unchanged : .engineStartFailed
        }
        stop()
        engine.stop()
        engine.disconnectNodeOutput(playerNode)
        engine.disconnectNodeInput(timePitch)
        engine.disconnectNodeOutput(timePitch)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            hasValidSampleRateConfiguration = false
            formatError = Self.unconfigurableSampleRateMessage
            return .engineStartFailed
        }
        engine.connect(playerNode, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        bufferQueue.sync {
            audioFormat = format
        }
        self.sampleRate = sampleRate
        hasValidSampleRateConfiguration = true
        formatError = nil
        return startEngineIfStopped() ? .updated : .engineStartFailed
    }

    /// Returns whether applying `sampleRate` would replace the format the buffered PCM was decoded
    /// with, which is exactly when `setSampleRate` discards that PCM.
    ///
    /// The session owner asks before it applies a rate, because the request feeding that PCM has to
    /// end with it: a format change that cleared the buffer alone would leave its request streaming
    /// audio the player is now certain to drop. `setSampleRate` decides with this same answer, so
    /// the prediction and the change cannot disagree. Only the main queue writes `audioFormat`, so
    /// a caller that asks and then applies within one main-queue turn is told what it will do.
    func changesAudioFormat(to sampleRate: Double) -> Bool {
        guard Self.isSupportedSampleRate(sampleRate) else { return false }
        return bufferQueue.sync { audioFormat?.sampleRate } != sampleRate
    }

    /// Returns whether a PCM sample rate can be represented by the app's mono Int16 graph.
    static func isSupportedSampleRate(_ sampleRate: Double) -> Bool {
        sampleRate.isFinite && supportedSampleRateRange.contains(sampleRate)
    }

    /// Whether the current configuration can start a new PCM stream without misinterpreting its format.
    ///
    /// A stopped engine does not make it false: `prepareForNewStream()` starts the engine for the
    /// session that needs it, so a failed start can be retried by the next attempt to speak.
    var isReadyForNewStream: Bool {
        hasValidSampleRateConfiguration
    }

    func startNewStream() -> Int {
        stop()
        return bufferQueue.sync {
            scheduleGeneration += 1
            return scheduleGeneration
        }
    }

    func scheduleAudio(data: Data, streamGeneration: Int) {
        // Runs on the network delegate's background queue; serialize buffer access via bufferQueue.
        bufferQueue.async {
            defer { self.audioObservers.processed() }
            guard self.scheduleGeneration == streamGeneration else { return }
            guard let format = self.audioFormat else { return }

            self.pcmData.accumulated.append(data)
            self.pcmData.unprocessed.append(data)

            let bytesPerNetworkFrame = 2 // 16-bit PCM = 2 bytes per frame
            self.bufferedPCMFrameCount = self.pcmData.accumulated.count / bytesPerNetworkFrame
            let bufferedFrameCount = self.bufferedPCMFrameCount
            let frameCapacity = AVAudioFrameCount(self.pcmData.unprocessed.count / bytesPerNetworkFrame)
            guard frameCapacity > 0 else { return }

            let bytesToProcess = Int(frameCapacity) * bytesPerNetworkFrame
            let dataToProcess = self.pcmData.unprocessed.prefix(bytesToProcess)
            self.pcmData.unprocessed.removeFirst(bytesToProcess)

            guard let buffer = self.makePCMBuffer(from: dataToProcess, format: format, frameCapacity: frameCapacity) else { return }

            self.schedule(buffer)
            let shouldScheduleAutomaticPlayback = self.automaticPlaybackGeneration != streamGeneration
            if shouldScheduleAutomaticPlayback {
                self.automaticPlaybackGeneration = streamGeneration
                self.automaticPlaybackScheduler(Self.automaticPlaybackPrebufferDuration) { [weak self] in
                    guard let self else { return }
                    DispatchQueue.main.async {
                        self.startAutomaticPlayback(streamGeneration: streamGeneration)
                    }
                }
            }

            DispatchQueue.main.async {
                let stream = self.bufferQueue.sync { () -> (isCurrent: Bool, endsUnderrun: Bool) in
                    guard self.scheduleGeneration == streamGeneration else { return (false, false) }
                    let endsUnderrun = self.underrunSuspendedGeneration == streamGeneration
                    self.underrunSuspendedGeneration = nil
                    return (true, endsUnderrun)
                }
                guard stream.isCurrent else { return }
                self.bufferDuration = Double(bufferedFrameCount) / format.sampleRate
                self.hasAudio = true
                if stream.endsUnderrun { self.resumeAfterUnderrun() }
                self.audioObservers.statePublished()
            }
        }
    }

    /// Starts or resumes playback, replaying from zero when it sits at the end of the buffered PCM.
    ///
    /// Pressing Play during an underrun suspension always takes that replay path, because a stream
    /// suspends exactly where its published position reached the buffered end, and the seek it
    /// performs releases the suspension. Later PCM therefore extends the replay the user asked for
    /// rather than jumping playback back to where the buffer had run out.
    func play() {
        guard startEngineIfStopped() else { return }

        if playbackProgress >= bufferDuration && bufferDuration > 0 {
            seek(to: 0.0)
        }
        playerNode.play()

        isPlaying = true
        startProgressTimer()
    }

    func stop() {
        // Bump the generation and clear buffers first, then stop the node. bufferQueue is a serial
        // FIFO: any scheduleAudio block already queued runs before this sync block and may still call
        // playerNode.scheduleBuffer, but the following playerNode.stop() flushes that buffer. Blocks
        // queued after the bump fail the generation guard and drop. Reversing the order would let an
        // in-flight scheduleAudio schedule one buffer onto the node after it was stopped.
        bufferQueue.sync {
            scheduleGeneration += 1
            automaticPlaybackGeneration = nil
            automaticPlaybackSuppressedGeneration = nil
            underrunSuspendedGeneration = nil
            pcmData.accumulated.removeAll()
            pcmData.unprocessed.removeAll()
            bufferedPCMFrameCount = 0
        }
        playerNode.stop()
        baseProgressOffset = 0.0

        let updatePublishedState: @Sendable () -> Void = {
            self.isPlaying = false
            self.hasAudio = false
            self.bufferDuration = 0.0
            self.playbackProgress = 0.0
            self.streamTermination = nil
        }
        if Thread.isMainThread {
            updatePublishedState()
        } else {
            DispatchQueue.main.async(execute: updatePublishedState)
        }
        stopProgressTimer()
    }

    /// Moves playback to a buffered position, clamping requests outside the available PCM range.
    /// Seeking to the end stops playback but preserves the buffered data for replay.
    func seek(to progress: Double) {
        let wasPlaying = isPlaying
        let requestedProgress = progress.isFinite ? progress : 0.0
        var clampedProgress = 0.0
        var reachedBufferEnd = false

        // Both scheduleAudio and seek manipulate the player node based on pcmData.accumulated. Keeping
        // those operations on bufferQueue means a seek runs after all earlier scheduling work, then
        // prevents it from surviving playerNode.stop() and being replayed alongside the seek buffer.
        bufferQueue.sync {
            // Seeking is the user choosing where playback sits, so it ends any underrun suspension:
            // PCM arriving behind the chosen position must not restart what they left paused.
            underrunSuspendedGeneration = nil
            guard let format = audioFormat else { return }
            let bytesPerNetworkFrame = 2
            let bufferedDuration = Double(bufferedPCMFrameCount) / format.sampleRate
            let frameOffset: Int
            if requestedProgress >= bufferedDuration {
                frameOffset = bufferedPCMFrameCount
            } else if requestedProgress <= 0.0 {
                frameOffset = 0
            } else {
                frameOffset = min(Int(requestedProgress * format.sampleRate), bufferedPCMFrameCount)
            }
            clampedProgress = Double(frameOffset) / format.sampleRate
            let byteOffset = frameOffset * bytesPerNetworkFrame
            let completeByteCount = bufferedPCMFrameCount * bytesPerNetworkFrame

            playerNode.stop()

            guard byteOffset < completeByteCount else {
                reachedBufferEnd = true
                automaticPlaybackSuppressedGeneration = scheduleGeneration
                return
            }

            let remainingData = pcmData.accumulated.subdata(in: byteOffset..<completeByteCount)
            let frameCapacity = AVAudioFrameCount(remainingData.count / bytesPerNetworkFrame)
            guard frameCapacity > 0,
                  let buffer = makePCMBuffer(from: remainingData, format: format, frameCapacity: frameCapacity) else { return }

            schedule(buffer)
            if wasPlaying {
                playerNode.play()
            }
        }

        playbackProgress = clampedProgress
        baseProgressOffset = clampedProgress

        guard reachedBufferEnd else { return }

        // playerNode.stop() above clears every scheduled buffer, while pcmData.accumulated is retained
        // for play() to seek back to zero and replay without requesting audio again.
        isPlaying = false
        stopProgressTimer()
    }

    private func schedule(_ buffer: AVAudioPCMBuffer) {
        playerNode.scheduleBuffer(buffer)
        scheduledBufferObserver(buffer)
    }

    private func makePCMBuffer(from data: Data, format: AVAudioFormat, frameCapacity: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else { return nil }
        buffer.frameLength = frameCapacity
        data.withUnsafeBytes { rawBufferPointer in
            let int16Pointer = rawBufferPointer.bindMemory(to: Int16.self)
            if let floatChannelData = buffer.floatChannelData?[0] {
                for frame in 0..<Int(frameCapacity) {
                    floatChannelData[frame] = Float(int16Pointer[frame]) / 32768.0
                }
            }
        }
        return buffer
    }
}

/// Progress reporting: the repeating tick that turns the node's rendered position into the
/// published playback position, and the timer that drives it while a stream plays.
extension AudioPlayerManager {
    /// Converts a player-node sample time to elapsed seconds using the active PCM format.
    func progress(forRenderedSampleTime sampleTime: AVAudioFramePosition) -> Double? {
        let sampleRate = bufferQueue.sync { audioFormat?.sampleRate }
        guard let sampleRate else { return nil }
        return baseProgressOffset + Double(sampleTime) / sampleRate
    }

    /// Publishes the position one progress tick has reached, reading the rendered sample time and
    /// applying it within a single main-queue turn.
    ///
    /// The read and the publication must stay in one turn. `seek` installs a new
    /// `baseProgressOffset` on the main queue, so a tick that deferred its update would add a
    /// position rendered before the seek to the offset that seek installed. That sum reports
    /// playback ahead of the position the user chose, and stops the stream once it reaches the
    /// buffered end. Reaching that end on a tick of its own still stops playback, which is how it
    /// halts when the buffer runs out; `stopAtBufferedEnd` decides whether that halt is final.
    func applyProgressTick() {
        guard let sampleTime = renderedSampleTime(playerNode),
              let newProgress = progress(forRenderedSampleTime: sampleTime) else { return }
        if newProgress > 0 && newProgress <= bufferDuration {
            playbackProgress = newProgress
        } else if newProgress > bufferDuration {
            playbackProgress = bufferDuration
        }
        guard isPlaying, let bufferedEnd = serializedBufferedDuration, bufferedEnd > 0,
              newProgress >= bufferedEnd else { return }
        stopAtBufferedEnd(renderedProgress: newProgress, bufferedEnd: bufferedEnd)
    }

    /// The end of the PCM the player node actually holds, in seconds of the active format.
    ///
    /// Published `bufferDuration` is what the menu shows, and it lands a main-queue turn behind the
    /// frames `scheduleAudio` has already handed the node. Deciding that playback ran out of audio
    /// against that lagging value would suspend a stream whose next chunk is already rendering and
    /// discount the frames it had heard of that chunk as dry silence, so the decision and the offset
    /// it re-anchors read the serialized frame count scheduling itself maintains.
    private var serializedBufferedDuration: Double? {
        bufferQueue.sync {
            guard let format = audioFormat else { return nil }
            return Double(bufferedPCMFrameCount) / format.sampleRate
        }
    }

    private func startProgressTimer() {
        stopProgressTimer()
        let timer = Timer(timeInterval: Self.progressTickInterval, repeats: true) { [weak self] _ in
            self?.applyProgressTick()
        }
        progressTimer = timer
        progressTimerScheduler(timer)
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }
}

/// How a stream ends: the terminal event its request delivered, the stop playback makes when the
/// buffered PCM runs out, and whether later PCM may undo that stop. The four ways playback can come
/// to rest — a Pause the user asked for, a seek they chose, an underrun of a still-open request, and
/// the end of a request that has terminated — are told apart here, because only the underrun is
/// resumed by the audio that arrives behind it.
extension AudioPlayerManager {
    /// Whether the player node is itself running, as distinct from the `isPlaying` state published
    /// for the menu.
    ///
    /// The two must agree: telling the menu that a stream resumed without restarting the node
    /// reports playback that is not happening. Nothing in the app reads this — the node's own state
    /// is never the app's source of truth for what is playing — but the invariant is worth stating
    /// where it can be checked.
    var isNodePlaying: Bool {
        playerNode.isPlaying
    }

    /// Records how the request feeding `streamGeneration` ended, behind that stream's own PCM.
    ///
    /// It joins `bufferQueue` exactly as `scheduleAudio` does, so a terminal event the network
    /// manager released after a chunk of PCM cannot be applied before that chunk is buffered: both
    /// reach the main queue from the same serial queue, in the order they arrived on it.
    ///
    /// Ownership is checked once, where the value is published. Checking it again on `bufferQueue`
    /// beforehand would decide nothing: `scheduleGeneration` only advances, so an ending that queue
    /// would already reject is rejected by the publication check as well, while an ending it would
    /// accept can still be replaced before that publication runs. Rejecting is what keeps the
    /// session that replaced this one from being told that somebody else's request ended.
    func finishStream(streamGeneration: Int, termination: SpeechStreamTermination) {
        bufferQueue.async {
            defer { self.audioObservers.processed() }

            DispatchQueue.main.async {
                guard self.bufferQueue.sync(execute: { self.scheduleGeneration == streamGeneration }) else { return }
                self.streamTermination = termination
                self.audioObservers.statePublished()
            }
        }
    }

    /// Pauses playback and revokes the current stream's pending automatic start.
    ///
    /// The deferred start only observes `isPlaying`, which pausing clears, so without recording the
    /// intent against the paused generation the prebuffer deadline would undo an explicit Pause.
    /// Binding it to `scheduleGeneration` keeps the revocation to the stream that was paused: a
    /// later stream begins from a new generation, and `play()` still resumes this one on demand.
    ///
    /// A Pause the user asked for is not resumable: it releases any underrun suspension, so PCM
    /// arriving behind it keeps buffering for Resume instead of starting playback again.
    func pause() {
        suspendPlayback(resumableAfterUnderrun: false)
    }

    /// Stops the node and its progress timer, revoking the current stream's pending automatic start.
    ///
    /// `resumableAfterUnderrun` says whether the current stream's next PCM may resume playback where
    /// it stopped. It is false for every stop that reflects a decision — the user's Pause, or the end
    /// of a request that has already terminated — which later PCM must not reverse. Recording both
    /// revocations in one `bufferQueue` visit keeps a stop from being classified as one kind of stop
    /// and then read as the other.
    private func suspendPlayback(resumableAfterUnderrun: Bool) {
        bufferQueue.sync {
            automaticPlaybackSuppressedGeneration = scheduleGeneration
            underrunSuspendedGeneration = resumableAfterUnderrun ? scheduleGeneration : nil
        }
        playerNode.pause()
        isPlaying = false
        stopProgressTimer()
    }

    /// Stops playback where the buffered PCM ran out, recording whether more of it may still arrive.
    ///
    /// A stream whose request has already published a terminal event has been heard to its end, so
    /// it stops for good and only Play restarts it. A stream still open ran out early — the provider
    /// has not sent its next chunk, or a bounded retry is filling the gap — and stopping such a
    /// stream for good is what left the rest of a slow response unplayed, so its suspension names
    /// the generation later PCM resumes.
    ///
    /// The offset is re-anchored to that buffered end either way, by discounting however far
    /// `renderedProgress` overshot it. The node goes on advancing its sample time between
    /// exhausting its last buffer and this tick, and that silence is not audio anyone heard;
    /// carried forward, it would put each resumed position a further tick ahead of the sound and
    /// stop the next underrun early. Anchoring makes the rendered position read as the buffered
    /// end, which is exactly where the PCM that resumes the stream begins.
    private func stopAtBufferedEnd(renderedProgress: Double, bufferedEnd: Double) {
        suspendPlayback(resumableAfterUnderrun: streamTermination == nil)
        baseProgressOffset -= renderedProgress - bufferedEnd
    }

    /// Restarts the node on the PCM that ended an underrun, from the position playback stopped at.
    ///
    /// The node was paused rather than stopped, so it kept its sample time and its place in the
    /// output timeline: playing it again renders the buffer `scheduleAudio` has just queued behind
    /// what the user already heard. Nothing is re-scheduled and no prebuffer window is opened,
    /// because neither the audio nor the reason to wait for more of it has changed.
    private func resumeAfterUnderrun() {
        playerNode.play()
        isPlaying = true
        startProgressTimer()
    }
}

private extension AudioPlayerManager {
    func startAutomaticPlayback(streamGeneration: Int) {
        let result = bufferQueue.sync { () -> (started: Bool, engineStartFailed: Bool) in
            guard scheduleGeneration == streamGeneration,
                  automaticPlaybackSuppressedGeneration != streamGeneration,
                  !isPlaying else { return (false, false) }
            guard attemptEngineStart() else { return (false, true) }
            playerNode.play()
            return (true, false)
        }
        guard result.started else {
            if result.engineStartFailed {
                publishEngineStart(succeeded: false)
            }
            return
        }
        publishEngineStart(succeeded: true)
        isPlaying = true
        startProgressTimer()
    }
}
