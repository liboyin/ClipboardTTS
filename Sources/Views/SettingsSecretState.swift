import Combine
import Foundation

/// Holds the Settings form's API keys and surfaces safe Keychain failures to the user.
///
/// This owns the form's storage side — reading keys when the form is built, persisting edits, and
/// recovering a key the store refused to read or a legacy key that migration could not secure —
/// so `SettingsView` stays the declarative form.
final class SettingsSecretState: ObservableObject {
    @Published private var secrets: [APIKeyProvider: String] = [:]
    @Published private(set) var errorMessage: String?
    /// The providers whose legacy plaintext key still has to be secured, in provider order.
    @Published private(set) var pendingMigrationProviders: [APIKeyProvider]
    /// The providers whose key could not be read, so resolving one can surface the next instead of
    /// leaving the form silent about a key the user still cannot use. Published because the form
    /// offers its read retry only while one remains.
    @Published private(set) var unreadableProviders: Set<APIKeyProvider> = []
    /// The providers whose edit the store refused. Held per provider for the same reason: the form
    /// shows one failure at a time, so a later failure must not be the end of an earlier one.
    private var unsavedProviders: Set<APIKeyProvider> = []
    private let secretStore: SecretStoring
    private let defaults: UserDefaults

    init(secretStore: SecretStoring, defaults: UserDefaults) {
        self.secretStore = secretStore
        self.defaults = defaults
        self.pendingMigrationProviders = APIKeyMigrationService.pendingProviders(defaults: defaults)
        for provider in APIKeyProvider.allCases {
            do {
                secrets[provider] = try secretStore.secret(for: provider) ?? ""
            } catch {
                secrets[provider] = ""
                unreadableProviders.insert(provider)
            }
        }
        errorMessage = unresolvedFailureMessage()
    }

    /// Reruns the migration that failed, using the same store and preferences startup migrates.
    ///
    /// A provider keeps its plaintext value until the store confirms the write, so one that fails
    /// again stays pending with its key recoverable, while one that succeeds hands back the value
    /// it secured for the form to adopt in place of whatever was readable at mount.
    func retryLegacyKeyMigration() {
        let retriedProviders = pendingMigrationProviders
        let outcome = APIKeyMigrationService(secretStore: secretStore).migrateLegacyAPIKeys(defaults: defaults)
        for provider in retriedProviders {
            guard let securedSecret = outcome.securedSecrets[provider] else { continue }
            adoptReadSecret(securedSecret, for: provider)
        }
        pendingMigrationProviders = outcome.pendingProviders
    }

    /// Reads again every key the store refused, and returns the providers it could read this time.
    ///
    /// Only providers still unreadable are asked: one the user has stored an edit for since is no
    /// longer unreadable, so the value they typed is never replaced by a read, and a read that
    /// fails now cannot report a failure about a key the store just accepted. A provider that
    /// still fails keeps its guidance and its retry.
    @discardableResult
    func retryUnreadableSecrets() -> [APIKeyProvider] {
        var recoveredProviders: [APIKeyProvider] = []
        for provider in APIKeyProvider.allCases where unreadableProviders.contains(provider) {
            // A key that is simply absent is a successful read, so it resolves the failure too.
            guard let storedSecret = try? secretStore.secret(for: provider) ?? "" else { continue }
            adoptReadSecret(storedSecret, for: provider)
            recoveredProviders.append(provider)
        }
        return recoveredProviders
    }

    /// Returns the key currently shown for a provider without reading preferences or the Keychain again.
    func secret(for provider: APIKeyProvider) -> String {
        secrets[provider] ?? ""
    }

    /// Persists a user edit immediately so future clipboard and Services requests use the same key.
    ///
    /// A stored edit also retires whatever plaintext copy migration was still trying to rescue for
    /// that provider. The user has just said what this credential is — including that it is now
    /// nothing — so keeping the old copy would let a migration, here or on a later launch, put a
    /// replaced or deleted key back into the Keychain and into the next request. Only a write the
    /// store confirmed does this; a refused edit leaves the plaintext exactly where it was.
    func saveSecret(_ secret: String, for provider: APIKeyProvider) {
        do {
            if secret.isEmpty {
                try secretStore.deleteSecret(for: provider)
            } else {
                try secretStore.saveSecret(secret, for: provider)
            }
            secrets[provider] = secret
            // The store accepted this provider's key, so an earlier read failure for it no longer
            // describes anything a later recovery should resurface.
            unreadableProviders.remove(provider)
            unsavedProviders.remove(provider)
            defaults.removeObject(forKey: provider.legacyUserDefaultsKey)
            pendingMigrationProviders.removeAll { $0 == provider }
            // Withdraw only what this write settles — this provider's read or save failure — and
            // then say what is still wrong. Treating a stored edit as a general all-clear would
            // hide another provider's key that the user still cannot read or save.
            if errorMessage == Self.readFailureMessage(for: provider)
                || errorMessage == Self.saveFailureMessage(for: provider) {
                errorMessage = unresolvedFailureMessage()
            }
        } catch {
            unsavedProviders.insert(provider)
            errorMessage = Self.saveFailureMessage(for: provider)
        }
    }

    /// Adopts a provider's key once the app has read it, from a retried read or from the value a
    /// confirmed migration secured, which required reading it.
    ///
    /// That provider's mount-time read failure is disproved and gives way to the next unresolved
    /// one — never to silence while another key is still unreadable. Only that provider's own
    /// message is replaced: a save failure the user has not fixed describes something this says
    /// nothing about.
    private func adoptReadSecret(_ secret: String, for provider: APIKeyProvider) {
        secrets[provider] = secret
        unreadableProviders.remove(provider)
        if errorMessage == Self.readFailureMessage(for: provider) {
            errorMessage = unresolvedFailureMessage()
        }
    }

    /// The guidance for the first provider with something still unresolved, in provider order.
    ///
    /// A refused save outranks that same provider's earlier read failure, because it describes the
    /// user's own most recent attempt on that key.
    private func unresolvedFailureMessage() -> String? {
        for provider in APIKeyProvider.allCases {
            if unsavedProviders.contains(provider) {
                return Self.saveFailureMessage(for: provider)
            }
            if unreadableProviders.contains(provider) {
                return Self.readFailureMessage(for: provider)
            }
        }
        return nil
    }

    private static func readFailureMessage(for provider: APIKeyProvider) -> String {
        APIKeyStartupState.readFailureMessage(for: provider)
    }

    private static func saveFailureMessage(for provider: APIKeyProvider) -> String {
        "Couldn't save the \(provider.displayName) API key. Check Keychain access and try again."
    }
}
