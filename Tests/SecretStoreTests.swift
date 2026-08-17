import XCTest
@testable import ClipboardTTSApp

final class SecretStoreTests: MockURLProtocolTestCase {
    func testInMemorySecretStoreCreatesReadsUpdatesAndDeletesSecrets() throws {
        // WHY: Settings needs one store contract for all providers, so this proves an edit replaces
        // rather than duplicates a key and clearing the field removes it from future requests.
        let store = InMemorySecretStore()

        XCTAssertNil(try store.secret(for: .openAI))
        try store.saveSecret("test-openai-key-one", for: .openAI)
        XCTAssertEqual(try store.secret(for: .openAI), "test-openai-key-one")

        try store.saveSecret("test-openai-key-two", for: .openAI)
        XCTAssertEqual(try store.secret(for: .openAI), "test-openai-key-two")

        try store.deleteSecret(for: .openAI)
        XCTAssertNil(try store.secret(for: .openAI))
    }

    func testMigrationPreservesLegacyPreferenceAndMapsAStoreFailureToActionableGuidance() throws {
        // WHY: Migration is allowed to delete a plaintext key only after Keychain confirms its
        // write. Retaining it on failure lets the user recover instead of losing their only key.
        let store = InMemorySecretStore()
        let legacySecret = "test-legacy-openai-key"
        UserDefaults.standard.set(legacySecret, forKey: SettingsKeys.legacyOpenAIAPIKey)
        store.nextError = .unavailable

        let outcome = APIKeyMigrationService(secretStore: store).migrateLegacyAPIKeys()

        XCTAssertEqual(outcome.pendingProviders, [.openAI])
        XCTAssertEqual(outcome.securedSecrets, [:])
        XCTAssertEqual(UserDefaults.standard.string(forKey: SettingsKeys.legacyOpenAIAPIKey), legacySecret)
        XCTAssertNil(try store.secret(for: .openAI))
        XCTAssertEqual(
            APIKeyMigrationService.failureMessage(for: .openAI),
            "Couldn't secure the saved OpenAI API key. It remains in Settings; check Keychain access and try again."
        )
    }

    func testStartupPublishesMigrationFailureWhilePreservingLegacySecret() {
        // WHY: A retained legacy key is only recoverable if startup exposes a safe, actionable
        // warning. Otherwise migration can fail silently and leave plaintext credentials behind.
        let store = InMemorySecretStore()
        let legacySecret = "test-legacy-custom-key"
        UserDefaults.standard.set("Custom", forKey: SettingsKeys.ttsProvider)
        UserDefaults.standard.set(legacySecret, forKey: SettingsKeys.legacyCustomAPIKey)
        store.nextError = .unavailable

        let manager = TestNetworkFactory.makeManager(secretStore: store)

        XCTAssertEqual(
            manager.lastError,
            "Couldn't secure the saved Custom API key. It remains in Settings; check Keychain access and try again."
        )
        XCTAssertEqual(UserDefaults.standard.string(forKey: SettingsKeys.legacyCustomAPIKey), legacySecret)
        XCTAssertNil(try? store.secret(for: .custom))
    }

    func testPendingProvidersNameOnlyTheKeysAMigrationRetryStillHasToSecure() {
        // WHY: Settings decides from this set whether to offer recovery at all. A key the store
        // already accepted must not invite a retry that touches the Keychain again, and an empty
        // legacy value carries no secret to rescue — only a retained plaintext key can still be
        // lost, which is exactly what a failed migration leaves behind.
        let store = InMemorySecretStore()
        UserDefaults.standard.set("test-legacy-openai-key", forKey: SettingsKeys.legacyOpenAIAPIKey)
        UserDefaults.standard.set("", forKey: SettingsKeys.legacyGeminiAPIKey)
        UserDefaults.standard.set("test-legacy-custom-key", forKey: SettingsKeys.legacyCustomAPIKey)
        store.nextError = .unavailable

        XCTAssertEqual(APIKeyMigrationService.pendingProviders(defaults: .standard), [.openAI, .custom])

        // The scheduled failure lands on the first provider the migration touches.
        let outcome = APIKeyMigrationService(secretStore: store).migrateLegacyAPIKeys()

        XCTAssertEqual(outcome.pendingProviders, [.openAI])
        XCTAssertEqual(outcome.securedSecrets, [.custom: "test-legacy-custom-key"])
        XCTAssertEqual(APIKeyMigrationService.pendingProviders(defaults: .standard), [.openAI])
    }

    func testMigrationMovesLegacySecretOnceAndDoesNotRewriteOnTheNextLaunch() throws {
        // WHY: A completed migration must remove the plaintext source, so a later launch neither
        // exposes it through UserDefaults nor overwrites the Keychain value again.
        let store = InMemorySecretStore()
        let legacySecret = "test-legacy-gemini-key"
        UserDefaults.standard.set(legacySecret, forKey: SettingsKeys.legacyGeminiAPIKey)
        let migration = APIKeyMigrationService(secretStore: store)

        XCTAssertEqual(migration.migrateLegacyAPIKeys(), APIKeyMigrationOutcome(securedSecrets: [.gemini: legacySecret]))
        XCTAssertEqual(try store.secret(for: .gemini), legacySecret)
        XCTAssertNil(UserDefaults.standard.object(forKey: SettingsKeys.legacyGeminiAPIKey))

        XCTAssertEqual(migration.migrateLegacyAPIKeys(), APIKeyMigrationOutcome())
        XCTAssertEqual(try store.secret(for: .gemini), legacySecret)
        XCTAssertNil(UserDefaults.standard.object(forKey: SettingsKeys.legacyGeminiAPIKey))
    }

    func testMigrationPreservesAnExistingKeychainSecretOverStalePlaintext() throws {
        // WHY: A user can save a replacement after a failed migration. A later launch must remove
        // the stale plaintext value without overwriting the newer Keychain credential.
        let store = InMemorySecretStore()
        try store.saveSecret("test-new-keychain-key", for: .openAI)
        UserDefaults.standard.set("test-stale-legacy-key", forKey: SettingsKeys.legacyOpenAIAPIKey)

        XCTAssertEqual(
            APIKeyMigrationService(secretStore: store).migrateLegacyAPIKeys(),
            APIKeyMigrationOutcome(securedSecrets: [.openAI: "test-new-keychain-key"])
        )
        XCTAssertEqual(try store.secret(for: .openAI), "test-new-keychain-key")
        XCTAssertNil(UserDefaults.standard.object(forKey: SettingsKeys.legacyOpenAIAPIKey))
    }
}
