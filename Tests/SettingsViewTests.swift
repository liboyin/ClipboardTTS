import XCTest
import SwiftUI
@testable import ClipboardTTSApp

final class SettingsViewTests: MockURLProtocolTestCase {

    func testSettingsViewMethods() {
        isolateAppSettingsDefaults()

        let audioPlayer = AudioPlayerManager()
        let networkManager = TestNetworkFactory.makeManager()
        let view = SettingsView(networkManager: networkManager, audioPlayer: audioPlayer)

        let metadataRequests = expectation(description: "OpenAI metadata requests are mock routed")
        metadataRequests.expectedFulfillmentCount = 2
        MockURLProtocol.installRequestHandler { request in
            metadataRequests.fulfill()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("{ \"data\": [] }".utf8))
        }

        UserDefaults.standard.set("OpenAI", forKey: "ttsProvider")
        UserDefaults.standard.set("test-openai-key", forKey: "apiKey")
        UserDefaults.standard.set("tts-1-hd", forKey: "openaiModel")
        UserDefaults.standard.set("nova", forKey: "openaiVoice")
        XCTAssertEqual(view.currentBaseURL, "https://api.openai.com/v1/audio/speech")
        XCTAssertEqual(view.currentAPIKey, "test-openai-key")
        XCTAssertEqual(view.currentModel, "tts-1-hd")
        XCTAssertEqual(view.currentVoice, "nova")
        view.syncSettings()
        view.fetchMetadata()
        wait(for: [metadataRequests], timeout: 2.0)

        UserDefaults.standard.set("Gemini", forKey: "ttsProvider")
        UserDefaults.standard.set("test-gemini-key", forKey: "geminiAPIKey")
        UserDefaults.standard.set("gemini-tts", forKey: "geminiModel")
        UserDefaults.standard.set("Kore", forKey: "geminiVoice")
        XCTAssertEqual(view.currentBaseURL, "https://generativelanguage.googleapis.com/v1beta")
        XCTAssertEqual(view.currentAPIKey, "test-gemini-key")
        XCTAssertEqual(view.currentModel, "gemini-tts")
        XCTAssertEqual(view.currentVoice, "Kore")
        view.syncSettings()

        UserDefaults.standard.set("Custom", forKey: "ttsProvider")
        UserDefaults.standard.set("test-custom-key", forKey: "customAPIKey")
        UserDefaults.standard.set("https://custom.api", forKey: "apiBaseURL")
        XCTAssertEqual(view.currentBaseURL, "https://custom.api")
        XCTAssertEqual(view.currentAPIKey, "test-custom-key")
        // Custom provider sends no model/voice; the request body omits them by design.
        XCTAssertEqual(view.currentModel, "")
        XCTAssertEqual(view.currentVoice, "")
        view.syncSettings()
    }

    func testProviderDidChangeAndTestVoice() {
        // Isolated even though this test writes nothing: SettingsView reads the provider from
        // UserDefaults.standard, so without it the exercised code path depends on machine state.
        isolateAppSettingsDefaults()

        let audioPlayer = AudioPlayerManager()
        let networkManager = TestNetworkFactory.makeManager()
        let view = SettingsView(networkManager: networkManager, audioPlayer: audioPlayer)

        // providerDidChange fetches metadata, so its local handler must be installed before it runs.
        MockURLProtocol.installRequestHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("{ \"data\": [] }".utf8))
        }

        view.providerDidChange(to: "OpenAI")
        view.providerDidChange(to: "Gemini")

        view.runTestVoice()

        // Let async execute
        let expectation = XCTestExpectation(description: "Wait for test voice")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            XCTAssertFalse(networkManager.isStreaming)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)
    }
}
