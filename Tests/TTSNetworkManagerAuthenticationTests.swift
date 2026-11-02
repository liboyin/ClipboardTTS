import XCTest
@testable import ClipboardTTSApp

final class TTSNetworkManagerAuthenticationTests: MockURLProtocolTestCase {
    func testUnknownPersistedProviderUsesOpenAIConfigurationBeforeSettingsOpen() throws {
        // WHY: Services can start speech before Settings is constructed. A corrupted provider value
        // must not combine one provider's Keychain key with another provider's persisted endpoint.
        let store = InMemorySecretStore()
        try store.saveSecret("test-openai-api-key", for: .openAI)
        try store.saveSecret("test-custom-api-key", for: .custom)
        let defaults = makeOwnedDefaults([
            SettingsKeys.ttsProvider: "Unexpected",
            SettingsKeys.apiBaseURL: "https://custom.example/v1/audio/speech"
        ])

        let connections = ScriptedRealtimeConnections()
        let manager = TestNetworkFactory.makeManager(secretStore: store, defaults: defaults, realtimeConnections: connections)
        MockURLProtocol.installRequestHandler { request in
            XCTFail("A normalized OpenAI request must not reach \(request.url?.absoluteString ?? "an HTTP endpoint").")
            return (HTTPURLResponse(), Data())
        }

        manager.streamTTS(text: "Normalize persisted provider") { _ in }

        let connection = try XCTUnwrap(connections.all.first, "A normalized OpenAI request must open a Realtime connection.")
        addTeardownBlock { connection.cancel(); connection.drain() }
        XCTAssertEqual(connection.request.url?.absoluteString, "wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1-mini")
        XCTAssertEqual(connection.request.value(forHTTPHeaderField: "Authorization"), "Bearer test-openai-api-key")
        XCTAssertFalse(connection.request.url?.absoluteString.contains("test-openai-api-key") ?? true)
    }

    // Hosted Settings drives `NSHostingView` and the AppKit controls it builds, so this test runs
    // on the main actor; the rest of this class does not use it.
    @MainActor
    func testSettingsNormalizesUnknownProviderBeforeTestingVoice() throws {
        // WHY: Opening Settings must preserve the same safe provider normalization as startup;
        // otherwise Test Voice could disclose a provider key to a corrupted Custom endpoint.
        let store = InMemorySecretStore()
        try store.saveSecret("test-openai-api-key", for: .openAI)
        try store.saveSecret("test-custom-api-key", for: .custom)
        let defaults = makeOwnedDefaults([
            SettingsKeys.ttsProvider: "Unexpected",
            SettingsKeys.apiBaseURL: "https://custom.example/v1/audio/speech"
        ])

        let audioPlayer = makeOwnedAudioPlayer()
        let requestEmitted = expectation(description: "Settings uses a normalized OpenAI request")
        let connections = ScriptedRealtimeConnections { connection in
            XCTAssertEqual(connection.request.url?.host, "api.openai.com")
            XCTAssertEqual(connection.request.value(forHTTPHeaderField: "Authorization"), "Bearer test-openai-api-key")
            XCTAssertFalse(connection.request.url?.absoluteString.contains("test-openai-api-key") ?? true)
            requestEmitted.fulfill()
        }
        addTeardownBlock { connections.all.forEach { $0.cancel() }; connections.drain() }
        let manager = TestNetworkFactory.makeManager(secretStore: store, defaults: defaults, realtimeConnections: connections)
        // Opening Settings publishes the normalized provider's catalogs, which need no request, so
        // nothing that carries the key may reach the corrupted Custom endpoint or any other.
        MockURLProtocol.installRequestHandler { request in
            XCTFail("Settings must not contact \(request.url?.absoluteString ?? "an HTTP endpoint") for a normalized OpenAI provider.")
            return (HTTPURLResponse(), Data())
        }
        let settings = HostedSettings(
            networkManager: manager,
            audioPlayer: audioPlayer,
            secretStore: store,
            defaults: defaults,
            testCase: self
        )

        settings.click("Test Voice")

        wait(for: [requestEmitted], timeout: 2.0)
        settings.release()
    }

    func testFailedSettingsSecretEditRetainsItsActionableError() throws {
        // WHY: A failed Keychain write must remain visible. Retrying an automatic restoration used
        // to erase the warning even though the user's new key was never saved.
        let store = InMemorySecretStore()
        try store.saveSecret("test-original-custom-key", for: .custom)
        let defaults = makeOwnedDefaults()
        let secretState = SettingsSecretState(secretStore: store, defaults: defaults)
        store.nextError = .unavailable

        secretState.saveSecret("test-new-custom-key", for: .custom)

        XCTAssertEqual(
            secretState.errorMessage,
            "Couldn't save the Custom API key. Check Keychain access and try again."
        )
        XCTAssertEqual(try store.secret(for: .custom), "test-original-custom-key")
    }

    func testSecuringEveryPendingKeyWithdrawsTheStartupMigrationWarning() {
        // WHY: The warning is the app's own claim that a saved key is still sitting in preferences.
        // Leaving it up after the user's retry secured every one of them would send them back to a
        // Keychain problem they already solved.
        let defaults = makeOwnedDefaults([
            SettingsKeys.ttsProvider: "Custom",
            SettingsKeys.legacyCustomAPIKey: "test-legacy-custom-key"
        ])
        let store = InMemorySecretStore()
        store.nextError = .unavailable
        let manager = TestNetworkFactory.makeManager(secretStore: store, defaults: defaults)
        XCTAssertEqual(manager.lastError, APIKeyMigrationService.failureMessage(for: .custom))

        manager.updateMigrationFailureWarning(for: nil)

        XCTAssertNil(manager.lastError)
    }

    func testWithdrawingTheMigrationWarningCannotEraseANewerRequestFailure() {
        // WHY: Migration guidance and request failures share one menu-bar channel. Securing a key
        // resolves nothing about a request that failed afterwards, so withdrawing the warning must
        // not silence the guidance the user still needs to make the app speak.
        let defaults = makeOwnedDefaults([
            SettingsKeys.ttsProvider: "Custom",
            SettingsKeys.legacyCustomAPIKey: "test-legacy-custom-key"
        ])
        let store = InMemorySecretStore()
        store.nextError = .unavailable
        let manager = TestNetworkFactory.makeManager(secretStore: store, defaults: defaults)
        XCTAssertEqual(manager.lastError, APIKeyMigrationService.failureMessage(for: .custom))
        let requestFailure = "The TTS endpoint must use HTTPS unless it runs on localhost. Update Settings and try again."
        manager.updateSettings(
            baseURL: "http://custom.api/v1/audio/speech",
            apiKey: "test-custom-key",
            model: "custom-model",
            voice: "custom-voice",
            selectedProvider: "Custom"
        )
        assertTerminalState(of: manager, expectedError: requestFailure) {
            manager.streamTTS(text: "Speech a cleartext endpoint must refuse") { _ in }
        }

        manager.updateMigrationFailureWarning(for: nil)

        XCTAssertEqual(manager.lastError, requestFailure)
    }

    func testProviderCredentialsUseOnlyTheirDocumentedHeaders() throws {
        // WHY: Keys in a URL can escape through proxies and diagnostics. Each provider must send
        // its token only in its authentication header, while app-owned state remains secret-free.
        let providers = [
            (name: "Gemini", baseURL: "https://generativelanguage.googleapis.com/v1beta", selectedProvider: "Gemini", header: "x-goog-api-key", value: "test-gemini-api-key"),
            (name: "Custom", baseURL: "https://custom.api/v1/audio/speech", selectedProvider: "Custom", header: "Authorization", value: "Bearer test-custom-api-key")
        ]

        for provider in providers {
            let defaults = makeOwnedDefaults()
            let manager = TestNetworkFactory.makeManager(defaults: defaults)
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
            XCTAssertFalse(SettingsKeys.allUserDefaultsKeys.contains { defaults.string(forKey: $0) == token })
        }

        // OpenAI authenticates its Realtime handshake the same way, and its query names only the model.
        let defaults = makeOwnedDefaults()
        let connections = ScriptedRealtimeConnections()
        let manager = TestNetworkFactory.makeManager(defaults: defaults, realtimeConnections: connections)
        manager.updateSettings(baseURL: OpenAIRealtimeSpeech.endpoint, apiKey: "test-openai-api-key",
                               model: "test-model", voice: "test-voice", selectedProvider: "OpenAI")
        manager.streamTTS(text: "Verify OpenAI authentication") { _ in }
        let connection = try XCTUnwrap(connections.all.first)
        addTeardownBlock { connection.cancel(); connection.drain() }
        XCTAssertEqual(connection.request.value(forHTTPHeaderField: "Authorization"), "Bearer test-openai-api-key")
        XCTAssertNil(connection.request.value(forHTTPHeaderField: "x-goog-api-key"))
        XCTAssertEqual(connection.request.url?.query, "model=test-model")
        XCTAssertFalse(connection.sentFrames.contains { $0.contains("test-openai-api-key") })
        XCTAssertFalse(SettingsKeys.allUserDefaultsKeys.contains { defaults.string(forKey: $0) == "test-openai-api-key" })
    }

    func testCustomGoogleLookingHostUsesTheOpenAICompatibleSpeechContract() {
        // WHY: A Custom hostname is provider-controlled text, not an identity. Treating this one
        // as Gemini would send the wrong URL, payload, and credential to a compatible server.
        let endpoint = "https://generativelanguage.googleapis.com.custom.example/v1/audio/speech"
        let manager = TestNetworkFactory.makeManager()
        manager.updateSettings(
            baseURL: endpoint,
            apiKey: "custom-token",
            model: "custom-model",
            voice: "custom-voice",
            selectedProvider: "Custom"
        )
        let requestEmitted = expectation(description: "Custom compatible request is emitted")
        MockURLProtocol.installRequestHandler { request in
            XCTAssertEqual(request.url?.absoluteString, endpoint)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer custom-token")
            XCTAssertNil(request.value(forHTTPHeaderField: "x-goog-api-key"))
            guard let bodyData = requestBodyData(from: request),
                  let body = try? JSONSerialization.jsonObject(with: bodyData) as? [String: String] else {
                XCTFail("A Custom endpoint must receive the OpenAI-compatible payload.")
                requestEmitted.fulfill()
                return (HTTPURLResponse(), Data())
            }
            XCTAssertEqual(body["model"], "custom-model")
            XCTAssertEqual(body["voice"], "custom-voice")
            XCTAssertEqual(body["response_format"], "pcm")
            requestEmitted.fulfill()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data([0, 1]))
        }

        manager.streamTTS(text: "Keep Custom compatible") { _ in }
        wait(for: [requestEmitted], timeout: 2.0)
    }

    func testMalformedDirectProviderIdentityNormalizesToOpenAI() throws {
        // WHY: Direct callers bypass the Settings sidebar, so normalization must happen before
        // the manager snapshots its request settings rather than only while the form is rendered.
        // Normalizing to OpenAI also means its one fixed endpoint, so the endpoint this caller
        // supplied must not receive the key.
        let endpoint = "https://generativelanguage.googleapis.com.custom.example/v1/audio/speech"
        let connections = ScriptedRealtimeConnections()
        let manager = TestNetworkFactory.makeManager(realtimeConnections: connections)
        manager.updateSettings(
            baseURL: endpoint,
            apiKey: "normalized-token",
            model: "openai-model",
            voice: "openai-voice",
            selectedProvider: "Malformed identity"
        )
        XCTAssertTrue(manager.isCurrentProvider(.openAI))
        MockURLProtocol.installRequestHandler { request in
            XCTFail("A normalized OpenAI request must not reach \(request.url?.absoluteString ?? "an HTTP endpoint").")
            return (HTTPURLResponse(), Data())
        }

        manager.streamTTS(text: "Normalize direct input") { _ in }

        let connection = try XCTUnwrap(connections.all.first)
        addTeardownBlock { connection.cancel(); connection.drain() }
        XCTAssertEqual(connection.request.url?.absoluteString, "wss://api.openai.com/v1/realtime?model=openai-model")
        XCTAssertEqual(connection.request.value(forHTTPHeaderField: "Authorization"), "Bearer normalized-token")
        XCTAssertNil(connection.request.value(forHTTPHeaderField: "x-goog-api-key"))
    }
}
