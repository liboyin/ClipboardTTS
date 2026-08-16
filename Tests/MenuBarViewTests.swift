import XCTest
import AppKit
import SwiftUI
@testable import ClipboardTTSApp

/// Builds the menu with its own deferred-action owner unless a test needs a controllable one.
func makeMenu(audioPlayer: AudioPlayerManager,
              textExtraction: TextExtractionManager,
              networkManager: TTSNetworkManager,
              deferredClipboardAction: DeferredClipboardAction = DeferredClipboardAction()) -> MenuBarView {
    MenuBarView(
        audioPlayer: audioPlayer,
        textExtraction: textExtraction,
        networkManager: networkManager,
        deferredClipboardAction: deferredClipboardAction
    )
}

final class MenuBarViewTests: MockURLProtocolTestCase {
    func testMenuLoadsProviderVoiceMetadataBeforeSettingsAppears() {
        // WHY: The menu is the primary interaction surface, so its voice picker cannot depend on
        // the Settings window having been opened to populate the provider-authoritative choices.
        let audioPlayer = AudioPlayerManager()
        let textExtraction = TextExtractionManager(pasteboard: FakePasteboardReader())
        let networkManager = TestNetworkFactory.makeManager()
        let view = makeMenu(audioPlayer: audioPlayer, textExtraction: textExtraction, networkManager: networkManager)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 320)

        XCTAssertEqual(view.voiceOptions, [])
        host.layoutSubtreeIfNeeded()

        let voicesLoaded = expectation(description: "Menu receives initial OpenAI voice metadata")
        DispatchQueue.main.async {
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(
                view.voiceOptions,
                ["alloy", "ash", "coral", "echo", "fable", "onyx", "nova", "sage", "shimmer"]
            )
            voicesLoaded.fulfill()
        }
        wait(for: [voicesLoaded], timeout: 1.0)
    }

    func testMenuCustomVoiceOptionsReflectConfiguredVoiceOnly() {
        // WHY: Custom has no voice-discovery contract, so the menu must expose exactly its shared
        // configured voice rather than an unrelated provider list; blank configuration is not a
        // selectable voice and must remain an explicit Settings correction.
        UserDefaults.standard.set("Custom", forKey: SettingsKeys.ttsProvider)
        UserDefaults.standard.set("custom-voice", forKey: SettingsKeys.customVoice)
        let audioPlayer = AudioPlayerManager()
        let textExtraction = TextExtractionManager(pasteboard: FakePasteboardReader())
        let networkManager = TestNetworkFactory.makeManager()
        networkManager.updateSettings(
            baseURL: "https://custom.api/v1/audio/speech",
            apiKey: "test-key",
            model: "custom-model",
            voice: "custom-voice",
            selectedProvider: "Custom"
        )
        let configuredVoiceView = makeMenu(
            audioPlayer: audioPlayer,
            textExtraction: textExtraction,
            networkManager: networkManager
        )
        XCTAssertEqual(configuredVoiceView.voiceOptions, ["custom-voice"])

        UserDefaults.standard.set(" \t\n", forKey: SettingsKeys.customVoice)
        let emptyVoiceView = makeMenu(
            audioPlayer: audioPlayer,
            textExtraction: textExtraction,
            networkManager: networkManager
        )
        XCTAssertEqual(emptyVoiceView.voiceOptions, [])
    }

    func testMenuVoiceSelectionUsesCurrentProviderOptionsAndNextRequest() throws {
        // WHY: The menu must choose an OpenAI voice from fresh provider metadata, persist it in
        // the same setting as Settings, and use it on the next request without changing its model
        // or endpoint configuration.
        let audioPlayer = AudioPlayerManager()
        let textExtraction = TextExtractionManager(pasteboard: FakePasteboardReader())
        let networkManager = TestNetworkFactory.makeManager()
        networkManager.updateSettings(
            baseURL: "https://mock.api/v1/audio/speech",
            apiKey: "test-key",
            model: "tts-1",
            voice: "alloy",
            selectedProvider: "OpenAI"
        )
        networkManager.availableVoices = ["alloy", "nova"]
        let view = makeMenu(audioPlayer: audioPlayer, textExtraction: textExtraction, networkManager: networkManager)

        XCTAssertEqual(view.voiceOptions, ["alloy", "nova"])
        view.selectVoice("nova")
        XCTAssertEqual(view.selectedVoice, "nova")
        XCTAssertEqual(UserDefaults.standard.string(forKey: SettingsKeys.openAIVoice), "nova")

        let requestStarted = expectation(description: "Menu voice is used by the next TTS request")
        MockURLProtocol.installRequestHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            guard let bodyData = requestBodyData(from: request),
                  let body = try? JSONSerialization.jsonObject(with: bodyData) as? [String: String] else {
                XCTFail("The menu request should contain a JSON speech payload.")
                return (response, Data())
            }
            XCTAssertEqual(body["voice"], "nova")
            requestStarted.fulfill()
            return (response, Data())
        }

        networkManager.streamTTS(text: "Use the selected voice") { _ in }
        wait(for: [requestStarted], timeout: 1.0)
    }

    func testMenuVoiceSelectionRejectsStaleProviderOptionsAndBufferedPlayback() {
        // WHY: Changing a voice while paused with retained audio would make the visible setting
        // disagree with the already-buffered read. A switch must also not retain the prior
        // provider's options long enough to write a stale voice into the new provider's setting.
        let audioPlayer = AudioPlayerManager()
        let textExtraction = TextExtractionManager(pasteboard: FakePasteboardReader())
        let networkManager = TestNetworkFactory.makeManager()
        networkManager.updateSettings(
            baseURL: "https://mock.api/v1/audio/speech",
            apiKey: "test-key",
            model: "tts-1",
            voice: "alloy",
            selectedProvider: "OpenAI"
        )
        networkManager.availableVoices = ["alloy", "nova"]
        let view = makeMenu(audioPlayer: audioPlayer, textExtraction: textExtraction, networkManager: networkManager)

        UserDefaults.standard.set("Gemini", forKey: SettingsKeys.ttsProvider)
        XCTAssertEqual(view.voiceOptions, [])
        view.selectVoice("nova")
        XCTAssertEqual(UserDefaults.standard.string(forKey: SettingsKeys.geminiVoice), nil)

        networkManager.updateSettings(
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            apiKey: "test-key",
            model: "gemini-3.1-flash-tts-preview",
            voice: "Aoede",
            selectedProvider: "Gemini"
        )
        networkManager.availableVoices = ["Aoede", "Puck"]
        let geminiView = makeMenu(
            audioPlayer: audioPlayer,
            textExtraction: textExtraction,
            networkManager: networkManager
        )
        XCTAssertEqual(geminiView.voiceOptions, ["Aoede", "Puck"])
        geminiView.selectVoice("Puck")
        XCTAssertEqual(UserDefaults.standard.string(forKey: SettingsKeys.geminiVoice), "Puck")
        XCTAssertEqual(UserDefaults.standard.string(forKey: SettingsKeys.openAIVoice), nil)

        UserDefaults.standard.set("OpenAI", forKey: SettingsKeys.ttsProvider)
        networkManager.updateSettings(
            baseURL: "https://mock.api/v1/audio/speech",
            apiKey: "test-key",
            model: "tts-1",
            voice: "alloy",
            selectedProvider: "OpenAI"
        )
        networkManager.availableVoices = ["alloy", "nova"]
        let openAIView = makeMenu(
            audioPlayer: audioPlayer,
            textExtraction: textExtraction,
            networkManager: networkManager
        )
        audioPlayer.hasAudio = true
        XCTAssertFalse(openAIView.isVoiceSelectionEnabled)
        openAIView.selectVoice("nova")
        XCTAssertEqual(UserDefaults.standard.string(forKey: SettingsKeys.openAIVoice), nil)

        audioPlayer.hasAudio = false
        networkManager.isStreaming = true
        XCTAssertFalse(openAIView.isVoiceSelectionEnabled)
        networkManager.isStreaming = false
        XCTAssertTrue(openAIView.isVoiceSelectionEnabled)
        openAIView.selectVoice("nova")
        XCTAssertEqual(UserDefaults.standard.string(forKey: SettingsKeys.openAIVoice), "nova")
    }

    func testSpeakCopiedTextStartsStreamingFromClipboard() {
        // WHY: This is the core "Speak Copied Text" story - with text on the clipboard and nothing
        // playing, the button must pull the clipboard text and start a network request. Audio
        // scheduling is covered by AudioPlayerManagerTests, so this view test avoids live audio.
        let audioPlayer = AudioPlayerManager()
        let textExtraction = TextExtractionManager(pasteboard: FakePasteboardReader(text: "Speak me"))
        let networkManager = TestNetworkFactory.makeManager()
        networkManager.updateSettings(baseURL: "https://mock.api/v1/audio/speech", apiKey: "test", model: "test", voice: "test")
        let requestStarted = expectation(description: "Clipboard text starts a TTS request")
        MockURLProtocol.installRequestHandler { request in
            requestStarted.fulfill()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }

        let view = makeMenu(audioPlayer: audioPlayer, textExtraction: textExtraction, networkManager: networkManager)
        view.speakCopiedText()

        // speakCopiedText defers clipboard extraction and request creation by 0.2 seconds.
        wait(for: [requestStarted], timeout: 2.0)
    }

    func testSpeakCopiedTextClearsActiveBuffer() {
        // WHY: Once audio is buffered the button becomes "Clear Buffer"; speakCopiedText must then
        // tear playback down (stop streaming + discard buffered audio) rather than start a new read.
        // If it didn't, the button would advertise a clear that never happens.
        let audioPlayer = AudioPlayerManager()
        let textExtraction = TextExtractionManager(pasteboard: FakePasteboardReader())
        let networkManager = TestNetworkFactory.makeManager()
        let view = makeMenu(audioPlayer: audioPlayer, textExtraction: textExtraction, networkManager: networkManager)

        networkManager.updateSettings(baseURL: "not a valid endpoint", apiKey: "fake-key", model: "test", voice: "test")
        networkManager.streamTTS(text: "Create an error before clearing") { _ in }
        XCTAssertNotNil(networkManager.lastError)

        // Set the view's branch condition without scheduling live AVAudioEngine work. Audio
        // scheduling is covered by AudioPlayerManagerTests; this test owns only menu behavior.
        audioPlayer.hasAudio = true

        view.speakCopiedText()

        let cleared = XCTestExpectation(description: "Buffer cleared")
        DispatchQueue.main.async {
            XCTAssertFalse(audioPlayer.hasAudio)
            XCTAssertNil(networkManager.lastError)
            cleared.fulfill()
        }
        wait(for: [cleared], timeout: 1.0)
    }

    func testRenderedErrorMessageAppearsAfterNetworkFailureWithoutRemovingControls() {
        // WHY: The request error is supplementary feedback, not a replacement for playback
        // controls. Mounting the view verifies SwiftUI actually renders the conditional message
        // while keeping the primary playback control available.
        let audioPlayer = AudioPlayerManager()
        let textExtraction = TextExtractionManager(pasteboard: FakePasteboardReader())
        let networkManager = TestNetworkFactory.makeManager()
        let view = makeMenu(audioPlayer: audioPlayer, textExtraction: textExtraction, networkManager: networkManager)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 280)

        host.layoutSubtreeIfNeeded()
        let errorMessage = "TTS configuration is invalid. Check the API endpoint and try again."
        XCTAssertNil(host.descendantText(equalTo: errorMessage))
        XCTAssertNotNil(host.descendantView(of: NSSlider.self))

        networkManager.updateSettings(baseURL: "not a valid endpoint", apiKey: "fake-key", model: "test", voice: "test")
        networkManager.streamTTS(text: "Show error") { _ in }

        let rendered = expectation(description: "Error message rendered")
        DispatchQueue.main.async {
            host.layoutSubtreeIfNeeded()
            XCTAssertNotNil(host.descendantText(equalTo: errorMessage))
            XCTAssertNotNil(host.descendantView(of: NSSlider.self))
            rendered.fulfill()
        }
        wait(for: [rendered], timeout: 1.0)
    }

}

private extension NSView {
    func descendantText(equalTo value: String) -> NSTextField? {
        if let textField = self as? NSTextField, textField.stringValue == value {
            return textField
        }
        return subviews.lazy.compactMap { $0.descendantText(equalTo: value) }.first
    }

    func descendantView<ViewType: NSView>(of type: ViewType.Type) -> ViewType? {
        if let view = self as? ViewType {
            return view
        }
        return subviews.lazy.compactMap { $0.descendantView(of: type) }.first
    }
}
