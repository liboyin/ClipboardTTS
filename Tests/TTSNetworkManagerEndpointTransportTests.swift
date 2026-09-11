import XCTest
@testable import ClipboardTTSApp

/// Covers what the endpoint transport rule does to a real request: which endpoints still send the
/// complete contract, and which are refused before a task or a credential can exist.
/// `EndpointTransportPolicyTests` owns the rule itself, and `TTSNetworkManagerRedirectTests` owns
/// what the credential rules do to a request already in flight.
final class TTSNetworkManagerEndpointTransportTests: MockURLProtocolTestCase {
    private static let insecureTransportError =
        "The TTS endpoint must use HTTPS unless it runs on localhost. Update Settings and try again."
    private static let invalidConfigurationError =
        "TTS configuration is invalid. Check the API endpoint and try again."

    func testHTTPSAndLoopbackCustomEndpointsSendTheCompleteRequestContract() {
        // WHY: Refusing cleartext must not quietly narrow what a supported Custom endpoint may be.
        // HTTPS and a loopback local engine both still send the whole documented contract, key
        // included, so the rule cannot be "satisfied" by dropping requests the user expects to run.
        let endpoints = [
            "https://custom.api/v1/audio/speech",
            "http://localhost:8080/v1/audio/speech",
            "http://127.0.0.1:8080/v1/audio/speech",
            "http://[::1]:8080/v1/audio/speech"
        ]

        for endpoint in endpoints {
            let manager = TestNetworkFactory.makeManager()
            manager.updateSettings(
                baseURL: endpoint,
                apiKey: "test-custom-api-key",
                model: "test-model",
                voice: "test-voice",
                selectedProvider: "Custom"
            )
            let requestEmitted = expectation(description: "\(endpoint) emits its request")
            MockURLProtocol.installRequestHandler { request in
                XCTAssertEqual(request.url?.absoluteString, endpoint)
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-custom-api-key")
                XCTAssertFalse(request.url?.absoluteString.contains("test-custom-api-key") ?? true)
                let body = requestBodyData(from: request)
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: String]
                XCTAssertEqual(body?["model"], "test-model")
                XCTAssertEqual(body?["voice"], "test-voice")
                XCTAssertEqual(body?["input"], "Speak through \(endpoint)")
                XCTAssertEqual(body?["response_format"], "pcm")
                requestEmitted.fulfill()
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, Data([0, 1]))
            }

            manager.streamTTS(text: "Speak through \(endpoint)") { _ in }
            wait(for: [requestEmitted], timeout: 2.0)
        }
    }

    func testCleartextEndpointsAreRefusedBeforeAnyRequestOrCredentialLeaves() {
        // WHY: A cleartext remote endpoint would put the saved key and the user's clipboard text on
        // the wire, so the app must refuse it itself, before a task exists, rather than rely on a
        // transport layer it does not configure. Each entry reaches a host that is not this
        // machine's loopback interface, however local it reads. No handler is installed here: this
        // scope's unhandled-request accounting fails the test if any of them creates a request.
        let key = "conspicuous-cleartext-key-4242"
        let refusals = [
            (endpoint: "http://tts.example.com/v1/audio/speech",
             provider: "Custom", message: Self.insecureTransportError),
            (endpoint: "http://192.168.1.10:8080/v1/audio/speech",
             provider: "Custom", message: Self.insecureTransportError),
            (endpoint: "http://localhost.example.com/v1/audio/speech",
             provider: "Custom", message: Self.insecureTransportError),
            (endpoint: "http://127.0.0.1.example.com/v1/audio/speech",
             provider: "Custom", message: Self.insecureTransportError),
            (endpoint: "http://127.0.0.1@example.com/v1/audio/speech",
             provider: "Custom", message: Self.insecureTransportError),
            (endpoint: "http://generativelanguage.googleapis.com/v1beta",
             provider: "Gemini", message: Self.insecureTransportError),
            (endpoint: "http:///v1/audio/speech",
             provider: "Custom", message: Self.invalidConfigurationError),
            (endpoint: "ftp://localhost/v1/audio/speech",
             provider: "Custom", message: Self.invalidConfigurationError)
        ]

        for refusal in refusals {
            let defaults = makeOwnedDefaults()
            let manager = TestNetworkFactory.makeManager(defaults: defaults)
            manager.updateSettings(
                baseURL: refusal.endpoint,
                apiKey: key,
                model: "test-model",
                voice: "test-voice",
                selectedProvider: refusal.provider
            )

            manager.streamTTS(text: "Speak through \(refusal.endpoint)") { _ in
                XCTFail("A refused endpoint must not produce audio.")
            }

            XCTAssertEqual(manager.lastError, refusal.message, "\(refusal.endpoint) must publish its own refusal.")
            XCTAssertFalse(manager.isStreaming, "\(refusal.endpoint) must not report an active stream.")
            XCTAssertFalse(manager.lastError?.contains(key) ?? true, "A refusal must not disclose the key.")
            XCTAssertFalse(
                manager.lastError?.contains(refusal.endpoint) ?? true,
                "A refusal must not echo a user-controlled endpoint."
            )
            XCTAssertFalse(
                SettingsKeys.allUserDefaultsKeys.contains { defaults.string(forKey: $0) == key },
                "A refused request must not leave the key it would have carried in preferences."
            )
        }
    }
}
