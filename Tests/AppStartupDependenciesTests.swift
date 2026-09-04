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
        let hostedDefaults = makeDefaults()
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
        assertRequestInputs(
            defaultDependencies.networkManager,
            match: .init(
                baseURL: "https://api.openai.com/v1/audio/speech",
                apiKey: "",
                model: "tts-1",
                voice: "alloy",
                provider: .openAICompatible
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
        assertRequestInputs(
            dependencies.networkManager,
            match: .init(
                baseURL: "https://hosted.example/v1/audio/speech",
                apiKey: "hosted-legacy-credential",
                model: "hosted-model",
                voice: "hosted-voice",
                provider: .custom
            )
        )
        XCTAssertEqual(dependencies.audioPlayer.sampleRate, 16_000)
    }

    func testProductionStartupUsesInjectedPersistedSettingsAndSecretStore() {
        // WHY: The isolation branch is safe only if the non-test branch remains the production
        // behavior: persisted provider settings must set up the manager, audio, and migration
        // before the Services coordinator can accept requests.
        let productionDefaults = makeDefaults()
        let productionSecretStore = RecordingSecretStore()
        let testDefaults = makeDefaults()
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
        assertRequestInputs(
            dependencies.networkManager,
            match: .init(
                baseURL: "https://production.example/v1/audio/speech",
                apiKey: "production-legacy-credential",
                model: "production-model",
                voice: "production-voice",
                provider: .custom
            )
        )
        XCTAssertEqual(dependencies.audioPlayer.sampleRate, 12_000)
    }

    func testStartupRegressionDefaultsWriteNeitherToDiskNorToTheAppSettingsDomain() {
        // WHY: These regressions seed provider settings, so a disk-backed suite made them the only
        // thing in the repository that writes unbounded state outside the build directory:
        // `removePersistentDomain` empties a suite but does not delete it, and `cfprefsd` rewrites
        // the suite's plist into ~/Library/Preferences when the hosted test process exits. The
        // replacement must also keep its values out of the app's own defaults domain, because the
        // test bundle is hosted inside the app and a value that falls through to `UserDefaults`'
        // own storage would reconfigure the developer's installation.
        isolateAppSettingsDefaults()
        let preferenceFilesBeforeSeeding = appPreferenceFileNames()

        let defaults = makeDefaults()
        SettingsKeys.allUserDefaultsKeys.forEach { defaults.set("seeded-\($0)", forKey: $0) }
        defaults.set(44_100.0, forKey: SettingsKeys.customSampleRate)
        defaults.synchronize()

        XCTAssertEqual(
            defaults.string(forKey: SettingsKeys.apiBaseURL),
            "seeded-\(SettingsKeys.apiBaseURL)",
            "Startup regressions must read back the settings they seed, or they prove nothing about startup."
        )
        XCTAssertEqual(
            defaults.double(forKey: SettingsKeys.customSampleRate),
            44_100,
            "Typed accessors must resolve through the test-owned storage, not a fallback domain."
        )
        XCTAssertEqual(
            appPreferenceFileNames(),
            preferenceFilesBeforeSeeding,
            "Seeding a startup regression must not create a preferences file in the developer's home directory."
        )
        for key in SettingsKeys.allUserDefaultsKeys {
            XCTAssertNil(
                UserDefaults.standard.object(forKey: key),
                "Seeded startup value for \(key) must not reach the app's own defaults domain."
            )
        }
    }

    /// Asserts every input the manager would put into its first speech request.
    ///
    /// WHY: startup decides which endpoint, credential, model, voice, and provider kind the user's
    /// first Speak actually sends, so these regressions read the production request seam rather
    /// than a narrower accessor. The expectation is a `RequestSettings` so a later input added to
    /// that seam cannot compile until startup proves it too, and the fields are compared one at a
    /// time so a failure names the input that regressed.
    private func assertRequestInputs(_ manager: TTSNetworkManager,
                                     match expected: TTSNetworkManager.RequestSettings,
                                     file: StaticString = #filePath,
                                     line: UInt = #line) {
        let settings = manager.requestSettingsSnapshot()
        XCTAssertEqual(settings.baseURL, expected.baseURL, "Startup must request the persisted endpoint.", file: file, line: line)
        XCTAssertEqual(settings.apiKey, expected.apiKey, "Startup must request with the secured key.", file: file, line: line)
        XCTAssertEqual(settings.model, expected.model, "Startup must request the persisted model.", file: file, line: line)
        XCTAssertEqual(settings.voice, expected.voice, "Startup must request the persisted voice.", file: file, line: line)
        XCTAssertEqual(settings.provider, expected.provider, "Startup must request as the persisted provider.", file: file, line: line)
    }

    /// Creates test-owned settings storage that outlives no test and reaches no shared domain.
    private func makeDefaults() -> UserDefaults {
        InMemoryDefaults()
    }

    /// The app-owned preference file names currently present in the developer's home directory.
    private func appPreferenceFileNames() -> Set<String> {
        let preferences = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Preferences", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: preferences.path)) ?? []
        return Set(names.filter { $0.hasPrefix("com.clipboardtts.") })
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
