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

        player.scheduleAudio(data: sampleData)

        let expectation = XCTestExpectation(description: "Audio scheduled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertTrue(player.hasAudio)
            XCTAssertGreaterThan(player.bufferDuration, 0.0)
            XCTAssertTrue(player.isPlaying)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testSeek() {
        // WHY: User seeking the slider should change playbackProgress and restart playing.
        let player = AudioPlayerManager()
        let sampleData = Data(repeating: 0, count: 48000) // 1 second of 24kHz 16-bit PCM audio
        player.scheduleAudio(data: sampleData)

        let expectation = XCTestExpectation(description: "Wait for audio schedule")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            player.seek(to: 0.5)

            XCTAssertEqual(player.playbackProgress, 0.5)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }
}
