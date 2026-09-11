import XCTest
import AVFoundation
@testable import ClipboardTTSApp

// Test doubles shared by the audio-manager suites. They live here rather than beside one suite so
// any of them can drive the 0.1-second automatic-playback prebuffer, the progress timer, and the
// rendered position deterministically: the schedulers hand the deferred start and the timer back to
// the test, the position source states what the node has rendered, and the recorders turn the
// manager's processing and publication hooks into explicit completion instead of an elapsed-time
// wait.

final class AudioDataProcessingRecorder {
    private let lock = NSLock()
    private var pendingExpectations: [XCTestExpectation] = []

    func expectNextProcessing() -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "Audio queue finishes processing a network packet")
        lock.lock()
        pendingExpectations.append(expectation)
        lock.unlock()
        return expectation
    }

    func record() {
        lock.lock()
        let expectation = pendingExpectations.isEmpty ? nil : pendingExpectations.removeFirst()
        lock.unlock()
        expectation?.fulfill()
    }
}

final class FailingAudioEngineStarter {
    private(set) var callCount = 0

    func start(_: AVAudioEngine) throws {
        callCount += 1
        throw TestAudioEngineStartError.failed
    }
}

enum TestAudioEngineStartError: Error {
    case failed
}

final class ManualAutomaticPlaybackScheduler {
    private let lock = NSLock()
    private var actions: [() -> Void] = []
    private var delays: [TimeInterval] = []

    var scheduledActionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return actions.count
    }

    var scheduledDelays: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return delays
    }

    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) {
        lock.lock()
        delays.append(delay)
        actions.append(action)
        lock.unlock()
    }

    func runNextAction() {
        lock.lock()
        let action = actions.removeFirst()
        lock.unlock()
        action()
    }
}

final class ScheduledPCMBufferRecorder {
    private let lock = NSLock()
    private var bufferCount = 0
    private var frameCount: AVAudioFrameCount = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return bufferCount
    }

    var totalFrameCount: AVAudioFrameCount {
        lock.lock()
        defer { lock.unlock() }
        return frameCount
    }

    func record(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        bufferCount += 1
        frameCount += buffer.frameLength
        lock.unlock()
    }
}

final class AudioStateUpdateRecorder {
    private let lock = NSLock()
    private var pendingExpectations: [XCTestExpectation] = []

    func expectNextUpdate() -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "Buffered-audio state is published")
        lock.lock()
        pendingExpectations.append(expectation)
        lock.unlock()
        return expectation
    }

    func record() {
        lock.lock()
        let expectation = pendingExpectations.isEmpty ? nil : pendingExpectations.removeFirst()
        lock.unlock()
        expectation?.fulfill()
    }
}

/// States the rendered position a progress tick reads, so a test can drive the tick from a position
/// it chose instead of from whatever the live audio graph has rendered by then.
final class RenderedPositionSource {
    var sampleTime: AVAudioFramePosition?

    init(sampleTime: AVAudioFramePosition?) {
        self.sampleTime = sampleTime
    }

    func read(_: AVAudioPlayerNode) -> AVAudioFramePosition? {
        sampleTime
    }
}

/// Keeps the manager's progress timer out of every run loop, so the only ticks are the ones a test
/// fires, and each one runs the callback the manager gave that timer.
final class ProgressTimerSpy {
    private(set) var timer: Timer?

    var isRunning: Bool {
        timer?.isValid ?? false
    }

    var requestedInterval: TimeInterval? {
        timer?.timeInterval
    }

    func schedule(_ timer: Timer) {
        self.timer = timer
    }

    func fireTick(file: StaticString = #filePath, line: UInt = #line) {
        guard let timer, timer.isValid else {
            XCTFail("No progress timer is running, so it cannot tick.", file: file, line: line)
            return
        }
        timer.fire()
    }
}
