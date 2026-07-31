import XCTest
@testable import ClipboardTTSApp

final class TTSNetworkManagerAuthenticationTests: MockURLProtocolTestCase {
    func testUnknownPersistedProviderUsesOpenAIConfigurationBeforeSettingsOpen() throws {
        // WHY: Services can start speech before Settings is constructed. A corrupted provider value
        // must not combine one provider's Keychain key with another provider's persisted endpoint.
        isolateAppSettingsDefaults()
        let store = InMemorySecretStore()
        try store.saveSecret("test-openai-api-key", for: .openAI)
        try store.saveSecret("test-custom-api-key", for: .custom)
        UserDefaults.standard.set("Unexpected", forKey: SettingsKeys.ttsProvider)
        UserDefaults.standard.set("https://custom.example/v1/audio/speech", forKey: SettingsKeys.apiBaseURL)

        let manager = TestNetworkFactory.makeManager(secretStore: store)
        let requestEmitted = expectation(description: "A normalized OpenAI request is emitted")
        MockURLProtocol.installRequestHandler { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/audio/speech")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-openai-api-key")
            XCTAssertFalse(request.url?.absoluteString.contains("test-openai-api-key") ?? true)
            requestEmitted.fulfill()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data([0, 1]))
        }

        manager.streamTTS(text: "Normalize persisted provider") { _ in }
        wait(for: [requestEmitted], timeout: 2.0)
    }

    func testSettingsNormalizesUnknownProviderBeforeTestingVoice() throws {
        // WHY: Opening Settings must preserve the same safe provider normalization as startup;
        // otherwise Test Voice could disclose a provider key to a corrupted Custom endpoint.
        isolateAppSettingsDefaults()
        let store = InMemorySecretStore()
        try store.saveSecret("test-openai-api-key", for: .openAI)
        try store.saveSecret("test-custom-api-key", for: .custom)
        UserDefaults.standard.set("Unexpected", forKey: SettingsKeys.ttsProvider)
        UserDefaults.standard.set("https://custom.example/v1/audio/speech", forKey: SettingsKeys.apiBaseURL)

        let audioPlayer = AudioPlayerManager()
        let manager = TestNetworkFactory.makeManager(secretStore: store)
        let view = SettingsView(networkManager: manager, audioPlayer: audioPlayer, secretStore: store)
        let requestEmitted = expectation(description: "Settings uses a normalized OpenAI request")
        MockURLProtocol.installRequestHandler { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/audio/speech")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-openai-api-key")
            XCTAssertFalse(request.url?.absoluteString.contains("test-openai-api-key") ?? true)
            requestEmitted.fulfill()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data([0, 1]))
        }

        view.runTestVoice()
        wait(for: [requestEmitted], timeout: 2.0)
    }

    func testFailedSettingsSecretEditRetainsItsActionableError() throws {
        // WHY: A failed Keychain write must remain visible. Retrying an automatic restoration used
        // to erase the warning even though the user's new key was never saved.
        isolateAppSettingsDefaults()
        let store = InMemorySecretStore()
        try store.saveSecret("test-original-custom-key", for: .custom)
        let secretState = SettingsSecretState(secretStore: store)
        store.nextError = .unavailable

        secretState.saveSecret("test-new-custom-key", for: .custom)

        XCTAssertEqual(
            secretState.errorMessage,
            "Couldn't save the Custom API key. Check Keychain access and try again."
        )
        XCTAssertEqual(try store.secret(for: .custom), "test-original-custom-key")
    }

    func testProviderCredentialsUseOnlyTheirDocumentedHeaders() {
        // WHY: Keys in a URL can escape through proxies and diagnostics. Each provider must send
        // its token only in its authentication header, while app-owned state remains secret-free.
        isolateAppSettingsDefaults()
        let providers = [
            (name: "OpenAI", baseURL: "https://mock.api/v1/audio/speech", selectedProvider: "OpenAI", header: "Authorization", value: "Bearer test-openai-api-key"),
            (name: "Gemini", baseURL: "https://generativelanguage.googleapis.com/v1beta", selectedProvider: "Gemini", header: "x-goog-api-key", value: "test-gemini-api-key"),
            (name: "Custom", baseURL: "https://custom.api/v1/audio/speech", selectedProvider: "Custom", header: "Authorization", value: "Bearer test-custom-api-key")
        ]

        for provider in providers {
            let manager = TestNetworkFactory.makeManager()
            let token = provider.value.replacingOccurrences(of: "Bearer ", with: "")
            manager.updateSettings(
                baseURL: provider.baseURL,
                apiKey: token,
                model: "test-model",
                voice: "test-voice",
                selectedProvider: provider.selectedProvider
            )
            let requestEmitted = expectation(description: "\(provider.name) request is emitted")
            MockURLProtocol.installRequestHandler { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: provider.header), provider.value)
                XCTAssertFalse(request.url?.absoluteString.contains(token) ?? true)
                if provider.name == "Gemini" {
                    XCTAssertEqual(request.url?.query, "alt=sse")
                    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                } else {
                    XCTAssertNil(request.url?.query)
                    XCTAssertNil(request.value(forHTTPHeaderField: "x-goog-api-key"))
                }
                requestEmitted.fulfill()
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, Data([0, 1]))
            }

            manager.streamTTS(text: "Verify \(provider.name) authentication") { _ in }
            wait(for: [requestEmitted], timeout: 2.0)
            XCTAssertFalse(SettingsKeys.allUserDefaultsKeys.contains { UserDefaults.standard.string(forKey: $0) == token })
        }
    }
}
