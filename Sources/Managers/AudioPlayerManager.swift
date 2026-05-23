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
    private var baseProgressOffset: Double = 0.0
    
    private var progressTimer: Timer?
    
    init() {
        setupEngine()
    }
    
    private func setupEngine() {
        engine.attach(playerNode)
        engine.attach(timePitch)
        
        
        // Define format for buffer allocation
        audioFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true)
        
        // Define format for connecting nodes (standard format with standard sample rate)
        // Note: Using custom format (e.g. PCM Int16) directly in connection causes error -10868 on macOS.
        // Connecting with standard float format works, and AVFoundation handles the conversion from the buffer's format.
        let standardFormat = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)
        
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
        
        let frameCapacity = AVAudioFrameCount(data.count) / format.streamDescription.pointee.mBytesPerFrame
        guard frameCapacity > 0 else { return }
        
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else { return }
        buffer.frameLength = frameCapacity
        
        data.withUnsafeBytes { rawBufferPointer in
            if let ptr = rawBufferPointer.bindMemory(to: Int16.self).baseAddress {
                buffer.int16ChannelData?.pointee.update(from: ptr, count: Int(frameCapacity))
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
        accumulatedData.removeAll()
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
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        let byteOffset = Int(progress * sampleRate) * bytesPerFrame
        
        // Align to frame boundary
        let alignedOffset = byteOffset - (byteOffset % bytesPerFrame)
        
        guard alignedOffset < accumulatedData.count else { return }
        
        let remainingData = accumulatedData.subdata(in: alignedOffset..<accumulatedData.count)
        let frameCapacity = AVAudioFrameCount(remainingData.count) / format.streamDescription.pointee.mBytesPerFrame
        guard frameCapacity > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else { return }
        
        buffer.frameLength = frameCapacity
        remainingData.withUnsafeBytes { rawBufferPointer in
            if let ptr = rawBufferPointer.bindMemory(to: Int16.self).baseAddress {
                buffer.int16ChannelData?.pointee.update(from: ptr, count: Int(frameCapacity))
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
