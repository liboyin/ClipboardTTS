import XCTest
import SwiftUI
@testable import ClipboardTTSApp

final class MenuBarViewTests: XCTestCase {

    func testTogglePlayPauseFlipsPlayingState() {
        // WHY: The single play/pause button is driven entirely by togglePlayPause flipping
        // audioPlayer.isPlaying. If toggling stopped alternating state, the button would lie about
        // what playback is doing. This asserts the toggle actually flips the state both ways.
        let audioPlayer = AudioPlayerManager()
        let textExtraction = TextExtractionManager()
        let networkManager = TTSNetworkManager(configuration: .ephemeral)

        let view = MenuBarView(audioPlayer: audioPlayer, textExtraction: textExtraction, networkManager: networkManager)

        XCTAssertFalse(audioPlayer.isPlaying)

        view.togglePlayPause()
        let playing = XCTestExpectation(description: "Toggled to playing")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertTrue(audioPlayer.isPlaying)
            playing.fulfill()
        }
        wait(for: [playing], timeout: 1.0)

        view.togglePlayPause()
        let paused = XCTestExpectation(description: "Toggled back to paused")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertFalse(audioPlayer.isPlaying)
            paused.fulfill()
        }
        wait(for: [paused], timeout: 1.0)
    }

    func testSpeakCopiedTextStartsStreamingFromClipboard() {
        // WHY: This is the core "Speak Copied Text" story - with text on the clipboard and nothing
        // playing, the button must pull the clipboard text and stream it to audio. Asserting
        // hasAudio flips true proves clipboard -> network -> scheduled audio ran end to end.
        let audioPlayer = AudioPlayerManager()
        let textExtraction = TextExtractionManager()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let networkManager = TTSNetworkManager(configuration: config)
        networkManager.updateSettings(baseURL: "https://mock.api/v1/audio/speech", apiKey: "test", model: "test", voice: "test")
        MockURLProtocol.requestHandler = { request in
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(repeating: 0, count: 2048))
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("Speak me", forType: .string)

        let view = MenuBarView(audioPlayer: audioPlayer, textExtraction: textExtraction, networkManager: networkManager)
        view.speakCopiedText()

        // speakCopiedText defers the extraction+stream by 0.2s, then audio is scheduled async.
        let expectation = XCTestExpectation(description: "Clipboard text streamed to audio")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            XCTAssertTrue(audioPlayer.hasAudio)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 3.0)
    }

    func testSpeakCopiedTextClearsActiveBuffer() {
        // WHY: Once audio is buffered the button becomes "Clear Buffer"; speakCopiedText must then
        // tear playback down (stop streaming + discard buffered audio) rather than start a new read.
        // If it didn't, the button would advertise a clear that never happens.
        let audioPlayer = AudioPlayerManager()
        let textExtraction = TextExtractionManager()
        let networkManager = TTSNetworkManager(configuration: .ephemeral)
        let view = MenuBarView(audioPlayer: audioPlayer, textExtraction: textExtraction, networkManager: networkManager)

        // Buffer audio so hasAudio == true (the "Clear Buffer" precondition).
        let gen = audioPlayer.startNewStream()
        audioPlayer.scheduleAudio(data: Data(repeating: 0, count: 2048), streamGeneration: gen)
        let buffered = XCTestExpectation(description: "Audio buffered")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertTrue(audioPlayer.hasAudio)
            buffered.fulfill()
        }
        wait(for: [buffered], timeout: 1.0)

        view.speakCopiedText()

        let cleared = XCTestExpectation(description: "Buffer cleared")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertFalse(audioPlayer.hasAudio)
            cleared.fulfill()
        }
        wait(for: [cleared], timeout: 1.0)
    }
}
