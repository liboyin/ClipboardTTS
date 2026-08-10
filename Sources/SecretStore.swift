import Foundation
import Security

/// The providers whose API keys are kept outside of app preferences.
enum APIKeyProvider: CaseIterable, Hashable {
    case openAI
    case gemini
    case custom

    /// Stable Keychain account used for this provider's API key.
    var keychainAccount: String {
        switch self {
        case .openAI:
            return "openai-api-key"
        case .gemini:
            return "gemini-api-key"
        case .custom:
            return "custom-api-key"
        }
    }

    /// The temporary preference key used by versions released before Keychain storage.
    var legacyUserDefaultsKey: String {
        switch self {
        case .openAI:
            return SettingsKeys.legacyOpenAIAPIKey
        case .gemini:
            return SettingsKeys.legacyGeminiAPIKey
        case .custom:
            return SettingsKeys.legacyCustomAPIKey
        }
    }

    /// A human-readable provider name for application-owned failure messages.
    var displayName: String {
        switch self {
        case .openAI:
            return "OpenAI"
        case .gemini:
            return "Gemini"
        case .custom:
            return "Custom"
        }
    }

    /// The persisted provider value corresponding to this known provider.
    var settingsValue: String {
        displayName
    }

    /// Resolves corrupted or obsolete provider values to OpenAI's fixed, trusted configuration.
    init(selectedProvider: String) {
        switch selectedProvider {
        case "Gemini":
            self = .gemini
        case "Custom":
            self = .custom
        default:
            self = .openAI
        }
    }
}

/// Errors exposed by a secret store without leaking an underlying security-system detail.
enum SecretStoreError: Error, Equatable {
    case unavailable
    case invalidStoredValue
}

/// A narrow interface for API-key persistence.
protocol SecretStoring: AnyObject {
    func secret(for provider: APIKeyProvider) throws -> String?
    func saveSecret(_ secret: String, for provider: APIKeyProvider) throws
    func deleteSecret(for provider: APIKeyProvider) throws
}

/// Stores API keys as generic-password items in the user's login Keychain.
final class KeychainSecretStore: SecretStoring {
    private static let service = "com.clipboardtts.api-keys"

    func secret(for provider: APIKeyProvider) throws -> String? {
        var query = itemQuery(for: provider)
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecReturnData] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data,
              let secret = String(data: data, encoding: .utf8) else {
            throw status == errSecSuccess ? SecretStoreError.invalidStoredValue : .unavailable
        }
        return secret
    }

    func saveSecret(_ secret: String, for provider: APIKeyProvider) throws {
        let query = itemQuery(for: provider)
        let value = Data(secret.utf8)
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData: value] as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw SecretStoreError.unavailable
        }

        var newItem = query
        newItem[kSecValueData] = value
        guard SecItemAdd(newItem as CFDictionary, nil) == errSecSuccess else {
            throw SecretStoreError.unavailable
        }
    }

    func deleteSecret(for provider: APIKeyProvider) throws {
        let status = SecItemDelete(itemQuery(for: provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.unavailable
        }
    }

    private func itemQuery(for provider: APIKeyProvider) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: provider.keychainAccount
        ]
    }
}

/// A process-local secret store for dependency-injected unit tests.
final class InMemorySecretStore: SecretStoring {
    private var secrets: [APIKeyProvider: String] = [:]
    /// Causes the next store operation to fail, allowing tests to exercise recovery paths.
    var nextError: SecretStoreError?

    func secret(for provider: APIKeyProvider) throws -> String? {
        try consumeNextError()
        return secrets[provider]
    }

    func saveSecret(_ secret: String, for provider: APIKeyProvider) throws {
        try consumeNextError()
        secrets[provider] = secret
    }

    func deleteSecret(for provider: APIKeyProvider) throws {
        try consumeNextError()
        secrets.removeValue(forKey: provider)
    }

    private func consumeNextError() throws {
        guard let nextError else { return }
        self.nextError = nil
        throw nextError
    }
}

/// Migrates legacy plaintext API-key preferences without discarding a key that could not be saved.
struct APIKeyMigrationService {
    let secretStore: SecretStoring

    /// Moves every non-empty legacy key to the secret store and returns the providers that need user attention.
    func migrateLegacyAPIKeys(defaults: UserDefaults = .standard) -> [APIKeyProvider] {
        APIKeyProvider.allCases.compactMap { provider in
            guard let legacySecret = defaults.string(forKey: provider.legacyUserDefaultsKey) else {
                return nil
            }
            guard !legacySecret.isEmpty else {
                defaults.removeObject(forKey: provider.legacyUserDefaultsKey)
                return nil
            }

            do {
                if let savedSecret = try secretStore.secret(for: provider) {
                    try secretStore.saveSecret(savedSecret, for: provider)
                } else {
                    try secretStore.saveSecret(legacySecret, for: provider)
                }
                defaults.removeObject(forKey: provider.legacyUserDefaultsKey)
                return nil
            } catch {
                return provider
            }
        }
    }

    /// Gives the user safe, actionable guidance without exposing a stored key or Keychain error.
    static func failureMessage(for provider: APIKeyProvider) -> String {
        "Couldn't secure the saved \(provider.displayName) API key. It remains in Settings; check Keychain access and try again."
    }
}

/// The current provider key and any safe startup error that should be shown to the user.
struct APIKeyStartupState {
    let apiKey: String
    let errorMessage: String?

    /// Migrates a legacy key before reading the selected provider's current saved key.
    static func load(selectedProvider: String,
                     secretStore: SecretStoring,
                     defaults: UserDefaults = .standard) -> APIKeyStartupState {
        let migrationFailures = APIKeyMigrationService(secretStore: secretStore).migrateLegacyAPIKeys(defaults: defaults)
        let provider = APIKeyProvider(selectedProvider: selectedProvider)
        do {
            return APIKeyStartupState(
                apiKey: try secretStore.secret(for: provider) ?? "",
                errorMessage: migrationFailures.first.map(APIKeyMigrationService.failureMessage(for:))
            )
        } catch {
            return APIKeyStartupState(
                apiKey: "",
                errorMessage: migrationFailures.first.map(APIKeyMigrationService.failureMessage(for:))
                    ?? "Couldn't read the saved \(provider.displayName) API key. Check Keychain access and try again."
            )
        }
    }
}
