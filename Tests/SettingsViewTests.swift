import XCTest
import SwiftUI
@testable import ClipboardTTSApp

final class SettingsViewTests: MockURLProtocolTestCase {

    func testCustomTestVoiceEmitsConfiguredOpenAICompatiblePayload() {
        // WHY: Test Voice must synchronize persisted Custom settings into the production request
        // path, so an endpoint test proves the same model/voice contract as normal speech.
        isolateAppSettingsDefaults()

        UserDefaults.standard.set("Custom", forKey: SettingsKeys.ttsProvider)
        UserDefaults.standard.set("test-custom-key", forKey: SettingsKeys.legacyCustomAPIKey)
        UserDefaults.standard.set("https://custom.api/v1/audio/speech", forKey: SettingsKeys.apiBaseURL)
        UserDefaults.standard.set("custom-model", forKey: SettingsKeys.customModel)
        UserDefaults.standard.set("custom-voice", forKey: SettingsKeys.customVoice)

        let audioPlayer = AudioPlayerManager()
        let networkManager = TestNetworkFactory.makeManager()
        let view = SettingsView(networkManager: networkManager, audioPlayer: audioPlayer)

        let requestEmitted = expectation(description: "Custom Test Voice request is emitted")
        MockURLProtocol.installRequestHandler { request in
            XCTAssertEqual(request.url?.absoluteString, "https://custom.api/v1/audio/speech")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-custom-key")
            let bodyData = try XCTUnwrap(requestBodyData(from: request))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: String])
            XCTAssertEqual(Set(body.keys), ["model", "input", "voice", "response_format"])
            XCTAssertEqual(body["model"], "custom-model")
            XCTAssertEqual(body["voice"], "custom-voice")
            XCTAssertEqual(body["response_format"], "pcm")
            requestEmitted.fulfill()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data([0, 1]))
        }

        view.runTestVoice()
        wait(for: [requestEmitted], timeout: 2.0)
    }

    func testCustomTestVoiceRejectsWhitespaceConfigurationWithoutStartingARequest() {
        // WHY: Test Voice must use the same Custom validation as clipboard and Services speech.
        // Otherwise a test action could contact an endpoint with a configuration normal speech
        // correctly rejects, making Settings appear to work while it uses a different contract.
        isolateAppSettingsDefaults()
        UserDefaults.standard.set("Custom", forKey: SettingsKeys.ttsProvider)
        UserDefaults.standard.set("https://custom.api/v1/audio/speech", forKey: SettingsKeys.apiBaseURL)
        UserDefaults.standard.set("\n\t ", forKey: SettingsKeys.customModel)
        UserDefaults.standard.set("custom-voice", forKey: SettingsKeys.customVoice)

        let audioPlayer = AudioPlayerManager()
        let networkManager = TestNetworkFactory.makeManager()
        let view = SettingsView(networkManager: networkManager, audioPlayer: audioPlayer)
        MockURLProtocol.installRequestHandler { _ in
            XCTFail("Invalid Custom Test Voice configuration must not contact the endpoint")
            return (HTTPURLResponse(), Data())
        }

        view.runTestVoice()

        XCTAssertEqual(networkManager.lastError, "Custom TTS requires a model and voice. Update Settings and try again.")
        XCTAssertFalse(networkManager.isStreaming)
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
