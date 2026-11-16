import AppKit
import SwiftUI

/// A pop-up button offering a Settings row's suggestions for the value its text field edits.
///
/// Settings renders these through AppKit rather than `Picker` for the reason `SettingsActionButton`
/// gives: from macOS 27 SwiftUI draws a picker itself instead of backing it with an
/// `NSPopUpButton`, so a hosted test has no control to read or choose from, and whether SwiftUI
/// backs a control with AppKit changes between releases. An `NSViewRepresentable`'s view is part
/// of the hosting view's tree by construction (D36).
///
/// The control shows `selection` as its selected item, or none when `choices` lacks it. Choosing an
/// item writes that choice to `selection`; nothing else does. In particular, updating the view never
/// writes the binding, so a row observing its value with `onChange` runs once per edit, whichever
/// control made it.
///
/// The row draws the button 30 points wide, showing only its arrows, so nothing visible says what
/// it offers; `accessibilityLabel` is what names it to assistive technology.
struct SuggestionPicker: NSViewRepresentable {
    let choices: [String]
    /// What the button offers suggestions for. It has no default, so no picker can be left unnamed.
    let accessibilityLabel: String
    @Binding var selection: String

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.choose(_:))
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let coordinator = context.coordinator
        coordinator.selection = $selection
        button.setAccessibilityLabel(accessibilityLabel)
        if coordinator.choices != choices {
            coordinator.choices = choices
            button.removeAllItems()
            // `addItems(withTitles:)` would remove an earlier item carrying the same title, so each
            // choice is added as its own menu item and keeps its position and title as given.
            for choice in choices {
                button.menu?.addItem(NSMenuItem(title: choice, action: nil, keyEquivalent: ""))
            }
        }
        // Selecting programmatically sends no action, so this cannot write the binding.
        button.selectItem(at: choices.firstIndex(of: selection) ?? -1)
    }

    /// Takes the width the row offers, at the button's own height.
    ///
    /// Without this, SwiftUI sizes the button to fit its longest title, so in the row's 30-point
    /// slot it overflows across the text field beside it; the narrow button shows only its arrows,
    /// which is how the row has always presented its suggestions. With no width offered, the button
    /// keeps the width its titles need.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView button: NSPopUpButton, context: Context) -> CGSize? {
        let natural = button.intrinsicContentSize
        guard let width = proposal.width, width.isFinite else { return natural }
        return CGSize(width: width, height: natural.height)
    }

    /// Delivers a chosen item to the binding the latest update supplied. AppKit sends its action on
    /// the main thread, where the button it reads lives.
    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<String>
        /// The choices the button's items were built from, in item order.
        var choices: [String] = []

        init(selection: Binding<String>) {
            self.selection = selection
        }

        @objc func choose(_ sender: NSPopUpButton) {
            let index = sender.indexOfSelectedItem
            guard choices.indices.contains(index) else { return }
            selection.wrappedValue = choices[index]
        }
    }
}
