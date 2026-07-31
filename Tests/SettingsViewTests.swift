import XCTest
import SwiftUI
import AVFoundation
@testable import ClipboardTTSApp

final class SettingsViewTests: MockURLProtocolTestCase {

    func testCustomSampleRatePersistsAndOtherProvidersResetTo24KHz() {
        // WHY: Only Custom PCM may use a user override. Switching away must reset the live graph
        // to the documented provider format so a later OpenAI or Gemini response is never decoded
        // at the previous Custom rate.
        isolateAppSettingsDefaults()
        UserDefaults.standard.set("Custom", forKey: SettingsKeys.ttsProvider)
        UserDefaults.standard.set(48_000.0, forKey: SettingsKeys.customSampleRate)

        let secretStore = InMemorySecretStore()
        let audioPlayer = AudioPlayerManager()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore)
        let view = SettingsView(networkManager: networkManager, audioPlayer: audioPlayer, secretStore: secretStore)

        view.syncSettings()
        XCTAssertEqual(audioPlayer.sampleRate, 48_000)

        MockURLProtocol.installRequestHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("{ \"data\": [] }".utf8))
        }
        UserDefaults.standard.set("OpenAI", forKey: SettingsKeys.ttsProvider)
        view.providerDidChange(to: "OpenAI")

        XCTAssertEqual(audioPlayer.sampleRate, 24_000)
    }

    func testInvalidCustomSampleRateIsReportedWithoutStartingTestVoice() {
        // WHY: The Settings field must refuse invalid PCM rates before a Test Voice request can
        // stream bytes into an unchanged graph, and its established error is rendered inline.
        isolateAppSettingsDefaults()
        UserDefaults.standard.set("Custom", forKey: SettingsKeys.ttsProvider)
        UserDefaults.standard.set(48_001.0, forKey: SettingsKeys.customSampleRate)

        let secretStore = InMemorySecretStore()
        let audioPlayer = AudioPlayerManager()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore)
        let view = SettingsView(networkManager: networkManager, audioPlayer: audioPlayer, secretStore: secretStore)
        MockURLProtocol.installRequestHandler { _ in
            XCTFail("An invalid PCM rate must not start Test Voice")
            return (HTTPURLResponse(), Data())
        }

        view.runTestVoice()

        XCTAssertEqual(audioPlayer.sampleRate, 24_000)
        XCTAssertEqual(audioPlayer.sampleRateError, "PCM sample rate must be a finite value from 8,000 to 48,000 Hz.")
        XCTAssertFalse(networkManager.isStreaming)
    }

    func testInvalidCustomSampleRateEditKeepsTheLastKnownGoodPersistedValue() {
        // WHY: A malformed draft must remain visible for correction without becoming startup
        // configuration. Otherwise a relaunch could silently decode Custom PCM at the default rate.
        isolateAppSettingsDefaults()
        UserDefaults.standard.set("Custom", forKey: SettingsKeys.ttsProvider)
        UserDefaults.standard.set(24_000.0, forKey: SettingsKeys.customSampleRate)

        let secretStore = InMemorySecretStore()
        let audioPlayer = AudioPlayerManager()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore)
        let view = SettingsView(networkManager: networkManager, audioPlayer: audioPlayer, secretStore: secretStore)

        view.updateCustomSampleRate(from: "48001")

        XCTAssertEqual(UserDefaults.standard.double(forKey: SettingsKeys.customSampleRate), 24_000)
        XCTAssertFalse(audioPlayer.hasValidSampleRateConfiguration)
        XCTAssertEqual(audioPlayer.sampleRateError, "PCM sample rate must be a finite value from 8,000 to 48,000 Hz.")
    }

    func testInvalidCustomSampleRateDraftBlocksTestVoiceAndSubsequentSettingsSync() {
        // WHY: A visible invalid draft must remain the active validation state until corrected.
        // Otherwise a later sync could silently recover the saved 24-kHz graph and speak despite
        // the field still showing a Custom format the app refuses to decode.
        isolateAppSettingsDefaults()
        UserDefaults.standard.set("Custom", forKey: SettingsKeys.ttsProvider)
        let secretStore = InMemorySecretStore()
        let audioPlayer = AudioPlayerManager()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore)
        let view = SettingsView(networkManager: networkManager, audioPlayer: audioPlayer, secretStore: secretStore)
        MockURLProtocol.installRequestHandler { _ in
            XCTFail("An invalid Custom PCM draft must not start Test Voice")
            return (HTTPURLResponse(), Data())
        }

        view.updateCustomSampleRate(from: "48001")
        view.syncSettings()

        XCTAssertEqual(audioPlayer.sampleRateError, "PCM sample rate must be a finite value from 8,000 to 48,000 Hz.")
        XCTAssertFalse(networkManager.isStreaming)

        view.runTestVoice()

        XCTAssertEqual(audioPlayer.sampleRateError, "PCM sample rate must be a finite value from 8,000 to 48,000 Hz.")
        XCTAssertFalse(networkManager.isStreaming)
    }

    func testTestVoiceDoesNotStartRequestWhenDefaultRateEngineCannotRecover() {
        // WHY: A sample rate can match the selected provider while its graph failed to start.
        // Test Voice must retry that graph and keep its failure visible instead of sending a TTS
        // request that cannot play.
        isolateAppSettingsDefaults()
        let secretStore = InMemorySecretStore()
        let audioPlayer = AudioPlayerManager(engineStarter: { _ in throw EngineStartFailure.failed })
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore)
        let view = SettingsView(networkManager: networkManager, audioPlayer: audioPlayer, secretStore: secretStore)
        MockURLProtocol.installRequestHandler { _ in
            XCTFail("A stopped audio graph must not start Test Voice")
            return (HTTPURLResponse(), Data())
        }

        view.runTestVoice()

        XCTAssertEqual(audioPlayer.sampleRate, 24_000)
        XCTAssertEqual(audioPlayer.sampleRateError, "Couldn't start audio playback. Try again.")
        XCTAssertFalse(networkManager.isStreaming)
    }

    func testCustomTestVoiceEmitsConfiguredOpenAICompatiblePayload() {
        // WHY: Test Voice must synchronize persisted Custom settings into the production request
        // path, so an endpoint test proves the same model/voice contract as normal speech.
        isolateAppSettingsDefaults()

        UserDefaults.standard.set("Custom", forKey: SettingsKeys.ttsProvider)
        UserDefaults.standard.set("test-custom-key", forKey: SettingsKeys.legacyCustomAPIKey)
        UserDefaults.standard.set("https://custom.api/v1/audio/speech", forKey: SettingsKeys.apiBaseURL)
        UserDefaults.standard.set("custom-model", forKey: SettingsKeys.customModel)
        UserDefaults.standard.set("custom-voice", forKey: SettingsKeys.customVoice)

        let secretStore = InMemorySecretStore()
        let audioPlayer = AudioPlayerManager()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore)
        let view = SettingsView(networkManager: networkManager, audioPlayer: audioPlayer, secretStore: secretStore)

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

        let secretStore = InMemorySecretStore()
        let audioPlayer = AudioPlayerManager()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore)
        let view = SettingsView(networkManager: networkManager, audioPlayer: audioPlayer, secretStore: secretStore)
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

        let secretStore = InMemorySecretStore()
        let audioPlayer = AudioPlayerManager()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore)
        let view = SettingsView(networkManager: networkManager, audioPlayer: audioPlayer, secretStore: secretStore)

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

private enum EngineStartFailure: Error {
    case failed
}
