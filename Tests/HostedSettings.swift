import XCTest
import SwiftUI
import AppKit
@testable import ClipboardTTSApp

/// Hosts `SettingsView` through a real SwiftUI lifecycle and drives the controls it renders.
///
/// Constructing `SettingsView` as a value leaves its lifecycle storage uninstalled. SwiftUI then
/// builds a fresh `SettingsSecretState` on every `@StateObject` access and discards `@State` writes,
/// so an unhosted test exercises different state identity from the production window and can pass
/// for a reason production never reproduces. Hosting installs that storage once, which is also the
/// only way a test can observe one retained secret state across several edits and actions.
///
/// Every member must be used from the main thread: `NSHostingView`, the AppKit controls it builds,
/// and the main-queue turns that order SwiftUI's updates all require it.
final class HostedSettings {
    /// A plain (non-secure) Custom-form text field, addressed by its position among those fields.
    enum PlainTextField {
        case customModel
        case customSampleRate

        /// The field's index among the Custom form's plain text fields, in rendering order:
        /// Base URL, Model, Voice, PCM Sample Rate. The API key is excluded because it is secure.
        var position: Int {
            switch self {
            case .customModel:
                return 1
            case .customSampleRate:
                return 3
            }
        }
    }

    private var host: NSHostingView<SettingsView>?

    init(networkManager: TTSNetworkManager,
         audioPlayer: AudioPlayerManager,
         secretStore: SecretStoring,
         aboutAction: AboutAction = AboutAction(),
         testCase: XCTestCase,
         file: StaticString = #filePath,
         line: UInt = #line) {
        let view = SettingsView(
            networkManager: networkManager,
            audioPlayer: audioPlayer,
            secretStore: secretStore,
            aboutAction: aboutAction
        )
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 350)
        self.host = host
        // A test that exits before releasing the host — including by throwing — must still not
        // leave its settings observers alive. This block retains the helper deliberately: under a
        // weak capture the test's own reference is the only strong one, so an early exit
        // deinitializes the helper first and the fallback then finds nothing to release, skipping
        // the main-queue drain. XCTest runs teardown blocks before `tearDown()`, so this still
        // lands before the mock scope invalidates its session.
        testCase.addTeardownBlock {
            self.release(file: file, line: line)
        }
        settle(file: file, line: line)
    }

    /// Presses the Settings control carrying this title.
    func click(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let button = host?.descendantButton(titled: title) else {
            XCTFail("Settings must render a \(title) button.", file: file, line: line)
            return
        }
        button.performClick(nil)
        settle(file: file, line: line)
    }

    /// Types `newText` into a Custom-form field after proving the position still addresses it.
    ///
    /// Neither a placeholder nor an accessibility identifier survives into the AppKit layer of a
    /// windowless host, so position is the only address available. `expecting` is what makes that
    /// safe: a reordered form fails this anchor instead of silently editing a different field.
    func type(_ newText: String,
              into field: PlainTextField,
              expecting currentText: String,
              file: StaticString = #filePath,
              line: UInt = #line) {
        let plainFields = editableTextFields().filter { !($0 is NSSecureTextField) }
        guard field.position < plainFields.count else {
            XCTFail(
                "The Custom form renders \(plainFields.count) plain text fields, so position \(field.position) is absent.",
                file: file,
                line: line
            )
            return
        }
        let control = plainFields[field.position]
        guard control.stringValue == currentText else {
            XCTFail(
                """
                Plain text field \(field.position) holds "\(control.stringValue)" rather than the \
                expected "\(currentText)", so the form order no longer matches this address.
                """,
                file: file,
                line: line
            )
            return
        }
        edit(control, to: newText, file: file, line: line)
    }

    /// Types a new API key into the form's key field, which is the only secure field it renders.
    func typeAPIKey(_ newText: String, file: StaticString = #filePath, line: UInt = #line) {
        let secureFields = editableTextFields().compactMap { $0 as? NSSecureTextField }
        guard secureFields.count == 1, let control = secureFields.first else {
            XCTFail(
                "Settings must render exactly one API-key field; the host renders \(secureFields.count).",
                file: file,
                line: line
            )
            return
        }
        edit(control, to: newText, file: file, line: line)
    }

    /// Returns the choices offered by each suggestion control the form currently renders.
    func suggestionLists() -> [[String]] {
        var lists: [[String]] = []
        host?.collectSuggestionLists(into: &lists)
        return lists
    }

    /// Switches provider the way the sidebar does, by writing the setting its selection is bound to.
    ///
    /// The sidebar `List` is bound to `@AppStorage(SettingsKeys.ttsProvider)`, so writing that key
    /// drives the installed view through the same binding and `onChange` production uses. The row
    /// itself is drawn by SwiftUI and backs no AppKit control a test could select.
    func selectProvider(_ provider: String, file: StaticString = #filePath, line: UInt = #line) {
        UserDefaults.standard.set(provider, forKey: SettingsKeys.ttsProvider)
        settle(file: file, line: line)
    }

    /// Releases the hosted view graph and drains the main queue.
    ///
    /// The hosted view owns settings observers, so releasing it before `MockURLProtocol` invalidates
    /// the test's session is what stops a deferred observer from starting a metadata request after
    /// its scope closed. Calling this more than once is safe.
    func release(file: StaticString = #filePath, line: UInt = #line) {
        guard host != nil else { return }
        host = nil
        drainMainQueue(file: file, line: line)
    }

    /// Replaces a field's text the way typing does, so SwiftUI's binding runs its setter.
    ///
    /// SwiftUI's macOS text fields observe their `NSTextField` through a coordinator implementing
    /// `controlTextDidChange(_:)`. Assigning `stringValue` alone changes only what AppKit displays,
    /// so the notification below is what carries the edit into the installed lifecycle storage.
    private func edit(_ control: NSTextField, to newText: String, file: StaticString, line: UInt) {
        guard let coordinator = control.delegate else {
            XCTFail(
                "The hosted text field has no SwiftUI coordinator, so an edit cannot reach its binding.",
                file: file,
                line: line
            )
            return
        }
        control.stringValue = newText
        coordinator.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: control))
        settle(file: file, line: line)
    }

    private func editableTextFields() -> [NSTextField] {
        var fields: [NSTextField] = []
        host?.collectEditableTextFields(into: &fields)
        return fields
    }

    /// Runs the main-queue turns SwiftUI needs to apply a change and rebuild its AppKit controls.
    ///
    /// One turn delivers the observation a change produced; the next runs the work its updated body
    /// scheduled. Laying out around them forces the controls a later lookup addresses to exist now
    /// rather than at some arbitrary later moment, which is what replaces a timing delay here.
    private func settle(file: StaticString, line: UInt) {
        for _ in 0..<2 {
            host?.layoutSubtreeIfNeeded()
            drainMainQueue(file: file, line: line)
        }
        host?.layoutSubtreeIfNeeded()
    }

    private func drainMainQueue(file: StaticString, line: UInt) {
        let drained = XCTestExpectation(description: "Hosted Settings completed a main-queue turn")
        DispatchQueue.main.async { drained.fulfill() }
        guard XCTWaiter().wait(for: [drained], timeout: 2.0) == .completed else {
            XCTFail("The hosted Settings view did not complete a main-queue turn within 2 seconds.", file: file, line: line)
            return
        }
    }
}

private extension NSView {
    func descendantButton(titled title: String) -> NSButton? {
        if let button = self as? NSButton, button.title == title {
            return button
        }
        return subviews.lazy.compactMap { $0.descendantButton(titled: title) }.first
    }

    /// Collects every editable field in rendering order, so a caller can address one by position.
    func collectEditableTextFields(into fields: inout [NSTextField]) {
        if let field = self as? NSTextField, field.isEditable {
            fields.append(field)
        }
        subviews.forEach { $0.collectEditableTextFields(into: &fields) }
    }

    /// Collects the item titles of every descendant pop-up button, which is how the form renders
    /// its model and voice suggestions.
    func collectSuggestionLists(into lists: inout [[String]]) {
        if let popUpButton = self as? NSPopUpButton {
            lists.append(popUpButton.itemTitles)
        }
        subviews.forEach { $0.collectSuggestionLists(into: &lists) }
    }
}
