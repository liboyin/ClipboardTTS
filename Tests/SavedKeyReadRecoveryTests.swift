import XCTest
@testable import ClipboardTTSApp

/// Covers recovering from a saved API key the store refused to read: what the form's retry reads
/// and adopts, the startup guidance the manager withdraws, and the hosted control that runs both.
///
/// Hosted Settings drives `NSHostingView` and the AppKit controls it builds, so every test here
/// runs on the main actor.
@MainActor
final class SavedKeyReadRecoveryTests: MockURLProtocolTestCase {
    private let retryTitle = "Retry Reading Saved Keys"

    // MARK: - The form's retry

    func testARetriedReadAdoptsTheSavedKeyAndWithdrawsItsReadFailure() {
        // WHY: The guidance says to try again, and a key the Keychain answers for now is the key
        // the user saved. Leaving the field blank would push them to re-enter a key they already
        // have, and leaving the failure up would describe storage the app just watched recover.
        let secretStore = ScriptedSecretStore()
        secretStore.seed("test-saved-openai-key", for: .openAI)
        secretStore.failingProviders = [.openAI]
        let secretState = SettingsSecretState(secretStore: secretStore, defaults: makeOwnedDefaults())
        XCTAssertEqual(secretState.errorMessage, APIKeyStartupState.readFailureMessage(for: .openAI))

        secretStore.failingProviders = []
        let recovered = secretState.retryUnreadableSecrets()

        XCTAssertEqual(recovered, [.openAI])
        XCTAssertEqual(secretState.secret(for: .openAI), "test-saved-openai-key")
        XCTAssertEqual(secretState.unreadableProviders, [])
        XCTAssertNil(secretState.errorMessage)
    }

    func testARetriedReadThatStillFailsKeepsItsGuidanceAndItsRetry() {
        // WHY: A Keychain that is still unavailable must not look fixed. The failure and the action
        // that recovers from it both have to stay, or the user is left with a blank key and no way
        // to try again.
        let secretStore = ScriptedSecretStore()
        secretStore.seed("test-saved-openai-key", for: .openAI)
        secretStore.failingProviders = [.openAI]
        let secretState = SettingsSecretState(secretStore: secretStore, defaults: makeOwnedDefaults())

        let recovered = secretState.retryUnreadableSecrets()

        XCTAssertEqual(recovered, [])
        XCTAssertEqual(secretState.secret(for: .openAI), "")
        XCTAssertEqual(secretState.unreadableProviders, [.openAI])
        XCTAssertEqual(secretState.errorMessage, APIKeyStartupState.readFailureMessage(for: .openAI))
    }

    func testARetriedReadFindingNoSavedKeyStillResolvesTheFailure() {
        // WHY: A store that answers "no key" has been read successfully. Treating that answer as
        // another failure would keep telling the user to fix Keychain access that already works,
        // when all that is missing is a key they never saved.
        let secretStore = ScriptedSecretStore()
        secretStore.failingProviders = [.gemini]
        let secretState = SettingsSecretState(secretStore: secretStore, defaults: makeOwnedDefaults())

        secretStore.failingProviders = []
        let recovered = secretState.retryUnreadableSecrets()

        XCTAssertEqual(recovered, [.gemini])
        XCTAssertEqual(secretState.secret(for: .gemini), "")
        XCTAssertEqual(secretState.unreadableProviders, [])
        XCTAssertNil(secretState.errorMessage)
    }

    func testARetriedReadReplacesItsOwnFailureWithTheNextUnresolvedOne() {
        // WHY: The form shows one storage failure at a time, so recovering the provider named first
        // must not read as "storage works now" while another key is still unreadable.
        let secretStore = ScriptedSecretStore()
        secretStore.seed("test-saved-openai-key", for: .openAI)
        secretStore.failingProviders = [.openAI, .gemini]
        let secretState = SettingsSecretState(secretStore: secretStore, defaults: makeOwnedDefaults())

        secretStore.failingProviders = [.gemini]
        secretState.retryUnreadableSecrets()

        XCTAssertEqual(secretState.secret(for: .openAI), "test-saved-openai-key")
        XCTAssertEqual(secretState.unreadableProviders, [.gemini])
        XCTAssertEqual(secretState.errorMessage, APIKeyStartupState.readFailureMessage(for: .gemini))
    }

    func testOneRetriedReadRecoversEveryKeyTheStoreNowAnswersFor() {
        // WHY: The user pressed one retry for every key the form could not read. Stopping at the
        // first recovered provider would leave another key blank, with its guidance promoted onto
        // the screen, even though the store would have answered for it too.
        let secretStore = ScriptedSecretStore()
        secretStore.seed("test-saved-openai-key", for: .openAI)
        secretStore.seed("test-saved-gemini-key", for: .gemini)
        secretStore.failingProviders = [.openAI, .gemini]
        let secretState = SettingsSecretState(secretStore: secretStore, defaults: makeOwnedDefaults())

        secretStore.failingProviders = []
        let recovered = secretState.retryUnreadableSecrets()

        XCTAssertEqual(recovered, [.openAI, .gemini])
        XCTAssertEqual(secretState.secret(for: .openAI), "test-saved-openai-key")
        XCTAssertEqual(secretState.secret(for: .gemini), "test-saved-gemini-key")
        XCTAssertNil(secretState.errorMessage)
    }

    func testARetriedReadNeverReplacesAKeyTheUserStoredSince() {
        // WHY: A key typed after the failure is the user's newest statement of that credential.
        // Reading the store again for it could hand back whatever else wrote there, silently
        // replacing the key the user can see with one they never chose.
        let secretStore = ScriptedSecretStore()
        secretStore.failingProviders = [.openAI, .gemini]
        let secretState = SettingsSecretState(secretStore: secretStore, defaults: makeOwnedDefaults())
        secretStore.failingProviders = [.gemini]
        secretState.saveSecret("test-typed-openai-key", for: .openAI)
        secretStore.seed("test-other-writer-openai-key", for: .openAI)

        secretStore.failingProviders = []
        let recovered = secretState.retryUnreadableSecrets()

        XCTAssertEqual(recovered, [.gemini])
        XCTAssertEqual(secretState.secret(for: .openAI), "test-typed-openai-key")
    }

    func testARetriedReadLeavesAnUnfixedSaveFailureOnScreen() {
        // WHY: Reading one key says nothing about a different key the store refused to save. Only
        // the recovered provider's own read failure may give way, or the user loses the only sign
        // that their edit was never persisted.
        let secretStore = ScriptedSecretStore()
        secretStore.failingProviders = [.openAI]
        let secretState = SettingsSecretState(secretStore: secretStore, defaults: makeOwnedDefaults())
        secretStore.failingProviders = [.openAI, .custom]
        secretState.saveSecret("test-refused-custom-key", for: .custom)
        let saveFailure = "Couldn't save the Custom API key. Check Keychain access and try again."
        XCTAssertEqual(secretState.errorMessage, saveFailure)

        secretStore.failingProviders = [.custom]
        secretState.retryUnreadableSecrets()

        XCTAssertEqual(secretState.unreadableProviders, [])
        XCTAssertEqual(secretState.errorMessage, saveFailure)
    }

    // MARK: - The manager's startup guidance

    func testRecoveringTheUnreadableKeyWithdrawsOnlyItsStartupGuidance() {
        // WHY: The menu bar keeps telling the user their key could not be read until something
        // withdraws it. Only recovering that provider's key disproves it: recovering another
        // provider's says nothing about the key future requests use.
        let secretStore = ScriptedSecretStore()
        secretStore.failingProviders = [.custom]
        let manager = TestNetworkFactory.makeManager(
            secretStore: secretStore,
            defaults: makeOwnedDefaults([SettingsKeys.ttsProvider: "Custom"])
        )
        XCTAssertEqual(manager.lastError, APIKeyStartupState.readFailureMessage(for: .custom))

        manager.withdrawKeyReadFailure(for: .openAI)
        XCTAssertEqual(manager.lastError, APIKeyStartupState.readFailureMessage(for: .custom))

        manager.withdrawKeyReadFailure(for: .custom)
        XCTAssertNil(manager.lastError)
    }

    func testWithdrawingTheReadFailureCannotEraseANewerRequestFailure() {
        // WHY: Startup guidance and request failures share one menu-bar channel. Reading a key
        // resolves nothing about a request that failed afterwards, so the user must keep the
        // guidance they need to make the app speak.
        let secretStore = ScriptedSecretStore()
        secretStore.failingProviders = [.custom]
        let manager = TestNetworkFactory.makeManager(
            secretStore: secretStore,
            defaults: makeOwnedDefaults([SettingsKeys.ttsProvider: "Custom"])
        )
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

        manager.withdrawKeyReadFailure(for: .custom)

        XCTAssertEqual(manager.lastError, requestFailure)
    }

    // MARK: - Hosted Settings

    func testAnUnreadableKeyOffersARetryThatHandsTheKeyToTheNextRequest() {
        // WHY: Recovery has to be reachable where the guidance appears, and it is finished only
        // when the saved key is what the next clipboard or Services request sends — not merely when
        // the warnings disappear.
        let defaults = makeOwnedDefaults([
            SettingsKeys.ttsProvider: "Custom",
            SettingsKeys.apiBaseURL: "https://custom.api/v1/audio/speech",
            SettingsKeys.customModel: "custom-model",
            SettingsKeys.customVoice: "custom-voice"
        ])
        let secretStore = ScriptedSecretStore()
        secretStore.seed("test-saved-custom-key", for: .custom)
        secretStore.failingProviders = [.custom]
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore, defaults: defaults)
        let requestEmitted = expectation(description: "The recovered key reaches the next request")
        MockURLProtocol.installRequestHandler { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-saved-custom-key")
            requestEmitted.fulfill()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data([0, 1]))
        }
        let settings = HostedSettings(
            networkManager: networkManager,
            audioPlayer: AudioPlayerManager(),
            secretStore: secretStore,
            defaults: defaults,
            testCase: self
        )
        XCTAssertTrue(settings.rendersButton(titled: retryTitle))
        XCTAssertFalse(settings.rendersButton(titled: "Retry Securing Saved Keys"))

        secretStore.failingProviders = []
        settings.click(retryTitle)

        XCTAssertFalse(settings.rendersButton(titled: retryTitle))
        XCTAssertNil(networkManager.lastError)
        // A request that reaches the manager directly proves the retry itself refreshed the
        // credentials, rather than the next Settings action doing it.
        networkManager.streamTTS(text: "Speech started after the key was read") { _ in }

        wait(for: [requestEmitted], timeout: 2.0)
        settings.release()
    }

    func testARetryThatStillCannotReadKeepsOfferingItself() {
        // WHY: A Keychain that is still unavailable must cost the user nothing and must not look
        // fixed: the menu keeps its guidance and Settings keeps the way to try again.
        let defaults = makeOwnedDefaults([SettingsKeys.ttsProvider: "Custom"])
        let secretStore = ScriptedSecretStore()
        secretStore.seed("test-saved-custom-key", for: .custom)
        secretStore.failingProviders = [.custom]
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore, defaults: defaults)
        let settings = HostedSettings(
            networkManager: networkManager,
            audioPlayer: AudioPlayerManager(),
            secretStore: secretStore,
            defaults: defaults,
            testCase: self
        )

        settings.click(retryTitle)

        XCTAssertTrue(settings.rendersButton(titled: retryTitle))
        XCTAssertEqual(networkManager.lastError, APIKeyStartupState.readFailureMessage(for: .custom))
        settings.release()
    }

    func testALaunchThatReadEveryKeyOffersNoReadRetry() {
        // WHY: The retry must be evidence of a real problem; offering it otherwise invites a
        // Keychain prompt for nothing.
        let defaults = makeOwnedDefaults([SettingsKeys.ttsProvider: "Custom"])
        let secretStore = ScriptedSecretStore()
        secretStore.seed("test-saved-custom-key", for: .custom)
        let settings = HostedSettings(
            networkManager: TestNetworkFactory.makeManager(secretStore: secretStore, defaults: defaults),
            audioPlayer: AudioPlayerManager(),
            secretStore: secretStore,
            defaults: defaults,
            testCase: self
        )

        XCTAssertFalse(settings.rendersButton(titled: retryTitle))
        settings.release()
    }

    func testRecoveringTheSelectedKeyRediscoversModelsWithIt() {
        // WHY: Opening Settings discovered models without the key it could not read, so the
        // suggestions stay empty until discovery runs again. Recovering the key changes it just as
        // typing one does, and typing one rediscovers. The voice catalog does not follow a key.
        let defaults = makeOwnedDefaults()
        let secretStore = ScriptedSecretStore()
        secretStore.seed("test-saved-openai-key", for: .openAI)
        secretStore.failingProviders = [.openAI]
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore, defaults: defaults)
        let rediscovered = expectation(description: "Model discovery carries the recovered key")
        MockURLProtocol.installRequestHandler { request in
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer test-saved-openai-key" {
                XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/models")
                rediscovered.fulfill()
            }
            return metadataResponse(for: request, json: "{ \"data\": [{\"id\": \"tts-1\"}] }")
        }
        let settings = HostedSettings(
            networkManager: networkManager,
            audioPlayer: AudioPlayerManager(),
            secretStore: secretStore,
            defaults: defaults,
            testCase: self
        )
        let begun = metadataRequestsBegun(by: networkManager)

        secretStore.failingProviders = []
        settings.click(retryTitle)

        XCTAssertEqual(metadataRequestsBegun(by: networkManager) - begun, 1, "Only model discovery follows the key.")
        XCTAssertEqual(networkManager.requestSettingsSnapshot().apiKey, "test-saved-openai-key")
        wait(for: [rediscovered], timeout: 2.0)
        settings.release()
    }

    func testRecoveringAnotherProvidersKeyLeavesTheSelectedDiscoveryAlone() {
        // WHY: Discovery follows the selected provider's key. Recovering a different provider's
        // key changes nothing it depends on, so rediscovering would only repeat a request.
        let defaults = makeOwnedDefaults()
        let secretStore = ScriptedSecretStore()
        secretStore.seed("test-saved-openai-key", for: .openAI)
        secretStore.seed("test-saved-gemini-key", for: .gemini)
        secretStore.failingProviders = [.gemini]
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore, defaults: defaults)
        MockURLProtocol.installRequestHandler { request in
            metadataResponse(for: request, json: "{ \"data\": [{\"id\": \"tts-1\"}] }")
        }
        let settings = HostedSettings(
            networkManager: networkManager,
            audioPlayer: AudioPlayerManager(),
            secretStore: secretStore,
            defaults: defaults,
            testCase: self
        )
        let begun = metadataRequestsBegun(by: networkManager)

        secretStore.failingProviders = []
        settings.click(retryTitle)

        XCTAssertFalse(settings.rendersButton(titled: retryTitle))
        XCTAssertEqual(metadataRequestsBegun(by: networkManager) - begun, 0)
        XCTAssertEqual(networkManager.requestSettingsSnapshot().apiKey, "test-saved-openai-key")
        settings.release()
    }
}
