import XCTest
@testable import ClipboardTTSApp

/// Covers recovering in Settings from a legacy API key that migration could not secure.
///
/// Hosted Settings drives `NSHostingView` and the AppKit controls it builds, so every test here
/// runs on the main actor.
@MainActor
final class SettingsMigrationRecoveryTests: MockURLProtocolTestCase {

    func testFailedMigrationOffersARetryThatSecuresTheKeyForTheNextRequest() throws {
        // WHY: The failure message tells the user to try again, but migration otherwise reruns only
        // when a new manager is created, so "again" would mean an undocumented relaunch. Recovery
        // has to be reachable where the guidance appears, and it is finished only when the secured
        // key is what the next request sends — not merely when the warning disappears.
        UserDefaults.standard.set("Custom", forKey: SettingsKeys.ttsProvider)
        UserDefaults.standard.set("https://custom.api/v1/audio/speech", forKey: SettingsKeys.apiBaseURL)
        UserDefaults.standard.set("custom-model", forKey: SettingsKeys.customModel)
        UserDefaults.standard.set("custom-voice", forKey: SettingsKeys.customVoice)
        UserDefaults.standard.set("test-legacy-custom-key", forKey: SettingsKeys.legacyCustomAPIKey)

        let secretStore = ScriptedSecretStore()
        secretStore.failingProviders = [.custom]
        let audioPlayer = AudioPlayerManager()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore)
        XCTAssertEqual(networkManager.lastError, APIKeyMigrationService.failureMessage(for: .custom))
        secretStore.failingProviders = []

        let requestEmitted = expectation(description: "The secured key reaches the next request")
        MockURLProtocol.installRequestHandler { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-legacy-custom-key")
            requestEmitted.fulfill()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data([0, 1]))
        }
        let settings = HostedSettings(
            networkManager: networkManager,
            audioPlayer: audioPlayer,
            secretStore: secretStore,
            testCase: self
        )

        XCTAssertTrue(settings.rendersButton(titled: "Retry Securing Saved Keys"))
        XCTAssertNil(secretStore.storedSecret(for: .custom))
        XCTAssertEqual(UserDefaults.standard.string(forKey: SettingsKeys.legacyCustomAPIKey), "test-legacy-custom-key")

        settings.click("Retry Securing Saved Keys")

        XCTAssertEqual(secretStore.storedSecret(for: .custom), "test-legacy-custom-key")
        XCTAssertNil(UserDefaults.standard.object(forKey: SettingsKeys.legacyCustomAPIKey))
        XCTAssertFalse(settings.rendersButton(titled: "Retry Securing Saved Keys"))
        XCTAssertNil(networkManager.lastError)

        // A clipboard or Services request reaches the manager directly, so it proves the retry
        // itself refreshed the credentials rather than the next Settings action doing it.
        networkManager.streamTTS(text: "Speech started after the key was secured") { _ in }

        wait(for: [requestEmitted], timeout: 2.0)
        settings.release()
    }

    func testTheRetryMigratesTheInjectedPreferencesRatherThanTheProcessDomain() {
        // WHY: The hosted test app already migrates a private preferences domain rather than
        // `UserDefaults.standard`, and startup threads that choice explicitly for exactly this
        // reason. A retry that reached for the process domain instead would leave the real legacy
        // key exposed while deleting a key belonging to somebody else's configuration.
        let injectedDefaults = InMemoryDefaults()
        let secretStore = ScriptedSecretStore()
        let audioPlayer = AudioPlayerManager()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore)
        // Each domain holds a different provider's key, so a form that read the wrong one would
        // both rescue the wrong secret and leave the one it was given behind.
        injectedDefaults.set("test-injected-legacy-key", forKey: SettingsKeys.legacyOpenAIAPIKey)
        UserDefaults.standard.set("test-process-legacy-key", forKey: SettingsKeys.legacyCustomAPIKey)

        let requestEmitted = expectation(description: "The injected domain's key reaches the next request")
        MockURLProtocol.installRequestHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            // Opening Settings on OpenAI also fetches its model and voice suggestions.
            guard request.url?.absoluteString == "https://api.openai.com/v1/audio/speech" else {
                return (response, Data("{ \"data\": [] }".utf8))
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-injected-legacy-key")
            requestEmitted.fulfill()
            return (response, Data([0, 1]))
        }
        let settings = HostedSettings(
            networkManager: networkManager,
            audioPlayer: audioPlayer,
            secretStore: secretStore,
            defaults: injectedDefaults,
            testCase: self
        )

        XCTAssertTrue(settings.rendersButton(titled: "Retry Securing Saved Keys"))

        settings.click("Retry Securing Saved Keys")

        XCTAssertEqual(secretStore.storedSecret(for: .openAI), "test-injected-legacy-key")
        XCTAssertNil(injectedDefaults.string(forKey: SettingsKeys.legacyOpenAIAPIKey))
        XCTAssertNil(secretStore.storedSecret(for: .custom))
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: SettingsKeys.legacyCustomAPIKey),
            "test-process-legacy-key"
        )
        XCTAssertFalse(settings.rendersButton(titled: "Retry Securing Saved Keys"))

        networkManager.streamTTS(text: "Speech started after the injected key was secured") { _ in }

        wait(for: [requestEmitted], timeout: 2.0)
        settings.release()
    }

    func testAFailedRetryLosesNothingAndASecondOneKeepsTheNewerSavedKey() throws {
        // WHY: A Keychain that is still unavailable must cost the user nothing: the plaintext key
        // has to survive for the next attempt and the recovery must keep advertising itself rather
        // than look as though it worked. When the store does accept the retry, the same rule that
        // protects a launch applies — a key the user saved after the failure is newer than the
        // plaintext, so securing must remove the stale value without overwriting the good one.
        UserDefaults.standard.set("test-stale-legacy-key", forKey: SettingsKeys.legacyOpenAIAPIKey)

        let secretStore = ScriptedSecretStore()
        secretStore.seed("test-newer-keychain-key", for: .openAI)
        secretStore.failingProviders = [.openAI]
        let audioPlayer = AudioPlayerManager()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore)
        secretStore.failingProviders = []

        let requestEmitted = expectation(description: "Test Voice still uses the newer saved key")
        MockURLProtocol.installRequestHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            // Opening Settings on OpenAI also fetches its model and voice suggestions.
            guard request.url?.absoluteString == "https://api.openai.com/v1/audio/speech" else {
                return (response, Data("{ \"data\": [] }".utf8))
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-newer-keychain-key")
            requestEmitted.fulfill()
            return (response, Data([0, 1]))
        }
        let settings = HostedSettings(
            networkManager: networkManager,
            audioPlayer: audioPlayer,
            secretStore: secretStore,
            testCase: self
        )
        secretStore.failingProviders = [.openAI]

        settings.click("Retry Securing Saved Keys")

        XCTAssertEqual(UserDefaults.standard.string(forKey: SettingsKeys.legacyOpenAIAPIKey), "test-stale-legacy-key")
        XCTAssertEqual(secretStore.storedSecret(for: .openAI), "test-newer-keychain-key")
        XCTAssertTrue(settings.rendersButton(titled: "Retry Securing Saved Keys"))
        XCTAssertEqual(networkManager.lastError, APIKeyMigrationService.failureMessage(for: .openAI))

        secretStore.failingProviders = []
        settings.click("Retry Securing Saved Keys")

        XCTAssertEqual(secretStore.storedSecret(for: .openAI), "test-newer-keychain-key")
        XCTAssertNil(UserDefaults.standard.object(forKey: SettingsKeys.legacyOpenAIAPIKey))
        XCTAssertFalse(settings.rendersButton(titled: "Retry Securing Saved Keys"))
        XCTAssertNil(networkManager.lastError)

        settings.click("Test Voice")

        wait(for: [requestEmitted], timeout: 2.0)
        settings.release()
    }

    func testPartialMigrationSuccessKeepsOnlyTheStillFailingProviderPending() throws {
        // WHY: One provider's Keychain refusal must not strand the keys that were secured, and a
        // provider that is now safe must not keep claiming the user has plaintext to rescue. The
        // one that failed keeps both its value and a warning that names it, because a warning left
        // naming the recovered provider would send the user looking in the wrong place.
        UserDefaults.standard.set("test-legacy-openai-key", forKey: SettingsKeys.legacyOpenAIAPIKey)
        UserDefaults.standard.set("test-legacy-gemini-key", forKey: SettingsKeys.legacyGeminiAPIKey)

        let secretStore = ScriptedSecretStore()
        secretStore.failingProviders = [.openAI, .gemini]
        let audioPlayer = AudioPlayerManager()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore)
        XCTAssertEqual(networkManager.lastError, APIKeyMigrationService.failureMessage(for: .openAI))
        secretStore.failingProviders = []
        MockURLProtocol.installRequestHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("{ \"data\": [] }".utf8))
        }
        let settings = HostedSettings(
            networkManager: networkManager,
            audioPlayer: audioPlayer,
            secretStore: secretStore,
            testCase: self
        )
        secretStore.failingProviders = [.gemini]

        settings.click("Retry Securing Saved Keys")

        XCTAssertEqual(secretStore.storedSecret(for: .openAI), "test-legacy-openai-key")
        XCTAssertNil(UserDefaults.standard.object(forKey: SettingsKeys.legacyOpenAIAPIKey))
        XCTAssertNil(secretStore.storedSecret(for: .gemini))
        XCTAssertEqual(UserDefaults.standard.string(forKey: SettingsKeys.legacyGeminiAPIKey), "test-legacy-gemini-key")
        XCTAssertTrue(settings.rendersButton(titled: "Retry Securing Saved Keys"))
        XCTAssertEqual(networkManager.lastError, APIKeyMigrationService.failureMessage(for: .gemini))
        settings.release()
    }

    func testSavingAKeyOverAPendingMigrationRetiresBothTheRecoveryAndItsWarning() throws {
        // WHY: Typing a key resolves that provider as completely as securing it does, so the menu
        // bar must stop warning about plaintext the app no longer holds and Settings must stop
        // offering to rescue it. Otherwise the user is told to act on a problem they just fixed.
        UserDefaults.standard.set("test-legacy-openai-key", forKey: SettingsKeys.legacyOpenAIAPIKey)
        let secretStore = ScriptedSecretStore()
        secretStore.failingProviders = [.openAI]
        let audioPlayer = AudioPlayerManager()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore)
        XCTAssertEqual(networkManager.lastError, APIKeyMigrationService.failureMessage(for: .openAI))
        secretStore.failingProviders = []
        MockURLProtocol.installRequestHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("{ \"data\": [] }".utf8))
        }
        let settings = HostedSettings(
            networkManager: networkManager,
            audioPlayer: audioPlayer,
            secretStore: secretStore,
            testCase: self
        )
        XCTAssertTrue(settings.rendersButton(titled: "Retry Securing Saved Keys"))

        settings.typeAPIKey("test-typed-openai-key")

        XCTAssertEqual(secretStore.storedSecret(for: .openAI), "test-typed-openai-key")
        XCTAssertNil(UserDefaults.standard.object(forKey: SettingsKeys.legacyOpenAIAPIKey))
        XCTAssertFalse(settings.rendersButton(titled: "Retry Securing Saved Keys"))
        XCTAssertNil(networkManager.lastError)
        settings.release()
    }

    func testALaunchWithNoUnsecuredKeyOffersNoRetryAndWritesNoSecret() throws {
        // WHY: The recovery must be evidence of a real problem. Offering it when nothing is pending
        // invites a Keychain prompt for nothing, and a launch that writes to the store at all could
        // replace a credential it was only ever supposed to read.
        let secretStore = ScriptedSecretStore()
        secretStore.seed("test-openai-key", for: .openAI)
        let audioPlayer = AudioPlayerManager()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore)
        MockURLProtocol.installRequestHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("{ \"data\": [] }".utf8))
        }
        let settings = HostedSettings(
            networkManager: networkManager,
            audioPlayer: audioPlayer,
            secretStore: secretStore,
            testCase: self
        )

        XCTAssertFalse(settings.rendersButton(titled: "Retry Securing Saved Keys"))
        XCTAssertNil(networkManager.lastError)
        XCTAssertEqual(secretStore.savedProviders, [])
        XCTAssertEqual(secretStore.deletedProviders, [])
        XCTAssertEqual(secretStore.storedSecret(for: .openAI), "test-openai-key")
        settings.release()
    }
}
