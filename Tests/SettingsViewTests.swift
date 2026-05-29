import XCTest
import SwiftUI
@testable import ClipboardTTSApp

final class SettingsViewTests: XCTestCase {
    
    func testSettingsViewMethods() {
        let audioPlayer = AudioPlayerManager()
        let networkManager = TTSNetworkManager(configuration: .ephemeral)
        let view = SettingsView(networkManager: networkManager, audioPlayer: audioPlayer)
        
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
        let audioPlayer = AudioPlayerManager()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let networkManager = TTSNetworkManager(configuration: config)
        let view = SettingsView(networkManager: networkManager, audioPlayer: audioPlayer)
        
        view.providerDidChange(to: "OpenAI")
        view.providerDidChange(to: "Gemini")
        
        MockURLProtocol.requestHandler = { request in
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        
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
