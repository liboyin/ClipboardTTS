import AppKit
import SwiftUI

/// A standard AppKit push button for one of Settings' actions.
///
/// Settings renders its actions through AppKit rather than `Button` because SwiftUI draws a button
/// itself instead of backing it with an `NSView`. A hosted regression therefore has no control to
/// press: a windowless `NSHostingView` exposes no such button and publishes no accessibility tree,
/// and wrapping the test host in an `NSWindow` is forbidden because AppKit window teardown can
/// outlive the test. `bezelStyle = .rounded` is the same standard push button `.buttonStyle(.bordered)`
/// renders.
struct SettingsActionButton: NSViewRepresentable {
    let title: String
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            title: title,
            target: context.coordinator,
            action: #selector(Coordinator.invoke)
        )
        button.bezelStyle = .rounded
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        button.title = title
        context.coordinator.action = action
    }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func invoke() {
            action()
        }
    }
}
