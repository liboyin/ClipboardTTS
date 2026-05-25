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
        
        accumulatedData.append(data)
        unprocessedData.append(data)
        
        let bytesPerNetworkFrame = 2 // 16-bit PCM = 2 bytes per frame
        let frameCapacity = AVAudioFrameCount(unprocessedData.count / bytesPerNetworkFrame)
        guard frameCapacity > 0 else { return }
        
        let bytesToProcess = Int(frameCapacity) * bytesPerNetworkFrame
        let dataToProcess = unprocessedData.prefix(bytesToProcess)
        unprocessedData.removeFirst(bytesToProcess)
        
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else { return }
        buffer.frameLength = frameCapacity
        
        dataToProcess.withUnsafeBytes { rawBufferPointer in
            let int16Pointer = rawBufferPointer.bindMemory(to: Int16.self)
            if let floatChannelData = buffer.floatChannelData?[0] {
                for i in 0..<Int(frameCapacity) {
                    floatChannelData[i] = Float(int16Pointer[i]) / 32768.0
                }
            }
        }
        
        DispatchQueue.main.async {
            self.bufferDuration += Double(frameCapacity) / format.sampleRate
            self.hasAudio = true
            
            if !self.isPlaying {
                self.play()
            }
        }
        
        playerNode.scheduleBuffer(buffer)
    }
    
    func play() {
        if !engine.isRunning {
            try? engine.start()
        }
        
        if playbackProgress >= bufferDuration && bufferDuration > 0 {
            seek(to: 0.0)
            playerNode.play()
        } else {
            playerNode.play()
        }
        
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
        accumulatedData.removeAll()
        unprocessedData.removeAll()
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
        self.playbackProgress = progress
        self.baseProgressOffset = progress
        
        playerNode.stop()
        guard let format = audioFormat else { return }
        
        let sampleRate = format.sampleRate
        let bytesPerNetworkFrame = 2
        let byteOffset = Int(progress * sampleRate) * bytesPerNetworkFrame
        
        // Align to frame boundary
        let alignedOffset = byteOffset - (byteOffset % bytesPerNetworkFrame)
        
        guard alignedOffset < accumulatedData.count else { return }
        
        let remainingData = accumulatedData.subdata(in: alignedOffset..<accumulatedData.count)
        let frameCapacity = AVAudioFrameCount(remainingData.count / bytesPerNetworkFrame)
        guard frameCapacity > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else { return }
        
        buffer.frameLength = frameCapacity
        remainingData.withUnsafeBytes { rawBufferPointer in
            let int16Pointer = rawBufferPointer.bindMemory(to: Int16.self)
            if let floatChannelData = buffer.floatChannelData?[0] {
                for i in 0..<Int(frameCapacity) {
                    floatChannelData[i] = Float(int16Pointer[i]) / 32768.0
                }
            }
        }
        
        playerNode.scheduleBuffer(buffer)
        if isPlaying {
            playerNode.play()
        }
    }
    
    private func startProgressTimer() {
        stopProgressTimer()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let nodeTime = self.playerNode.lastRenderTime, let playerTime = self.playerNode.playerTime(forNodeTime: nodeTime) else { return }
            
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
