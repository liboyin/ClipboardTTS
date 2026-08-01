import XCTest
import AVFoundation
@testable import ClipboardTTSApp

final class AudioPlayerManagerTests: XCTestCase {

    func testAudioPlayerStateTransitions() {
        // WHY: The UI elements (Play/Pause, Clear Buffer) rely on accurate state representation in the AudioPlayerManager.
        // We must verify that calling play(), pause(), and stop() correctly sets the `isPlaying` flag.

        let player = AudioPlayerManager(automaticPlaybackScheduler: immediatelyScheduleAutomaticPlayback)

        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.hasAudio)

        player.play()

        let expectation1 = XCTestExpectation(description: "State changes to playing")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertTrue(player.isPlaying)
            expectation1.fulfill()
        }
        wait(for: [expectation1], timeout: 1.0)

        player.pause()

        let expectation2 = XCTestExpectation(description: "State changes to paused")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertFalse(player.isPlaying)
            expectation2.fulfill()
        }
        wait(for: [expectation2], timeout: 1.0)

        player.stop()

        let expectation3 = XCTestExpectation(description: "State changes to stopped")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertFalse(player.isPlaying)
            XCTAssertFalse(player.hasAudio)
            expectation3.fulfill()
        }
        wait(for: [expectation3], timeout: 1.0)
    }

    func testPlaybackRateChange() {
        // WHY: The user slider must accurately control the underlying AVAudioUnitTimePitch rate without fail.
        let player = AudioPlayerManager(automaticPlaybackScheduler: immediatelyScheduleAutomaticPlayback)
        player.playbackRate = 1.5
        XCTAssertEqual(player.playbackRate, 1.5)
    }

    func testScheduleAudioDroppedAfterStop() {
        // WHY: Ensure that scheduleAudio calls from stale network requests are ignored after stop() is called.
        let player = AudioPlayerManager(automaticPlaybackScheduler: immediatelyScheduleAutomaticPlayback)
        let gen = player.startNewStream()

        player.stop()

        player.scheduleAudio(data: Data(repeating: 0, count: 1024), streamGeneration: gen)

        let expectation = XCTestExpectation(description: "Audio should not be scheduled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertFalse(player.hasAudio)
            XCTAssertEqual(player.bufferDuration, 0.0)
            XCTAssertFalse(player.isPlaying)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testDefaultSampleRateIs24KHz() {
        // WHY: OpenAI and Gemini PCM are fixed at 24 kHz, so the player must preserve the
        // long-standing default until Settings selects a validated Custom override.
        let player = AudioPlayerManager(automaticPlaybackScheduler: immediatelyScheduleAutomaticPlayback)

        XCTAssertEqual(player.sampleRate, 24_000)
        XCTAssertTrue(player.isReadyForNewStream)
    }

    func test48KHzPCMUsesRebuiltFormatForDurationAndSeek() {
        // WHY: A 48-kHz Custom stream has twice as many Int16 frames per second as the default.
        // Duration and seek must use the rebuilt format everywhere, or the menu would report and
        // schedule positions at half their real time.
        let scheduledBuffers = ScheduledBufferSpy()
        let player = AudioPlayerManager(
            scheduledBufferObserver: { scheduledBuffers.record($0) },
            automaticPlaybackScheduler: immediatelyScheduleAutomaticPlayback
        )

        XCTAssertEqual(player.setSampleRate(48_000), .updated)
        let generation = player.startNewStream()
        player.scheduleAudio(data: Data(repeating: 0, count: 96_000), streamGeneration: generation)

        waitForPlayback(toStartIn: player)
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
        let player = AudioPlayerManager(automaticPlaybackScheduler: immediatelyScheduleAutomaticPlayback)
        let generation = player.startNewStream()
        player.scheduleAudio(data: Data(repeating: 0, count: 48_000), streamGeneration: generation)

        waitForPlayback(toStartIn: player)
        XCTAssertEqual(player.setSampleRate(24_000), .unchanged)
        XCTAssertTrue(player.hasAudio)
        XCTAssertEqual(player.bufferDuration, 1.0, accuracy: 0.000_001)
    }

    func testInvalidSampleRateLeavesCurrentFormatAndBufferUntouched() {
        // WHY: Rejecting an invalid Custom setting must be atomic. A partial graph rebuild would
        // either lose the current read or leave audio interpreted by a format the UI did not accept.
        let player = AudioPlayerManager(automaticPlaybackScheduler: immediatelyScheduleAutomaticPlayback)
        let generation = player.startNewStream()
        player.scheduleAudio(data: Data(repeating: 0, count: 48_000), streamGeneration: generation)

        waitForPlayback(toStartIn: player)
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
        let startController = AudioEngineStartController()
        let player = AudioPlayerManager(
            engineStarter: startController.start,
            automaticPlaybackScheduler: immediatelyScheduleAutomaticPlayback
        )
        let generation = player.startNewStream()
        player.scheduleAudio(data: Data(repeating: 0, count: 48_000), streamGeneration: generation)

        waitForPlayback(toStartIn: player)
        startController.shouldFail = true

        XCTAssertEqual(player.setSampleRate(48_000), .engineStartFailed)
        XCTAssertEqual(player.sampleRate, 48_000)
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.hasAudio)
        XCTAssertEqual(player.bufferDuration, 0.0)
        XCTAssertEqual(player.playbackProgress, 0.0)
        XCTAssertEqual(player.sampleRateError, "Couldn't start audio playback. Try again.")
        XCTAssertFalse(player.isReadyForNewStream)

        XCTAssertEqual(player.setSampleRate(48_000), .engineStartFailed)
        XCTAssertEqual(player.sampleRateError, "Couldn't start audio playback. Try again.")
    }

    func testSeekWhilePlayingClampsToBufferedRangeAndReplaysFromExactEnd() {
        // WHY: The progress slider must never advertise playback after it reaches the final buffered
        // frame; the retained buffer must still support replay without a new TTS request.
        let scheduledBuffers = ScheduledBufferSpy()
        let player = AudioPlayerManager(
            scheduledBufferObserver: { scheduledBuffers.record($0) },
            automaticPlaybackScheduler: immediatelyScheduleAutomaticPlayback
        )
        let sampleData = Data(repeating: 0, count: 48000) // 1 second of 24kHz 16-bit PCM audio
        let gen = player.startNewStream()
        player.scheduleAudio(data: sampleData, streamGeneration: gen)

        waitForPlayback(toStartIn: player)
        XCTAssertTrue(player.isPlaying)

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

        player.play()
        player.seek(to: player.bufferDuration)
        waitForPlayingState(of: player, toBecome: false)

        let scheduledBufferCountBeforeReplay = scheduledBuffers.count
        player.play()
        XCTAssertEqual(player.playbackProgress, 0.0, accuracy: 0.000_001)
        XCTAssertEqual(scheduledBuffers.count, scheduledBufferCountBeforeReplay + 1)
        waitForPlayingState(of: player, toBecome: true)

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
            let player = AudioPlayerManager(automaticPlaybackScheduler: immediatelyScheduleAutomaticPlayback)
            let gen = player.startNewStream()
            player.scheduleAudio(data: Data(repeating: 0, count: byteCount), streamGeneration: gen)

            waitForPlayback(toStartIn: player)
            XCTAssertTrue(player.isPlaying)

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
            let player = AudioPlayerManager(automaticPlaybackScheduler: immediatelyScheduleAutomaticPlayback)
            let gen = player.startNewStream()
            for _ in 0..<7 {
                player.scheduleAudio(data: Data(repeating: 0, count: framesPerChunk * 2), streamGeneration: gen)
            }

            waitForBufferDuration(of: player, toBecome: expectedDuration)
            waitForPlayingState(of: player, toBecome: true)
            if shouldPause {
                player.pause()
                waitForPlayingState(of: player, toBecome: false)
            } else {
                XCTAssertTrue(player.isPlaying)
            }

            player.seek(to: player.bufferDuration)

            XCTAssertEqual(player.playbackProgress, expectedDuration, accuracy: 0.000_001)
            XCTAssertFalse(player.isPlaying)
            XCTAssertTrue(player.hasAudio)
        }
    }

    func testSeekWhilePausedClampsToBufferedRangeWithoutResuming() {
        // WHY: Dragging the progress slider while paused must retain the paused state at every
        // boundary, including a request beyond the buffered audio.
        let player = AudioPlayerManager(automaticPlaybackScheduler: immediatelyScheduleAutomaticPlayback)
        let sampleData = Data(repeating: 0, count: 48000) // 1 second of 24kHz 16-bit PCM audio
        let gen = player.startNewStream()
        player.scheduleAudio(data: sampleData, streamGeneration: gen)

        waitForPlayback(toStartIn: player)
        player.pause()
        waitForPlayingState(of: player, toBecome: false)

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

    private func waitForPlayback(toStartIn player: AudioPlayerManager) {
        let expectation = XCTestExpectation(description: "Audio is scheduled and playing")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertTrue(player.hasAudio)
            XCTAssertTrue(player.isPlaying)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    private func waitForPlayingState(of player: AudioPlayerManager, toBecome expectedState: Bool) {
        let expectation = XCTestExpectation(description: "Playback state is updated")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(player.isPlaying, expectedState)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    private func waitForBufferDuration(of player: AudioPlayerManager, toBecome expectedDuration: Double) {
        let expectation = XCTestExpectation(description: "Buffer duration is updated")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(player.bufferDuration, expectedDuration, accuracy: 0.000_001)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
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

private final class AudioEngineStartController {
    var shouldFail = false

    func start(_ engine: AVAudioEngine) throws {
        if shouldFail {
            throw AudioEngineStartFailure.failed
        }
        try engine.start()
    }
}

private enum AudioEngineStartFailure: Error {
    case failed
}

private func immediatelyScheduleAutomaticPlayback(after _: TimeInterval, _ action: @escaping () -> Void) {
    action()
}
