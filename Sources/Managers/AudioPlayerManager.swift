import Foundation
import AVFoundation

class AudioPlayerManager: ObservableObject {
    @Published var isPlaying = false
    @Published var playbackProgress: Double = 0.0
    @Published var bufferDuration: Double = 0.0
    @Published var hasAudio = false

    @Published var playbackRate: Float = 1.0 {
        didSet {
            timePitch.rate = playbackRate
        }
    }

    private var engine = AVAudioEngine()
    private var playerNode = AVAudioPlayerNode()
    private var timePitch = AVAudioUnitTimePitch()

    private var audioFormat: AVAudioFormat?

    // accumulatedData/unprocessedData are written from the network delegate's background queue
    // (scheduleAudio) and read/cleared from the main thread (seek/stop). All access to them MUST
    // go through bufferQueue to avoid a data race.
    private let bufferQueue = DispatchQueue(label: "com.clipboardtts.audiobuffer")
    private var accumulatedData = Data()
    private var unprocessedData = Data()
    private var bufferedPCMFrameCount = 0
    private var baseProgressOffset: Double = 0.0
    private var scheduleGeneration: Int = 0
    private let scheduledBufferObserver: (AVAudioPCMBuffer) -> Void

    private var progressTimer: Timer?

    /// Creates the audio graph. The observer is notified after each PCM buffer is passed to the node.
    init(scheduledBufferObserver: @escaping (AVAudioPCMBuffer) -> Void = { _ in }) {
        self.scheduledBufferObserver = scheduledBufferObserver
        setupEngine()
    }

    private func setupEngine() {
        engine.attach(playerNode)
        engine.attach(timePitch)

        let standardFormat = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)
        audioFormat = standardFormat

        if let standardFormat = standardFormat {
            engine.connect(playerNode, to: timePitch, format: standardFormat)
            engine.connect(timePitch, to: engine.mainMixerNode, format: standardFormat)
        }

        do {
            try engine.start()
        } catch {
            print("Engine start error: \(error)")
        }
    }

    func startNewStream() -> Int {
        return bufferQueue.sync {
            scheduleGeneration += 1
            accumulatedData.removeAll()
            unprocessedData.removeAll()
            bufferedPCMFrameCount = 0
            return scheduleGeneration
        }
    }

    func scheduleAudio(data: Data, streamGeneration: Int) {
        guard let format = audioFormat else { return }

        // Runs on the network delegate's background queue; serialize buffer access via bufferQueue.
        bufferQueue.async {
            guard self.scheduleGeneration == streamGeneration else { return }

            self.accumulatedData.append(data)
            self.unprocessedData.append(data)

            let bytesPerNetworkFrame = 2 // 16-bit PCM = 2 bytes per frame
            self.bufferedPCMFrameCount = self.accumulatedData.count / bytesPerNetworkFrame
            let bufferedFrameCount = self.bufferedPCMFrameCount
            let frameCapacity = AVAudioFrameCount(self.unprocessedData.count / bytesPerNetworkFrame)
            guard frameCapacity > 0 else { return }

            let bytesToProcess = Int(frameCapacity) * bytesPerNetworkFrame
            let dataToProcess = self.unprocessedData.prefix(bytesToProcess)
            self.unprocessedData.removeFirst(bytesToProcess)

            guard let buffer = self.makePCMBuffer(from: dataToProcess, format: format, frameCapacity: frameCapacity) else { return }

            self.schedule(buffer)

            DispatchQueue.main.async {
                self.bufferDuration = Double(bufferedFrameCount) / format.sampleRate
                self.hasAudio = true

                if !self.isPlaying {
                    self.play()
                }
            }
        }
    }

    func play() {
        if !engine.isRunning {
            try? engine.start()
        }

        if playbackProgress >= bufferDuration && bufferDuration > 0 {
            seek(to: 0.0)
        }
        playerNode.play()

        isPlaying = true
        startProgressTimer()
    }

    func pause() {
        playerNode.pause()
        isPlaying = false
        stopProgressTimer()
    }

    func stop() {
        // Bump the generation and clear buffers first, then stop the node. bufferQueue is a serial
        // FIFO: any scheduleAudio block already queued runs before this sync block and may still call
        // playerNode.scheduleBuffer, but the following playerNode.stop() flushes that buffer. Blocks
        // queued after the bump fail the generation guard and drop. Reversing the order would let an
        // in-flight scheduleAudio schedule one buffer onto the node after it was stopped.
        bufferQueue.sync {
            scheduleGeneration += 1
            accumulatedData.removeAll()
            unprocessedData.removeAll()
            bufferedPCMFrameCount = 0
        }
        playerNode.stop()
        baseProgressOffset = 0.0

        DispatchQueue.main.async {
            self.isPlaying = false
            self.hasAudio = false
            self.bufferDuration = 0.0
            self.playbackProgress = 0.0
        }
        stopProgressTimer()
    }

    /// Moves playback to a buffered position, clamping requests outside the available PCM range.
    /// Seeking to the end stops playback but preserves the buffered data for replay.
    func seek(to progress: Double) {
        guard let format = audioFormat else { return }
        let wasPlaying = isPlaying
        let requestedProgress = progress.isFinite ? progress : 0.0
        var clampedProgress = 0.0
        var reachedBufferEnd = false

        // Both scheduleAudio and seek manipulate the player node based on accumulatedData. Keeping
        // those operations on bufferQueue means a seek runs after all earlier scheduling work, then
        // prevents it from surviving playerNode.stop() and being replayed alongside the seek buffer.
        bufferQueue.sync {
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
                return
            }

            let remainingData = accumulatedData.subdata(in: byteOffset..<completeByteCount)
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

        // playerNode.stop() above clears every scheduled buffer, while accumulatedData is retained
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

    private func startProgressTimer() {
        stopProgressTimer()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self,
                  let nodeTime = self.playerNode.lastRenderTime,
                  let playerTime = self.playerNode.playerTime(forNodeTime: nodeTime) else { return }

            DispatchQueue.main.async {
                if let format = self.audioFormat {
                    let newProgress = self.baseProgressOffset + Double(playerTime.sampleTime) / format.sampleRate
                    if newProgress > 0 && newProgress <= self.bufferDuration {
                        self.playbackProgress = newProgress
                    } else if newProgress > self.bufferDuration {
                        self.playbackProgress = self.bufferDuration
                    }

                    if self.isPlaying && self.playbackProgress >= self.bufferDuration && self.bufferDuration > 0 {
                        self.pause()
                    }
                }
            }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }
}
