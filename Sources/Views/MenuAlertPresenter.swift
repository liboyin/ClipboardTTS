import AppKit

/// Presents an app-owned modal alert for a menu action that stopped before it did any work.
///
/// The menu deactivates the app so its dropdown can close, so anything it must tell the user
/// afterwards has to bring the app back to the front first. Both halves belong to this seam
/// together: a test substitutes one double and thereby neither activates the real test host nor
/// runs a modal panel no one can dismiss.
///
/// Main-actor isolated so the confinement the menu flow relies on is the compiler's to enforce
/// rather than a comment: every conformer runs AppKit or test state that belongs to the main queue.
@MainActor
protocol MenuAlertPresenting {
    /// Returns the app to the foreground and shows `title` and `message` until the user dismisses them.
    func presentAlert(title: String, message: String)
}

/// Shows the production `NSAlert`, whose panel AppKit makes keyboard- and VoiceOver-accessible.
struct AppKitMenuAlertPresenter: MenuAlertPresenting {
    func presentAlert(title: String, message: String) {
        // The click deactivated the app to close the dropdown, so an alert raised without
        // reactivating would open behind whatever the user is reading.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
