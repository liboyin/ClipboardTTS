import SwiftUI

/// The Settings recoveries for a saved API key that storage could not handle: reading one the
/// store refused, and securing a legacy key migration left in plaintext.
///
/// Each guidance line says to try again, but the app otherwise reads keys only when Settings is
/// built and migrates them only when a new `TTSNetworkManager` is created, so "again" would mean
/// an undocumented relaunch. Each action is rendered only while its failure remains, so offering
/// it is evidence of a real problem rather than an invitation to a Keychain prompt for nothing.
struct SavedKeyRecoveryView: View {
    @ObservedObject var secretState: SettingsSecretState
    let retryReading: () -> Void
    let retrySecuring: () -> Void

    var body: some View {
        if !secretState.unreadableProviders.isEmpty {
            actionRow(title: "Retry Reading Saved Keys", action: retryReading)
        }

        // Rendered for every pending provider, because one that keeps failing must stay visible
        // after another one succeeds.
        if !secretState.pendingMigrationProviders.isEmpty {
            Section {
                ForEach(secretState.pendingMigrationProviders, id: \.self) { provider in
                    Text(APIKeyMigrationService.failureMessage(for: provider))
                        .foregroundStyle(.red)
                }

                actionRow(title: "Retry Securing Saved Keys", action: retrySecuring)
            }
        }
    }

    private func actionRow(title: String, action: @escaping () -> Void) -> some View {
        HStack {
            // An `NSViewRepresentable` is greedy by default, so `.fixedSize()` keeps the control
            // hugging its title.
            SettingsActionButton(title: title, action: action)
                .fixedSize()

            Spacer()
        }
    }
}
