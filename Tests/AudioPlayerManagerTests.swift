// swiftlint:disable file_length
// The focused behavior tests intentionally remain alongside their shared playback helpers so
// their timing and lifecycle contracts are readable in one place.
import XCTest
import AVFoundation
@testable import ClipboardTTSApp

final class AudioPlayerManagerTests: XCTestCase {

    func testAudioPlayerStateTransitions() {
        // WHY: The UI elements (Play/Pause, Clear Buffer) rely on accurate state representation in the AudioPlayerManager.
        // We must verify that calling play(), pause(), and stop() correctly sets the `isPlaying` flag.

        let player = makeOwnedAudioPlayer(automaticPlaybackScheduler: immediatelyScheduleAutomaticPlayback)

        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.hasAudio)

        // Each transition is published synchronously on the main thread that requested it.
        player.play()
        XCTAssertTrue(player.isPlaying)

        player.pause()
        XCTAssertFalse(player.isPlaying)

        player.stop()
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.hasAudio)
    }

    func testPlaybackRateChange() {
        // WHY: The user slider must accurately control the underlying AVAudioUnitTimePitch rate without fail.
        let player = makeOwnedAudioPlayer(automaticPlaybackScheduler: immediatelyScheduleAutomaticPlayback)
        player.playbackRate = 1.5
        XCTAssertEqual(player.playbackRate, 1.5)
    }

    func testScheduleAudioDroppedAfterStop() {
        // WHY: Ensure that scheduleAudio calls from stale network requests are ignored after stop() is called.
        let processedPackets = AudioDataProcessingRecorder()
        let player = makeOwnedAudioPlayer(
            automaticPlaybackScheduler: immediatelyScheduleAutomaticPlayback,
            audioDataProcessingObserver: processedPackets.record
        )
        let gen = player.startNewStream()

        player.stop()

        let packetProcessed = processedPackets.expectNextProcessing()
        player.scheduleAudio(data: Data(repeating: 0, count: 1024), streamGeneration: gen)
        // The audio queue has handled the stale packet, so anything it queued for the main queue is
        // queued; one main-queue turn then applies it before the assertions read the state.
        wait(for: [packetProcessed], timeout: 1.0)
        drainMainQueue()

        XCTAssertFalse(player.hasAudio)
        XCTAssertEqual(player.bufferDuration, 0.0)
        XCTAssertFalse(player.isPlaying)
    }

    func testDefaultSampleRateIs24KHz() {
        // WHY: OpenAI and Gemini PCM are fixed at 24 kHz, so the player must preserve the
        // long-standing default until Settings selects a validated Custom override.
        let player = makeOwnedAudioPlayer(automaticPlaybackScheduler: immediatelyScheduleAutomaticPlayback)

        XCTAssertEqual(player.sampleRate, 24_000)
        XCTAssertTrue(player.isReadyForNewStream)
    }

    func test48KHzPCMUsesRebuiltFormatForDurationAndSeek() {
        // WHY: A 48-kHz Custom stream has twice as many Int16 frames per second as the default.
        // Duration and seek must use the rebuilt format everywhere, or the menu would report and
        // schedule positions at half their real time.
        let scheduledBuffers = ScheduledBufferSpy()
        let publications = AudioStateUpdateRecorder()
        let player = makeOwnedAudioPlayer(
            scheduledBufferObserver: { scheduledBuffers.record($0) },
            automaticPlaybackScheduler: immediatelyScheduleAutomaticPlayback,
            audioStateObserver: publications.record
        )

        XCTAssertEqual(player.setSampleRate(48_000), .updated)
        bufferAndStartPlayback(Data(repeating: 0, count: 96_000), in: player, publications: publications)
        XCTAssertEqual(player.bufferDuration, 1.0, accuracy: 0.000_001)
        XCTAssertEqual(player.progress(forRenderedSampleTime: 48_000) ?? -1.0, 1.0, accuracy: 0.000_001)
        XCTAssertEqual(scheduledBuffers.lastSampleRate, 48_000)
        XCTAssertEqual(scheduledBuffers.lastFrameLength, 48_000)

        player.seek(to: 0.5)

        XCTAssertEqual(player.playbackProgress, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(scheduledBuffers.lastSampleRate, 48_000)
        XCTAssertEqual(scheduledBuffers.lastFrameLength, 24_000)
    }

    func testUnchangedSampleRatePreservesBufferedAudio() {
        // WHY: Selecting the already-active Custom rate must not interrupt a read or discard its
        // buffer, because no mixed-format data can exist when the graph did not change.
        let publications = AudioStateUpdateRecorder()
        let player = makeOwnedAudioPlayer(
            automaticPlaybackScheduler: immediatelyScheduleAutomaticPlayback,
            audioStateObserver: publications.record
        )
        bufferAndStartPlayback(Data(repeating: 0, count: 48_000), in: player, publications: publications)
        XCTAssertEqual(player.setSampleRate(24_000), .unchanged)
        XCTAssertTrue(player.hasAudio)
        XCTAssertEqual(player.bufferDuration, 1.0, accuracy: 0.000_001)
    }

    func testInvalidSampleRateLeavesCurrentFormatAndBufferUntouched() {
        // WHY: Rejecting an invalid Custom setting must be atomic. A partial graph rebuild would
        // either lose the current read or leave audio interpreted by a format the UI did not accept.
        let publications = AudioStateUpdateRecorder()
        let player = makeOwnedAudioPlayer(
            automaticPlaybackScheduler: immediatelyScheduleAutomaticPlayback,
            audioStateObserver: publications.record
        )
        bufferAndStartPlayback(Data(repeating: 0, count: 48_000), in: player, publications: publications)
        XCTAssertEqual(player.setSampleRate(7_999), .invalid)
        XCTAssertEqual(player.setSampleRate(.infinity), .invalid)
        XCTAssertEqual(player.sampleRate, 24_000)
        XCTAssertFalse(player.hasValidSampleRateConfiguration)
        XCTAssertTrue(player.hasAudio)
        XCTAssertEqual(player.bufferDuration, 1.0, accuracy: 0.000_001)
        XCTAssertEqual(player.sampleRateError, "PCM sample rate must be a finite value from 8,000 to 48,000 Hz.")
    }

    func testSampleRateChangeClearsPlaybackAndReportsEngineRestartFailure() {
        // WHY: A valid format change invalidates already-scheduled PCM even when the engine cannot
        // restart. The UI must then show a safe cleared state instead of claiming old-format audio
        // remains playable.
        let startController = SwitchableAudioEngineStarter()
        let publications = AudioStateUpdateRecorder()
        let player = makeOwnedAudioPlayer(
            engineStarter: startController.start,
            automaticPlaybackScheduler: immediatelyScheduleAutomaticPlayback,
            audioStateObserver: publications.record
        )
        bufferAndStartPlayback(Data(repeating: 0, count: 48_000), in: player, publications: publications)
        startController.shouldFail = true

        XCTAssertEqual(player.setSampleRate(48_000), .engineStartFailed)
        XCTAssertEqual(player.sampleRate, 48_000)
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.hasAudio)
        XCTAssertEqual(player.bufferDuration, 0.0)
        XCTAssertEqual(player.playbackProgress, 0.0)
        XCTAssertEqual(player.sampleRateError, "Couldn't start audio playback. Try again.")
        // The rebuilt format is valid, so readiness stays true: the next session retries the start
        // rather than being refused until something else restarts the engine.
        XCTAssertTrue(player.isReadyForNewStream)

        XCTAssertEqual(player.setSampleRate(48_000), .engineStartFailed)
        XCTAssertEqual(player.sampleRateError, "Couldn't start audio playback. Try again.")
    }

    func testSeekWhilePlayingClampsToBufferedRangeAndReplaysFromExactEnd() {
        // WHY: The progress slider must never advertise playback after it reaches the final buffered
        // frame; the retained buffer must still support replay without a new TTS request.
        let scheduledBuffers = ScheduledBufferSpy()
        let publications = AudioStateUpdateRecorder()
        let player = makeOwnedAudioPlayer(
            scheduledBufferObserver: { scheduledBuffers.record($0) },
            automaticPlaybackScheduler: immediatelyScheduleAutomaticPlayback,
            audioStateObserver: publications.record
        )
        let sampleData = Data(repeating: 0, count: 48000) // 1 second of 24kHz 16-bit PCM audio
        bufferAndStartPlayback(sampleData, in: player, publications: publications)

        player.seek(to: 0.0)
        XCTAssertEqual(player.playbackProgress, 0.0, accuracy: 0.000_001)
        XCTAssertTrue(player.isPlaying)

        player.seek(to: 0.5)
        XCTAssertEqual(player.playbackProgress, 0.5, accuracy: 0.000_001)
        XCTAssertTrue(player.isPlaying)

        player.seek(to: player.bufferDuration - 0.001)
        XCTAssertEqual(player.playbackProgress, player.bufferDuration - 0.001, accuracy: 0.000_001)
        XCTAssertTrue(player.isPlaying)

        player.seek(to: player.bufferDuration)
        XCTAssertEqual(player.playbackProgress, player.bufferDuration, accuracy: 0.000_001)
        XCTAssertFalse(player.isPlaying)
        XCTAssertTrue(player.hasAudio)

        // Play and seek publish their playing state synchronously on the main thread.
        player.play()
        player.seek(to: player.bufferDuration)
        XCTAssertFalse(player.isPlaying)

        let scheduledBufferCountBeforeReplay = scheduledBuffers.count
        player.play()
        XCTAssertEqual(player.playbackProgress, 0.0, accuracy: 0.000_001)
        XCTAssertEqual(scheduledBuffers.count, scheduledBufferCountBeforeReplay + 1)
        XCTAssertTrue(player.isPlaying)

        player.seek(to: player.bufferDuration + 1.0)
        XCTAssertEqual(player.playbackProgress, player.bufferDuration, accuracy: 0.000_001)
        XCTAssertFalse(player.isPlaying)
        XCTAssertTrue(player.hasAudio)
    }

    func testSeekToCompletePCMEndStopsPlaybackWithRoundingSensitiveOrTrailingData() {
        // WHY: Network chunks may end at any byte boundary. End seeking must use complete PCM-frame
        // boundaries, rather than floating-point conversion or the raw byte count.
        let expectedDuration = Double(24_007) / 24_000.0
        for byteCount in [48_014, 48_015] {
            let publications = AudioStateUpdateRecorder()
            let player = makeOwnedAudioPlayer(
                automaticPlaybackScheduler: immediatelyScheduleAutomaticPlayback,
                audioStateObserver: publications.record
            )
            bufferAndStartPlayback(Data(repeating: 0, count: byteCount), in: player, publications: publications)

            player.seek(to: player.bufferDuration)

            XCTAssertEqual(player.playbackProgress, expectedDuration, accuracy: 0.000_001)
            XCTAssertFalse(player.isPlaying)
            XCTAssertTrue(player.hasAudio)
        }
    }

    func testSeekToPublishedEndStopsPlaybackAcrossRoundingSensitiveChunks() {
        // WHY: The slider maximum is a duration published after each network chunk. It must remain
        // the same complete-frame boundary used by seek, even when individual Double durations round.
        let framesPerChunk = 24_001
        let expectedDuration = Double(framesPerChunk * 7) / 24_000.0

        for shouldPause in [false, true] {
            let publications = AudioStateUpdateRecorder()
            let player = makeOwnedAudioPlayer(
                automaticPlaybackScheduler: immediatelyScheduleAutomaticPlayback,
                audioStateObserver: publications.record
            )
            let gen = player.startNewStream()
            let chunksPublished = (0..<7).map { _ in publications.expectNextUpdate() }
            for _ in 0..<7 {
                player.scheduleAudio(data: Data(repeating: 0, count: framesPerChunk * 2), streamGeneration: gen)
            }

            // The first chunk queued its automatic start ahead of its own publication, so once
            // every chunk has published, the stream has started too.
            wait(for: chunksPublished, timeout: 1.0)
            XCTAssertEqual(player.bufferDuration, expectedDuration, accuracy: 0.000_001)
            XCTAssertTrue(player.isPlaying)
            if shouldPause {
                player.pause()
                XCTAssertFalse(player.isPlaying)
            }

            player.seek(to: player.bufferDuration)

            XCTAssertEqual(player.playbackProgress, expectedDuration, accuracy: 0.000_001)
            XCTAssertFalse(player.isPlaying)
            XCTAssertTrue(player.hasAudio)
        }
    }

    func testConcurrentScheduleAudioKeepsExactFrameAccounting() {
        // WHY: scheduleAudio enters from the network delegate queue, so a burst of chunks can
        // arrive concurrently. bufferQueue must serialize every append, or the buffered-frame
        // total the UI publishes (and the slider clamps to) would drift from the retained PCM.
        let chunkCount = 32
        let allPublished = expectation(description: "Every scheduled packet publishes its buffered state")
        allPublished.expectedFulfillmentCount = chunkCount
        let player = makeOwnedAudioPlayer(
            automaticPlaybackScheduler: immediatelyScheduleAutomaticPlayback,
            audioStateObserver: { allPublished.fulfill() }
        )
        defer { player.stop() }
        let generation = player.startNewStream()

        DispatchQueue.concurrentPerform(iterations: chunkCount) { _ in
            player.scheduleAudio(data: Data(repeating: 0, count: 2), streamGeneration: generation)
        }

        wait(for: [allPublished], timeout: 2.0)
        XCTAssertEqual(player.bufferDuration, Double(chunkCount) / 24_000.0, accuracy: 0.000_001)
        XCTAssertTrue(player.hasAudio)
    }

    func testSeekWhilePausedClampsToBufferedRangeWithoutResuming() {
        // WHY: Dragging the progress slider while paused must retain the paused state at every
        // boundary, including a request beyond the buffered audio.
        let publications = AudioStateUpdateRecorder()
        let player = makeOwnedAudioPlayer(
            automaticPlaybackScheduler: immediatelyScheduleAutomaticPlayback,
            audioStateObserver: publications.record
        )
        let sampleData = Data(repeating: 0, count: 48000) // 1 second of 24kHz 16-bit PCM audio
        bufferAndStartPlayback(sampleData, in: player, publications: publications)
        player.pause()
        XCTAssertFalse(player.isPlaying)

        player.seek(to: -1.0)
        XCTAssertEqual(player.playbackProgress, 0.0, accuracy: 0.000_001)
        XCTAssertFalse(player.isPlaying)

        player.seek(to: 0.0)
        XCTAssertEqual(player.playbackProgress, 0.0, accuracy: 0.000_001)
        XCTAssertFalse(player.isPlaying)

        player.seek(to: 0.5)
        XCTAssertEqual(player.playbackProgress, 0.5, accuracy: 0.000_001)
        XCTAssertFalse(player.isPlaying)

        player.seek(to: player.bufferDuration - 0.001)
        XCTAssertEqual(player.playbackProgress, player.bufferDuration - 0.001, accuracy: 0.000_001)
        XCTAssertFalse(player.isPlaying)

        player.seek(to: player.bufferDuration)
        XCTAssertEqual(player.playbackProgress, player.bufferDuration, accuracy: 0.000_001)
        XCTAssertFalse(player.isPlaying)
        XCTAssertTrue(player.hasAudio)

        player.seek(to: player.bufferDuration + 1.0)
        XCTAssertEqual(player.playbackProgress, player.bufferDuration, accuracy: 0.000_001)
        XCTAssertFalse(player.isPlaying)
        XCTAssertTrue(player.hasAudio)
    }

    /// Buffers `data` as a new stream and waits for the stream's publication.
    ///
    /// The immediate scheduler queues the automatic start on the main queue before the packet's own
    /// publication, so once that publication has run the start has run too.
    private func bufferAndStartPlayback(_ data: Data,
                                        in player: AudioPlayerManager,
                                        publications: AudioStateUpdateRecorder,
                                        file: StaticString = #filePath,
                                        line: UInt = #line) {
        let published = publications.expectNextUpdate()
        let generation = player.startNewStream()
        player.scheduleAudio(data: data, streamGeneration: generation)
        wait(for: [published], timeout: 1.0)
        XCTAssertTrue(player.hasAudio, "Precondition: the stream is buffered.", file: file, line: line)
        XCTAssertTrue(player.isPlaying, "Precondition: the stream started automatically.", file: file, line: line)
    }

    /// Runs one main-queue turn, so a publication already queued lands before the assertions.
    private func drainMainQueue() {
        let drained = expectation(description: "Main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2.0)
    }
}

/// Covers the progress tick that publishes playback position: the timer calls it, and these tests
/// call it directly, so a stated rendered position replaces whatever live audio has rendered.
final class AudioPlayerProgressTickTests: XCTestCase {

    func testProgressTickPublishesItsRenderedPositionBeforeALaterSeekChangesTheOffset() {
        // WHY: A tick's rendered position and the seek offset it is added to must come from one
        // main-queue turn. Adding a position rendered before a seek to the offset that seek
        // installed reported playback beyond the position the user chose, and paused a stream at
        // the buffered end while it was still playing.
        let renderedPosition = RenderedPositionSource(sampleTime: 4_800) // 0.2 second at 24 kHz
        let heldAutomaticStart = ManualAutomaticPlaybackScheduler()
        let bufferPublished = expectation(description: "Buffered audio state is published")
        let player = makeOwnedAudioPlayer(
            automaticPlaybackScheduler: heldAutomaticStart.schedule,
            renderedSampleTimeReader: renderedPosition.read,
            audioStateObserver: { bufferPublished.fulfill() }
        )
        defer { player.stop() }
        let generation = player.startNewStream()
        player.scheduleAudio(data: Data(repeating: 0, count: 96_000), streamGeneration: generation) // 2 seconds
        wait(for: [bufferPublished], timeout: 1.0)
        XCTAssertEqual(player.bufferDuration, 2.0, accuracy: 0.000_001)

        player.applyProgressTick()
        XCTAssertEqual(player.playbackProgress, 0.2, accuracy: 0.000_001)

        player.seek(to: 1.8)
        drainMainQueue()

        XCTAssertEqual(player.playbackProgress, 1.8, accuracy: 0.000_001)
        XCTAssertTrue(player.hasAudio)
    }

    func testProgressTickPastTheBufferedEndClampsProgressAndStopsPlaybackAndItsTimer() {
        // WHY: The tick is what stops playback once rendering reaches the end of the buffered PCM.
        // It must publish the buffered end rather than a position beyond it, keep the audio for
        // replay, stop its own timer, and stop the stream in the way that revokes the prebuffer
        // start still pending behind it, which would otherwise resume what the tick just ended.
        let renderedPosition = RenderedPositionSource(sampleTime: 60_000) // 2.5 seconds at 24 kHz
        let heldAutomaticStart = ManualAutomaticPlaybackScheduler()
        let progressTimer = ProgressTimerSpy()
        let bufferPublished = expectation(description: "Buffered audio state is published")
        let player = makeOwnedAudioPlayer(
            automaticPlaybackScheduler: heldAutomaticStart.schedule,
            renderedSampleTimeReader: renderedPosition.read,
            progressTimerScheduler: progressTimer.schedule,
            audioStateObserver: { bufferPublished.fulfill() }
        )
        defer { player.stop() }
        let generation = player.startNewStream()
        player.scheduleAudio(data: Data(repeating: 0, count: 96_000), streamGeneration: generation) // 2 seconds
        wait(for: [bufferPublished], timeout: 1.0)
        XCTAssertEqual(heldAutomaticStart.scheduledDelays, [0.1])

        player.play()
        XCTAssertTrue(player.isPlaying)

        progressTimer.fireTick()

        XCTAssertEqual(player.playbackProgress, 2.0, accuracy: 0.000_001)
        XCTAssertFalse(player.isPlaying)
        XCTAssertTrue(player.hasAudio)
        XCTAssertFalse(progressTimer.isRunning)

        heldAutomaticStart.runNextAction()
        drainMainQueue()

        XCTAssertFalse(player.isPlaying)
    }

    func testProgressTickWithoutARenderedPositionLeavesPublishedProgressAlone() {
        // WHY: The node reports no render time before it has played anything and between a stop and
        // the next start. A tick that reads none must leave the position playback has reached,
        // rather than publishing the seek offset as though nothing had been rendered since.
        let renderedPosition = RenderedPositionSource(sampleTime: nil)
        let heldAutomaticStart = ManualAutomaticPlaybackScheduler()
        let bufferPublished = expectation(description: "Buffered audio state is published")
        let player = makeOwnedAudioPlayer(
            automaticPlaybackScheduler: heldAutomaticStart.schedule,
            renderedSampleTimeReader: renderedPosition.read,
            audioStateObserver: { bufferPublished.fulfill() }
        )
        defer { player.stop() }
        let generation = player.startNewStream()
        player.scheduleAudio(data: Data(repeating: 0, count: 96_000), streamGeneration: generation) // 2 seconds
        wait(for: [bufferPublished], timeout: 1.0)
        player.seek(to: 0.5)
        renderedPosition.sampleTime = 12_000 // 0.5 second rendered since that seek
        player.applyProgressTick()
        XCTAssertEqual(player.playbackProgress, 1.0, accuracy: 0.000_001)

        renderedPosition.sampleTime = nil
        player.applyProgressTick()

        XCTAssertEqual(player.playbackProgress, 1.0, accuracy: 0.000_001)
        XCTAssertFalse(player.isPlaying)
    }

    func testPlaybackDrivesEveryTickOfItsProgressTimerUntilItStops() {
        // WHY: The timer is what publishes position during playback. A driver that started but
        // called nothing would freeze the progress the menu shows and never pause at the buffered
        // end, so the tick the manager hands its timer must be the one that publishes.
        let renderedPosition = RenderedPositionSource(sampleTime: nil)
        let heldAutomaticStart = ManualAutomaticPlaybackScheduler()
        let progressTimer = ProgressTimerSpy()
        let bufferPublished = expectation(description: "Buffered audio state is published")
        let player = makeOwnedAudioPlayer(
            automaticPlaybackScheduler: heldAutomaticStart.schedule,
            renderedSampleTimeReader: renderedPosition.read,
            progressTimerScheduler: progressTimer.schedule,
            audioStateObserver: { bufferPublished.fulfill() }
        )
        defer { player.stop() }
        let generation = player.startNewStream()
        player.scheduleAudio(data: Data(repeating: 0, count: 96_000), streamGeneration: generation) // 2 seconds
        wait(for: [bufferPublished], timeout: 1.0)

        player.play()
        XCTAssertEqual(progressTimer.requestedInterval, 0.1)

        renderedPosition.sampleTime = 4_800 // 0.2 second at 24 kHz
        progressTimer.fireTick()
        XCTAssertEqual(player.playbackProgress, 0.2, accuracy: 0.000_001)

        renderedPosition.sampleTime = 12_000 // 0.5 second at 24 kHz
        progressTimer.fireTick()
        XCTAssertEqual(player.playbackProgress, 0.5, accuracy: 0.000_001)

        player.pause()
        XCTAssertFalse(progressTimer.isRunning)
    }

    /// Runs the main queue once, so any update a progress tick deferred would land before the
    /// assertions that follow.
    private func drainMainQueue() {
        let drained = expectation(description: "Main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2.0)
    }
}

private final class ScheduledBufferSpy {
    private let lock = NSLock()
    private var scheduledBufferCount = 0
    private var sampleRate: Double?
    private var frameLength: AVAudioFrameCount?

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return scheduledBufferCount
    }

    var lastSampleRate: Double? {
        lock.lock()
        defer { lock.unlock() }
        return sampleRate
    }

    var lastFrameLength: AVAudioFrameCount? {
        lock.lock()
        defer { lock.unlock() }
        return frameLength
    }

    func record(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        scheduledBufferCount += 1
        sampleRate = buffer.format.sampleRate
        frameLength = buffer.frameLength
        lock.unlock()
    }
}

private func immediatelyScheduleAutomaticPlayback(after _: TimeInterval, _ action: @escaping () -> Void) {
    action()
}
