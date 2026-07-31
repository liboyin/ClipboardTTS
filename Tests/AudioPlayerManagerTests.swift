import XCTest
@testable import ClipboardTTSApp

final class AudioPlayerManagerTests: XCTestCase {

    func testAudioPlayerStateTransitions() {
        // WHY: The UI elements (Play/Pause, Clear Buffer) rely on accurate state representation in the AudioPlayerManager.
        // We must verify that calling play(), pause(), and stop() correctly sets the `isPlaying` flag.

        let player = AudioPlayerManager()

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
        let player = AudioPlayerManager()
        player.playbackRate = 1.5
        XCTAssertEqual(player.playbackRate, 1.5)
    }

    func testScheduleAudio() {
        // WHY: Ensure that providing valid PCM data increments bufferDuration and correctly changes the state.
        let player = AudioPlayerManager()
        let sampleData = Data(repeating: 0, count: 1024)

        let gen = player.startNewStream()
        player.scheduleAudio(data: sampleData, streamGeneration: gen)

        let expectation = XCTestExpectation(description: "Audio scheduled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertTrue(player.hasAudio)
            XCTAssertGreaterThan(player.bufferDuration, 0.0)
            XCTAssertTrue(player.isPlaying)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testScheduleAudioDroppedAfterStop() {
        // WHY: Ensure that scheduleAudio calls from stale network requests are ignored after stop() is called.
        let player = AudioPlayerManager()
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

    func testSeekWhilePlayingClampsToBufferedRangeAndReplaysFromExactEnd() {
        // WHY: The progress slider must never advertise playback after it reaches the final buffered
        // frame; the retained buffer must still support replay without a new TTS request.
        let scheduledBuffers = ScheduledBufferSpy()
        let player = AudioPlayerManager { _ in scheduledBuffers.record() }
        let sampleData = Data(repeating: 0, count: 48000) // 1 second of 24kHz 16-bit PCM audio
        let gen = player.startNewStream()
        player.scheduleAudio(data: sampleData, streamGeneration: gen)

        waitForAudio(toBeScheduledBy: player)
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
            let player = AudioPlayerManager()
            let gen = player.startNewStream()
            player.scheduleAudio(data: Data(repeating: 0, count: byteCount), streamGeneration: gen)

            waitForAudio(toBeScheduledBy: player)
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
            let player = AudioPlayerManager()
            let gen = player.startNewStream()
            for _ in 0..<7 {
                player.scheduleAudio(data: Data(repeating: 0, count: framesPerChunk * 2), streamGeneration: gen)
            }

            waitForBufferDuration(of: player, toBecome: expectedDuration)
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
        let player = AudioPlayerManager()
        let sampleData = Data(repeating: 0, count: 48000) // 1 second of 24kHz 16-bit PCM audio
        let gen = player.startNewStream()
        player.scheduleAudio(data: sampleData, streamGeneration: gen)

        waitForAudio(toBeScheduledBy: player)
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

    private func waitForAudio(toBeScheduledBy player: AudioPlayerManager) {
        let expectation = XCTestExpectation(description: "Audio is scheduled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertTrue(player.hasAudio)
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

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return scheduledBufferCount
    }

    func record() {
        lock.lock()
        scheduledBufferCount += 1
        lock.unlock()
    }
}
