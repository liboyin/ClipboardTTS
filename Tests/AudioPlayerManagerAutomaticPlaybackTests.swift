import XCTest
import AVFoundation
@testable import ClipboardTTSApp

final class AudioPlayerManagerAutomaticPlaybackTests: XCTestCase {

    func testAutomaticPlaybackBuffersPacketsUntilPrebufferDeadline() {
        // WHY: A short first network chunk must be retained while the startup prebuffer grows,
        // rather than being consumed before later chunks arrive.
        let scheduler = ManualAutomaticPlaybackScheduler()
        let scheduledBuffers = ScheduledPCMBufferRecorder()
        let stateUpdates = AudioStateUpdateRecorder()
        let firstStateUpdate = stateUpdates.expectNextUpdate()
        let player = AudioPlayerManager(
            scheduledBufferObserver: scheduledBuffers.record,
            automaticPlaybackScheduler: scheduler.schedule,
            audioStateObserver: stateUpdates.record
        )
        defer { player.stop() }
        let generation = player.startNewStream()

        player.scheduleAudio(data: Data(repeating: 0, count: 1_024), streamGeneration: generation)

        wait(for: [firstStateUpdate], timeout: 1.0)
        XCTAssertTrue(player.hasAudio)
        XCTAssertGreaterThan(player.bufferDuration, 0.0)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(scheduler.scheduledActionCount, 1)
        XCTAssertEqual(scheduler.scheduledDelays, [0.1])

        let secondStateUpdate = stateUpdates.expectNextUpdate()
        player.scheduleAudio(data: Data(repeating: 0, count: 2_048), streamGeneration: generation)
        wait(for: [secondStateUpdate], timeout: 1.0)
        XCTAssertEqual(player.bufferDuration, Double(1_536) / 24_000.0, accuracy: 0.000_001)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(scheduler.scheduledActionCount, 1)
        XCTAssertEqual(scheduledBuffers.count, 2)
        XCTAssertEqual(scheduledBuffers.totalFrameCount, 1_536)

        scheduler.runNextAction()

        assertPlayingState(of: player, is: true)
    }

    func testAutomaticPlaybackDoesNotStartAfterStopBeforePrebufferDeadline() {
        // WHY: Clear Buffer maps to stop(), so an already-queued automatic start must never
        // resurrect playback after the user has discarded the stream.
        let scheduler = ManualAutomaticPlaybackScheduler()
        let stateUpdates = AudioStateUpdateRecorder()
        let bufferedAudioState = stateUpdates.expectNextUpdate()
        let player = AudioPlayerManager(
            automaticPlaybackScheduler: scheduler.schedule,
            audioStateObserver: stateUpdates.record
        )
        defer { player.stop() }
        let generation = player.startNewStream()
        player.scheduleAudio(data: Data(repeating: 0, count: 2), streamGeneration: generation)

        wait(for: [bufferedAudioState], timeout: 1.0)
        player.stop()
        scheduler.runNextAction()
        assertPlayingState(of: player, is: false)

        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.hasAudio)
        XCTAssertEqual(player.bufferDuration, 0.0)
    }

    func testAutomaticPlaybackDoesNotRestartAfterSeekingToPrebufferEnd() {
        // WHY: Seeking to the current end stops the node by design, so the pending automatic
        // start must respect that explicit user intent instead of publishing a false playing state.
        let scheduler = ManualAutomaticPlaybackScheduler()
        let stateUpdates = AudioStateUpdateRecorder()
        let bufferedAudioState = stateUpdates.expectNextUpdate()
        let player = AudioPlayerManager(
            automaticPlaybackScheduler: scheduler.schedule,
            audioStateObserver: stateUpdates.record
        )
        defer { player.stop() }
        let generation = player.startNewStream()
        player.scheduleAudio(data: Data(repeating: 0, count: 2), streamGeneration: generation)

        wait(for: [bufferedAudioState], timeout: 1.0)
        player.seek(to: player.bufferDuration)
        scheduler.runNextAction()

        assertPlayingState(of: player, is: false)
        XCTAssertTrue(player.hasAudio)
    }

    func testAutomaticPlaybackFromReplacedGenerationCannotStartNewStream() {
        // WHY: A late callback from a replaced request must not start playback for audio that
        // belongs to a newer generation.
        let scheduler = ManualAutomaticPlaybackScheduler()
        let stateUpdates = AudioStateUpdateRecorder()
        let firstStateUpdate = stateUpdates.expectNextUpdate()
        let player = AudioPlayerManager(
            automaticPlaybackScheduler: scheduler.schedule,
            audioStateObserver: stateUpdates.record
        )
        defer { player.stop() }
        let firstGeneration = player.startNewStream()
        player.scheduleAudio(data: Data(repeating: 0, count: 2), streamGeneration: firstGeneration)
        wait(for: [firstStateUpdate], timeout: 1.0)

        let secondGeneration = player.startNewStream()
        let secondStateUpdate = stateUpdates.expectNextUpdate()
        player.scheduleAudio(data: Data(repeating: 0, count: 2), streamGeneration: secondGeneration)
        wait(for: [secondStateUpdate], timeout: 1.0)
        XCTAssertEqual(scheduler.scheduledActionCount, 2)

        scheduler.runNextAction()
        assertPlayingState(of: player, is: false)

        scheduler.runNextAction()

        assertPlayingState(of: player, is: true)
    }

    func testAutomaticPlaybackDoesNotStartAfterFormatResetBeforePrebufferDeadline() {
        // WHY: A PCM format reset clears the scheduled node buffers, so its pending automatic
        // start must be invalidated instead of reviving audio decoded in the old format.
        let scheduler = ManualAutomaticPlaybackScheduler()
        let stateUpdates = AudioStateUpdateRecorder()
        let bufferedAudioState = stateUpdates.expectNextUpdate()
        let player = AudioPlayerManager(
            automaticPlaybackScheduler: scheduler.schedule,
            audioStateObserver: stateUpdates.record
        )
        defer { player.stop() }
        let generation = player.startNewStream()
        player.scheduleAudio(data: Data(repeating: 0, count: 2), streamGeneration: generation)

        wait(for: [bufferedAudioState], timeout: 1.0)
        XCTAssertEqual(player.setSampleRate(48_000), .updated)
        scheduler.runNextAction()
        assertPlayingState(of: player, is: false)

        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.hasAudio)
        XCTAssertEqual(player.bufferDuration, 0.0)
    }

    func testAutomaticPlaybackReportsEngineRestartFailure() {
        // WHY: A delayed start must retain play()'s engine-recovery behavior, or the UI could
        // claim playback is active while the audio engine cannot render the buffered PCM.
        let scheduler = ManualAutomaticPlaybackScheduler()
        let engineStarter = FailingAudioEngineStarter()
        let stateUpdates = AudioStateUpdateRecorder()
        let bufferedAudioState = stateUpdates.expectNextUpdate()
        let player = AudioPlayerManager(
            engineStarter: engineStarter.start,
            automaticPlaybackScheduler: scheduler.schedule,
            audioStateObserver: stateUpdates.record
        )
        defer { player.stop() }
        let generation = player.startNewStream()
        player.scheduleAudio(data: Data(repeating: 0, count: 2), streamGeneration: generation)

        wait(for: [bufferedAudioState], timeout: 1.0)
        scheduler.runNextAction()
        assertPlayingState(of: player, is: false)

        XCTAssertEqual(engineStarter.callCount, 2)
        XCTAssertFalse(player.hasValidSampleRateConfiguration)
        XCTAssertEqual(player.sampleRateError, "Couldn't start audio playback. Try again.")
    }

    func testAutomaticPlaybackWaitsForCompletePCMFrame() {
        // WHY: PCM can be split on an arbitrary byte boundary. The delay must begin when the
        // first playable frame exists, not when unusable partial data first arrives.
        let scheduler = ManualAutomaticPlaybackScheduler()
        let audioDataProcessing = AudioDataProcessingRecorder()
        let firstPacketProcessed = audioDataProcessing.expectNextProcessing()
        let stateUpdates = AudioStateUpdateRecorder()
        let firstStateUpdate = stateUpdates.expectNextUpdate()
        let player = AudioPlayerManager(
            automaticPlaybackScheduler: scheduler.schedule,
            audioDataProcessingObserver: audioDataProcessing.record,
            audioStateObserver: stateUpdates.record
        )
        defer { player.stop() }
        let generation = player.startNewStream()

        player.scheduleAudio(data: Data([0]), streamGeneration: generation)
        wait(for: [firstPacketProcessed], timeout: 1.0)
        XCTAssertEqual(scheduler.scheduledActionCount, 0)

        player.scheduleAudio(data: Data([0]), streamGeneration: generation)
        wait(for: [firstStateUpdate], timeout: 1.0)

        XCTAssertTrue(player.hasAudio)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(scheduler.scheduledActionCount, 1)
    }

    private func assertPlayingState(of player: AudioPlayerManager, is expectedState: Bool) {
        let expectation = XCTestExpectation(description: "Delayed playback action is handled on the main queue")
        DispatchQueue.main.async {
            XCTAssertEqual(player.isPlaying, expectedState)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }
}

private final class AudioDataProcessingRecorder {
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

private final class FailingAudioEngineStarter {
    private(set) var callCount = 0

    func start(_: AVAudioEngine) throws {
        callCount += 1
        throw TestAudioEngineStartError.failed
    }
}

private enum TestAudioEngineStartError: Error {
    case failed
}

private final class ManualAutomaticPlaybackScheduler {
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

private final class ScheduledPCMBufferRecorder {
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

private final class AudioStateUpdateRecorder {
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
