import XCTest
@testable import ClipboardTTSApp

final class AppStartupDependenciesTests: XCTestCase {
    func testHostedTestStartupUsesOnlyTestOwnedSettingsAndSecrets() {
        // WHY: XCTest initializes the app before any test can clear the installed app's defaults.
        // If that startup path falls back to production dependencies, legacy migration can read or
        // delete a developer credential before the mock-test lifecycle is established.
        XCTAssertTrue(HostedTestProcess.isActive, "The hosted test process must select test-owned app startup dependencies.")
        isolateAppSettingsDefaults()

        let developerDefaults = UserDefaults.standard
        let hostedDefaults = makeDefaults(named: "hosted")
        let developerSecretStore = RecordingSecretStore(secrets: [.custom: "developer-keychain-credential"])
        let hostedSecretStore = RecordingSecretStore()
        var productionDefaultsRequested = false
        var productionSecretStoreRequested = false
        let developerValues = [
            SettingsKeys.ttsProvider: "Custom",
            SettingsKeys.apiBaseURL: "https://developer.example/v1/audio/speech",
            SettingsKeys.customModel: "developer-model",
            SettingsKeys.customVoice: "developer-voice",
            SettingsKeys.legacyCustomAPIKey: "developer-legacy-credential"
        ]
        developerValues.forEach { developerDefaults.set($0.value, forKey: $0.key) }
        developerDefaults.set(48_000.0, forKey: SettingsKeys.customSampleRate)
        let hostedValues = [
            SettingsKeys.ttsProvider: "Custom",
            SettingsKeys.apiBaseURL: "https://hosted.example/v1/audio/speech",
            SettingsKeys.customModel: "hosted-model",
            SettingsKeys.customVoice: "hosted-voice",
            SettingsKeys.legacyCustomAPIKey: "hosted-legacy-credential"
        ]
        hostedValues.forEach { hostedDefaults.set($0.value, forKey: $0.key) }
        hostedDefaults.set(16_000.0, forKey: SettingsKeys.customSampleRate)

        let defaultDependencies = AppStartupDependencies.make()
        defer { defaultDependencies.networkManager.session.invalidateAndCancel() }

        let dependencies = AppStartupDependencies.make(
            isHostedTest: true,
            productionDefaults: {
                productionDefaultsRequested = true
                return developerDefaults
            },
            productionSecretStore: {
                productionSecretStoreRequested = true
                return developerSecretStore
            },
            testDefaults: { hostedDefaults },
            testSecretStore: { hostedSecretStore }
        )
        defer { dependencies.networkManager.session.invalidateAndCancel() }

        XCTAssertFalse(productionDefaultsRequested)
        XCTAssertFalse(productionSecretStoreRequested)
        XCTAssertFalse(defaultDependencies.defaults === developerDefaults)
        XCTAssertTrue(defaultDependencies.secretStore is InMemorySecretStore)
        XCTAssertTrue(defaultDependencies.networkManager.isCurrentProvider("OpenAI"))
        XCTAssertEqual(
            defaultDependencies.networkManager.metadataSettingsSnapshot(),
            .init(
                baseURL: "https://api.openai.com/v1/audio/speech",
                apiKey: "",
                model: "tts-1",
                provider: "OpenAI"
            )
        )
        XCTAssertEqual(defaultDependencies.audioPlayer.sampleRate, AudioPlayerManager.defaultSampleRate)
        XCTAssertTrue(developerSecretStore.operations.isEmpty)
        XCTAssertEqual(developerSecretStore.storedSecrets, [.custom: "developer-keychain-credential"])
        for (key, value) in developerValues {
            XCTAssertEqual(developerDefaults.string(forKey: key), value, "Hosted startup must not change developer default \(key).")
        }
        XCTAssertEqual(developerDefaults.double(forKey: SettingsKeys.customSampleRate), 48_000)
        XCTAssertNil(hostedDefaults.object(forKey: SettingsKeys.legacyCustomAPIKey))
        XCTAssertEqual(
            hostedSecretStore.operations,
            [.read(.custom), .save(.custom), .read(.custom)]
        )
        XCTAssertEqual(hostedSecretStore.storedSecrets, [.custom: "hosted-legacy-credential"])
        XCTAssertTrue(dependencies.networkManager.isCurrentProvider("Custom"))
        XCTAssertEqual(
            dependencies.networkManager.metadataSettingsSnapshot(),
            .init(
                baseURL: "https://hosted.example/v1/audio/speech",
                apiKey: "hosted-legacy-credential",
                model: "hosted-model",
                provider: "Custom"
            )
        )
        XCTAssertEqual(dependencies.audioPlayer.sampleRate, 16_000)
    }

    func testProductionStartupUsesInjectedPersistedSettingsAndSecretStore() {
        // WHY: The isolation branch is safe only if the non-test branch remains the production
        // behavior: persisted provider settings must set up the manager, audio, and migration
        // before the Services coordinator can accept requests.
        let productionDefaults = makeDefaults(named: "production")
        let productionSecretStore = RecordingSecretStore()
        let testDefaults = makeDefaults(named: "unused-hosted")
        let testSecretStore = RecordingSecretStore()
        var productionDefaultsRequested = false
        var productionSecretStoreRequested = false
        var testDefaultsRequested = false
        var testSecretStoreRequested = false
        productionDefaults.set("Custom", forKey: SettingsKeys.ttsProvider)
        productionDefaults.set("https://production.example/v1/audio/speech", forKey: SettingsKeys.apiBaseURL)
        productionDefaults.set("production-model", forKey: SettingsKeys.customModel)
        productionDefaults.set("production-voice", forKey: SettingsKeys.customVoice)
        productionDefaults.set(12_000.0, forKey: SettingsKeys.customSampleRate)
        productionDefaults.set("production-legacy-credential", forKey: SettingsKeys.legacyCustomAPIKey)

        let dependencies = AppStartupDependencies.make(
            isHostedTest: false,
            productionDefaults: {
                productionDefaultsRequested = true
                return productionDefaults
            },
            productionSecretStore: {
                productionSecretStoreRequested = true
                return productionSecretStore
            },
            testDefaults: {
                testDefaultsRequested = true
                return testDefaults
            },
            testSecretStore: {
                testSecretStoreRequested = true
                return testSecretStore
            }
        )
        defer { dependencies.networkManager.session.invalidateAndCancel() }

        XCTAssertTrue(productionDefaultsRequested)
        XCTAssertTrue(productionSecretStoreRequested)
        XCTAssertFalse(testDefaultsRequested)
        XCTAssertFalse(testSecretStoreRequested)
        XCTAssertNil(productionDefaults.object(forKey: SettingsKeys.legacyCustomAPIKey))
        XCTAssertEqual(
            productionSecretStore.operations,
            [.read(.custom), .save(.custom), .read(.custom)]
        )
        XCTAssertEqual(productionSecretStore.storedSecrets, [.custom: "production-legacy-credential"])
        XCTAssertTrue(dependencies.networkManager.isCurrentProvider("Custom"))
        XCTAssertEqual(
            dependencies.networkManager.metadataSettingsSnapshot(),
            .init(
                baseURL: "https://production.example/v1/audio/speech",
                apiKey: "production-legacy-credential",
                model: "production-model",
                provider: "Custom"
            )
        )
        XCTAssertEqual(dependencies.audioPlayer.sampleRate, 12_000)
    }

    private func makeDefaults(named suffix: String) -> UserDefaults {
        let suiteName = "com.clipboardtts.tests.startup.\(suffix).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }
}

private final class RecordingSecretStore: SecretStoring {
    enum Operation: Equatable {
        case read(APIKeyProvider)
        case save(APIKeyProvider)
        case delete(APIKeyProvider)
    }

    private(set) var operations: [Operation] = []
    private(set) var storedSecrets: [APIKeyProvider: String]

    init(secrets: [APIKeyProvider: String] = [:]) {
        self.storedSecrets = secrets
    }

    func secret(for provider: APIKeyProvider) throws -> String? {
        operations.append(.read(provider))
        return storedSecrets[provider]
    }

    func saveSecret(_ secret: String, for provider: APIKeyProvider) throws {
        operations.append(.save(provider))
        storedSecrets[provider] = secret
    }

    func deleteSecret(for provider: APIKeyProvider) throws {
        operations.append(.delete(provider))
        storedSecrets.removeValue(forKey: provider)
    }
}
