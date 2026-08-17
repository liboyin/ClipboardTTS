import Foundation
@testable import ClipboardTTSApp

/// A secret store whose failures a test schedules per provider, so one migration attempt can fail
/// for one provider while it succeeds for another.
///
/// It also records the writes and deletions the app performed, which is how a test can prove that
/// an ordinary launch only read from storage. Every member is used from the main thread, where
/// manager construction and the Settings form both run.
final class ScriptedSecretStore: SecretStoring {
    /// Providers whose store operations fail until the test clears them.
    var failingProviders: Set<APIKeyProvider> = []
    /// How many further reads the store will answer before every later one fails. A test sets this
    /// to let a migration write succeed while refusing the read a naive read-back would perform.
    var allowedReadCount: Int?
    private(set) var savedProviders: [APIKeyProvider] = []
    private(set) var deletedProviders: [APIKeyProvider] = []
    private var secrets: [APIKeyProvider: String] = [:]

    /// Places a value without recording it as storage work the app performed.
    func seed(_ secret: String, for provider: APIKeyProvider) {
        secrets[provider] = secret
    }

    /// Reads a value without consulting the failure script, so an assertion can inspect storage
    /// while the store is still scheduled to fail.
    func storedSecret(for provider: APIKeyProvider) -> String? {
        secrets[provider]
    }

    func secret(for provider: APIKeyProvider) throws -> String? {
        try failIfScheduled(for: provider)
        if let remainingReads = allowedReadCount {
            guard remainingReads > 0 else { throw SecretStoreError.unavailable }
            allowedReadCount = remainingReads - 1
        }
        return secrets[provider]
    }

    func saveSecret(_ secret: String, for provider: APIKeyProvider) throws {
        try failIfScheduled(for: provider)
        savedProviders.append(provider)
        secrets[provider] = secret
    }

    func deleteSecret(for provider: APIKeyProvider) throws {
        try failIfScheduled(for: provider)
        deletedProviders.append(provider)
        secrets.removeValue(forKey: provider)
    }

    private func failIfScheduled(for provider: APIKeyProvider) throws {
        guard failingProviders.contains(provider) else { return }
        throw SecretStoreError.unavailable
    }
}
