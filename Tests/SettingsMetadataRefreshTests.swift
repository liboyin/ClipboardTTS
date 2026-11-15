import XCTest
import SwiftUI
import AppKit
@testable import ClipboardTTSApp

/// Covers how often one Settings edit applies the form, whichever control made it, and that a
/// picker rebuilt without an edit applies nothing.
///
/// Hosted Settings drives `NSHostingView` and the AppKit controls it builds, so every test here
/// runs on the main actor.
@MainActor
final class SettingsMetadataRefreshTests: MockURLProtocolTestCase {
    func testATypedEditRunsItsFieldCallbackOnceBesideARenderedPicker() {
        // WHY: The field and the suggestion picker beside it edit the same binding. Observing each
        // control rather than the binding ran every edit's callback twice, which applied the form
        // twice per keystroke. Both pickers must render here, because the duplicate only exists
        // while there is a second control to observe.
        let fields = HostedEditableModelVoiceFields(
            provider: .openAI,
            model: "gpt-realtime-2.1-mini",
            voice: "alloy",
            testCase: self
        )

        XCTAssertEqual(fields.suggestionControls().count, 2, "Both rows must render their picker.")
        fields.type("gpt-realtime-2.1", intoFieldAt: 0, expecting: "gpt-realtime-2.1-mini")
        XCTAssertEqual(fields.callbackCounts, .init(model: 1, voice: 0))
        fields.type("ash", intoFieldAt: 1, expecting: "alloy")
        XCTAssertEqual(fields.callbackCounts, .init(model: 1, voice: 1))
        fields.release()
    }

    func testATypedEditRunsItsFieldCallbackWhenNoPickerRenders() {
        // WHY: A Custom endpoint documents no catalog, so its rows render no picker at all. The
        // text field alone must still report each edit, or a Custom model or voice would never
        // reach the requests the form configures.
        let fields = HostedEditableModelVoiceFields(
            provider: .custom,
            model: "custom-model",
            voice: "custom-voice",
            testCase: self
        )

        XCTAssertEqual(fields.suggestionControls(), [], "A Custom row must render no picker.")
        fields.type("other-model", intoFieldAt: 0, expecting: "custom-model")
        XCTAssertEqual(fields.callbackCounts, .init(model: 1, voice: 0))
        fields.type("other-voice", intoFieldAt: 1, expecting: "custom-voice")
        XCTAssertEqual(fields.callbackCounts, .init(model: 1, voice: 1))
        fields.release()

        // The absence above holds only if this lookup can see a picker at all: rows that do offer
        // suggestions, in the same host, must render one it finds for each row.
        let suggestingFields = HostedEditableModelVoiceFields(
            provider: .openAI,
            model: "gpt-realtime-2.1-mini",
            voice: "alloy",
            testCase: self
        )
        XCTAssertEqual(suggestingFields.suggestionControls().count, 2, "Rows with suggestions must render a visible picker.")
        suggestingFields.release()
    }

    func testAPickerSelectionRunsItsFieldCallbackOnce() {
        // WHY: Choosing a suggestion is the other way to edit the same binding, so it must report
        // the edit exactly once as well: not zero, which would leave the choice unapplied, and not
        // twice, which is the duplicate a typed edit also had.
        let fields = HostedEditableModelVoiceFields(
            provider: .openAI,
            model: "gpt-realtime-2.1-mini",
            voice: "alloy",
            testCase: self
        )

        fields.select("gpt-realtime-2.1", inSuggestionControlAt: 0)
        XCTAssertEqual(fields.fieldTexts(), ["gpt-realtime-2.1", "alloy"], "The selection must reach the binding.")
        XCTAssertEqual(fields.callbackCounts, .init(model: 1, voice: 0))

        fields.select("ash", inSuggestionControlAt: 1)
        XCTAssertEqual(fields.fieldTexts(), ["gpt-realtime-2.1", "ash"], "The selection must reach the binding.")
        XCTAssertEqual(fields.callbackCounts, .init(model: 1, voice: 1))
        fields.release()
    }

    func testRebuiltSuggestionChoicesRunNoFieldCallback() {
        // WHY: A picker's choices change without any edit when a typed value the catalog lacks is
        // prepended to it, and when the row is rendered for another provider's catalog. Rebuilding
        // the picker for either must keep showing the bound value and must not write it, or the row
        // would run its callback, and apply the form, for an edit nobody made. The voice starts on
        // the second choice so that a rebuild selecting or writing its first item would change it.
        let fields = HostedEditableModelVoiceFields(
            provider: .openAI,
            model: "gpt-realtime-2.1-mini",
            voice: "ash",
            testCase: self
        )

        fields.type("typed-model", intoFieldAt: 0, expecting: "gpt-realtime-2.1-mini")
        XCTAssertEqual(
            fields.suggestionControls().first,
            HostedSettings.SuggestionControl(
                choices: ["typed-model", "gpt-realtime-2.1-mini", "gpt-realtime-2.1"],
                selection: "typed-model"
            )
        )
        XCTAssertEqual(fields.callbackCounts, .init(model: 1, voice: 0), "One typed edit runs one callback.")

        fields.render(provider: .gemini)

        XCTAssertEqual(
            fields.suggestionControls().last,
            HostedSettings.SuggestionControl(choices: ["ash"] + documentedGeminiTTSVoices, selection: "ash")
        )
        XCTAssertEqual(fields.fieldTexts(), ["typed-model", "ash"])
        XCTAssertEqual(fields.callbackCounts, .init(model: 1, voice: 0), "A rebuilt catalog is not an edit.")
        fields.release()
    }

    func testEachKeyModelAndVoiceEditReachesFutureRequests() throws {
        // WHY: A clipboard or Services request reads the manager's settings, not the form, so each
        // edit must reach them as it is made. OpenAI's catalogs need no request, so no handler is
        // installed and one sent would fail this scope's accounting.
        let defaults = makeOwnedDefaults([SettingsKeys.ttsProvider: "OpenAI"])
        let secretStore = InMemorySecretStore()
        try secretStore.saveSecret("test-openai-key", for: .openAI)
        let audioPlayer = makeOwnedAudioPlayer()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore, defaults: defaults)
        let settings = HostedSettings(
            networkManager: networkManager,
            audioPlayer: audioPlayer,
            secretStore: secretStore,
            defaults: defaults,
            testCase: self
        )

        settings.type("marin", into: .providerVoice, expecting: "alloy")
        XCTAssertEqual(networkManager.requestSettingsSnapshot().voice, "marin")

        settings.type("gpt-realtime-2.1", into: .providerModel, expecting: "gpt-realtime-2.1-mini")
        XCTAssertEqual(networkManager.requestSettingsSnapshot().model, "gpt-realtime-2.1")

        settings.typeAPIKey("replacement-openai-key")
        XCTAssertEqual(networkManager.requestSettingsSnapshot().apiKey, "replacement-openai-key")
        settings.release()
    }
}

/// Hosts the shared model and voice fields over live bindings and counts the callbacks each edit
/// runs, which `HostedSettings` cannot observe because the form supplies its own callbacks.
@MainActor
private final class HostedEditableModelVoiceFields {
    struct CallbackCounts: Equatable {
        var model: Int
        var voice: Int
    }

    /// Receives the callbacks. SwiftUI runs them on the main thread while the host settles.
    private final class CallbackCounter {
        var counts = CallbackCounts(model: 0, voice: 0)
    }

    /// The provider the fields render, which a test can change without editing either binding.
    private final class RenderedProvider: ObservableObject {
        @Published var provider: APIKeyProvider

        init(_ provider: APIKeyProvider) {
            self.provider = provider
        }
    }

    /// The fields in a `Form`, as Settings renders them, over state the host owns.
    private struct EditableFields: View {
        @State var model: String
        @State var voice: String
        @ObservedObject var renderedProvider: RenderedProvider
        let counter: CallbackCounter

        var body: some View {
            Form {
                ModelVoiceConfigurationView(
                    ttsModel: $model,
                    ttsVoice: $voice,
                    provider: renderedProvider.provider,
                    onModelChange: { counter.counts.model += 1 },
                    onVoiceChange: { counter.counts.voice += 1 }
                )
            }
        }
    }

    private let counter = CallbackCounter()
    private let renderedProvider: RenderedProvider
    private var host: NSHostingView<EditableFields>?

    var callbackCounts: CallbackCounts { counter.counts }

    init(provider: APIKeyProvider,
         model: String,
         voice: String,
         testCase: XCTestCase,
         file: StaticString = #filePath,
         line: UInt = #line) {
        let renderedProvider = RenderedProvider(provider)
        self.renderedProvider = renderedProvider
        let host = NSHostingView(rootView: EditableFields(
            model: model,
            voice: voice,
            renderedProvider: renderedProvider,
            counter: counter
        ))
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 200)
        self.host = host
        testCase.addTeardownBlock {
            self.release(file: file, line: line)
        }
        settleHostedView(host, file: file, line: line)
    }

    /// Types into the field at `position` (Model is 0, Voice is 1) after proving it holds
    /// `currentText`, for the reason `HostedSettings.type` gives.
    func type(_ newText: String,
              intoFieldAt position: Int,
              expecting currentText: String,
              file: StaticString = #filePath,
              line: UInt = #line) {
        let fields = editableTextFields()
        guard fields.indices.contains(position), fields[position].stringValue == currentText else {
            XCTFail("Field \(position) does not hold \"\(currentText)\".", file: file, line: line)
            return
        }
        editHostedTextField(fields[position], to: newText, file: file, line: line)
        settleHostedView(host, file: file, line: line)
    }

    /// Chooses `title` in the suggestion picker at `position` the way a click on its menu item does.
    func select(_ title: String,
                inSuggestionControlAt position: Int,
                file: StaticString = #filePath,
                line: UInt = #line) {
        var popUpButtons: [NSPopUpButton] = []
        host?.collectPopUpButtons(into: &popUpButtons)
        guard popUpButtons.indices.contains(position),
              let menu = popUpButtons[position].menu,
              case let index = popUpButtons[position].indexOfItem(withTitle: title), index >= 0 else {
            XCTFail("Suggestion control \(position) does not offer \"\(title)\".", file: file, line: line)
            return
        }
        menu.performActionForItem(at: index)
        settleHostedView(host, file: file, line: line)
    }

    /// Renders the same bindings for `provider`'s catalogs, which rebuilds both pickers without
    /// editing either value, and runs the main-queue turns that render needs.
    func render(provider: APIKeyProvider, file: StaticString = #filePath, line: UInt = #line) {
        renderedProvider.provider = provider
        settleHostedView(host, file: file, line: line)
    }

    /// Returns the text each field shows, in rendering order.
    func fieldTexts() -> [String] {
        editableTextFields().map(\.stringValue)
    }

    /// Returns every suggestion control these fields render, in rendering order.
    func suggestionControls() -> [HostedSettings.SuggestionControl] {
        var controls: [HostedSettings.SuggestionControl] = []
        host?.collectSuggestionControls(into: &controls)
        return controls
    }

    /// Releases the hosted view graph and drains the main queue. Calling it twice is safe.
    func release(file: StaticString = #filePath, line: UInt = #line) {
        guard host != nil else { return }
        host = nil
        drainHostedMainQueue(file: file, line: line)
    }

    private func editableTextFields() -> [NSTextField] {
        var fields: [NSTextField] = []
        host?.collectEditableTextFields(into: &fields)
        return fields
    }
}

@MainActor
private extension NSView {
    func collectPopUpButtons(into buttons: inout [NSPopUpButton]) {
        if let popUpButton = self as? NSPopUpButton {
            buttons.append(popUpButton)
        }
        subviews.forEach { $0.collectPopUpButtons(into: &buttons) }
    }
}
