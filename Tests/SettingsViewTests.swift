import XCTest
import SwiftUI
@testable import ClipboardTTSApp

final class SettingsViewTests: XCTestCase {
    
    func testSettingsViewBody() {
        // WHY: Check that the settings view can be evaluated without crashing.
        let audioPlayer = AudioPlayerManager()
        let networkManager = TTSNetworkManager(configuration: .ephemeral)
        
        let view = SettingsView(networkManager: networkManager, audioPlayer: audioPlayer)
        
        let body = view.body
        XCTAssertNotNil(body)
    }
    
    func testSettingsViewProviders() {
        let audioPlayer = AudioPlayerManager()
        let networkManager = TTSNetworkManager(configuration: .ephemeral)
        
        let providers = ["OpenAI", "Gemini", "Custom"]
        
        for provider in providers {
            UserDefaults.standard.set(provider, forKey: "ttsProvider")
            let view = SettingsView(networkManager: networkManager, audioPlayer: audioPlayer)
            let body = view.body
            XCTAssertNotNil(body)
        }
    }
    
    func testSettingsViewMethods() {
        let audioPlayer = AudioPlayerManager()
        let networkManager = TTSNetworkManager(configuration: .ephemeral)
        let view = SettingsView(networkManager: networkManager, audioPlayer: audioPlayer)
        
        UserDefaults.standard.set("OpenAI", forKey: "ttsProvider")
        UserDefaults.standard.set("test-openai-key", forKey: "apiKey")
        XCTAssertEqual(view.currentBaseURL, "https://api.openai.com/v1/audio/speech")
        XCTAssertEqual(view.currentAPIKey, "test-openai-key")
        view.syncSettings()
        view.fetchMetadata()
        
        UserDefaults.standard.set("Gemini", forKey: "ttsProvider")
        UserDefaults.standard.set("test-gemini-key", forKey: "geminiAPIKey")
        XCTAssertEqual(view.currentBaseURL, "https://generativelanguage.googleapis.com/v1beta")
        XCTAssertEqual(view.currentAPIKey, "test-gemini-key")
        view.syncSettings()
        
        UserDefaults.standard.set("Custom", forKey: "ttsProvider")
        UserDefaults.standard.set("test-custom-key", forKey: "customAPIKey")
        UserDefaults.standard.set("https://custom.api", forKey: "apiBaseURL")
        XCTAssertEqual(view.currentBaseURL, "https://custom.api")
        XCTAssertEqual(view.currentAPIKey, "test-custom-key")
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
