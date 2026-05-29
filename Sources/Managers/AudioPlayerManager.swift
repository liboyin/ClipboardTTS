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
    private var baseProgressOffset: Double = 0.0

    private var progressTimer: Timer?

    init() {
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

    func scheduleAudio(data: Data) {
        guard let format = audioFormat else { return }

        // Runs on the network delegate's background queue; serialize buffer access via bufferQueue.
        bufferQueue.async {
            self.accumulatedData.append(data)
            self.unprocessedData.append(data)

            let bytesPerNetworkFrame = 2 // 16-bit PCM = 2 bytes per frame
            let frameCapacity = AVAudioFrameCount(self.unprocessedData.count / bytesPerNetworkFrame)
            guard frameCapacity > 0 else { return }

            let bytesToProcess = Int(frameCapacity) * bytesPerNetworkFrame
            let dataToProcess = self.unprocessedData.prefix(bytesToProcess)
            self.unprocessedData.removeFirst(bytesToProcess)

            guard let buffer = self.makePCMBuffer(from: dataToProcess, format: format, frameCapacity: frameCapacity) else { return }

            self.playerNode.scheduleBuffer(buffer)

            DispatchQueue.main.async {
                self.bufferDuration += Double(frameCapacity) / format.sampleRate
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

        DispatchQueue.main.async {
            self.isPlaying = true
        }
        startProgressTimer()
    }

    func pause() {
        playerNode.pause()
        DispatchQueue.main.async {
            self.isPlaying = false
        }
        stopProgressTimer()
    }

    func stop() {
        playerNode.stop()
        bufferQueue.sync {
            accumulatedData.removeAll()
            unprocessedData.removeAll()
        }
        baseProgressOffset = 0.0

        DispatchQueue.main.async {
            self.isPlaying = false
            self.hasAudio = false
            self.bufferDuration = 0.0
            self.playbackProgress = 0.0
        }
        stopProgressTimer()
    }

    func seek(to progress: Double) {
        guard let format = audioFormat else { return }
        self.playbackProgress = progress
        self.baseProgressOffset = progress
        let wasPlaying = isPlaying

        playerNode.stop()

        // Reading accumulatedData must be serialized against background appends in scheduleAudio.
        bufferQueue.sync {
            let bytesPerNetworkFrame = 2
            let byteOffset = Int(progress * format.sampleRate) * bytesPerNetworkFrame
            guard byteOffset < accumulatedData.count else { return }

            let remainingData = accumulatedData.subdata(in: byteOffset..<accumulatedData.count)
            let frameCapacity = AVAudioFrameCount(remainingData.count / bytesPerNetworkFrame)
            guard frameCapacity > 0,
                  let buffer = makePCMBuffer(from: remainingData, format: format, frameCapacity: frameCapacity) else { return }

            playerNode.scheduleBuffer(buffer)
            if wasPlaying {
                playerNode.play()
            }
        }
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
