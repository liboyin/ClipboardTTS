import XCTest
import SwiftUI
import AppKit
@testable import ClipboardTTSApp

/// Covers how often one Settings edit applies the form and which suggestion lists it refreshes.
///
/// Hosted Settings drives `NSHostingView` and the AppKit controls it builds, so every test here
/// runs on the main actor.
@MainActor
final class SettingsMetadataRefreshTests: MockURLProtocolTestCase {
    func testATypedEditRunsItsFieldCallbackOnceBesideARenderedPicker() {
        // WHY: The field and the suggestion picker beside it edit the same binding. Observing each
        // control rather than the binding ran every edit's callback twice, which applied the form
        // and started model discovery twice per keystroke. Both pickers must render here, because
        // the duplicate only exists while there is a second control to observe.
        let networkManager = TestNetworkFactory.makeManager()
        networkManager.modelSuggestions = ProviderSuggestions(provider: .openAI, values: ["tts-1", "tts-1-hd"])
        networkManager.voiceSuggestions = ProviderSuggestions(provider: .openAI, values: ["alloy", "nova"])
        let fields = HostedEditableModelVoiceFields(
            networkManager: networkManager,
            provider: .openAI,
            model: "tts-1",
            voice: "alloy",
            testCase: self
        )
        XCTAssertEqual(fields.suggestionControls().count, 2, "Both rows must render their picker.")

        fields.type("tts-1-hd", intoFieldAt: 0, expecting: "tts-1")
        XCTAssertEqual(fields.callbackCounts, .init(model: 1, voice: 0))

        fields.type("nova", intoFieldAt: 1, expecting: "alloy")
        XCTAssertEqual(fields.callbackCounts, .init(model: 1, voice: 1))
        fields.release()
    }

    func testATypedEditRunsItsFieldCallbackWhenNoPickerRenders() {
        // WHY: A Custom endpoint publishes no suggestions, so its rows render no picker at all. The
        // text field alone must still report each edit, or a Custom model or voice would never
        // reach the requests the form configures.
        let networkManager = TestNetworkFactory.makeManager()
        let fields = HostedEditableModelVoiceFields(
            networkManager: networkManager,
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
    }

    func testAPickerSelectionRunsItsFieldCallbackOnce() {
        // WHY: Choosing a suggestion is the other way to edit the same binding, so it must report
        // the edit exactly once as well: not zero, which would leave the choice unapplied, and not
        // twice, which is the duplicate a typed edit also had.
        let networkManager = TestNetworkFactory.makeManager()
        networkManager.modelSuggestions = ProviderSuggestions(provider: .openAI, values: ["tts-1", "tts-1-hd"])
        networkManager.voiceSuggestions = ProviderSuggestions(provider: .openAI, values: ["alloy", "nova"])
        let fields = HostedEditableModelVoiceFields(
            networkManager: networkManager,
            provider: .openAI,
            model: "tts-1",
            voice: "alloy",
            testCase: self
        )

        fields.select("tts-1-hd", inSuggestionControlAt: 0)
        XCTAssertEqual(fields.fieldTexts(), ["tts-1-hd", "alloy"], "The selection must reach the binding.")
        XCTAssertEqual(fields.callbackCounts, .init(model: 1, voice: 0))

        fields.select("nova", inSuggestionControlAt: 1)
        XCTAssertEqual(fields.fieldTexts(), ["tts-1-hd", "nova"], "The selection must reach the binding.")
        XCTAssertEqual(fields.callbackCounts, .init(model: 1, voice: 1))
        fields.release()
    }

    func testEachSettingsEditRefreshesOnlyTheSuggestionListsThatDependOnIt() throws {
        // WHY: Model discovery is a provider request authorized with the user's key, and it depends
        // only on the provider, endpoint, and key. Refreshing it on every model or voice keystroke
        // spent a request per character on a list the edit could not change. The OpenAI voice
        // catalog does depend on the model, so a model edit must still republish it, after the edit
        // reaches the manager the catalog reads. A key edit must still rediscover models.
        // Each edit is also checked against what the manager will send, because refreshing nothing
        // is not the same as applying nothing.
        let defaults = makeOwnedDefaults([SettingsKeys.ttsProvider: "OpenAI"])
        let secretStore = InMemorySecretStore()
        try secretStore.saveSecret("test-openai-key", for: .openAI)
        let audioPlayer = AudioPlayerManager()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore, defaults: defaults)
        MockURLProtocol.installRequestHandler { request in
            metadataResponse(for: request, json: "{ \"data\": [{\"id\": \"tts-1\"}, {\"id\": \"gpt-4o-mini-tts\"}] }")
        }
        let settings = HostedSettings(
            networkManager: networkManager,
            audioPlayer: audioPlayer,
            secretStore: secretStore,
            defaults: defaults,
            testCase: self
        )
        var begun = metadataRequestsBegun(by: networkManager)

        settings.type("nova", into: .providerVoice, expecting: "alloy")
        XCTAssertEqual(metadataRequestsBegun(by: networkManager) - begun, 0, "No suggestion list depends on the voice.")
        XCTAssertEqual(networkManager.requestSettingsSnapshot().voice, "nova")
        begun = metadataRequestsBegun(by: networkManager)

        settings.type("gpt-4o-mini-tts", into: .providerModel, expecting: "tts-1")
        XCTAssertEqual(
            metadataRequestsBegun(by: networkManager) - begun,
            1,
            "A model edit must republish the voice catalog alone, without rediscovering models."
        )
        XCTAssertEqual(networkManager.requestSettingsSnapshot().model, "gpt-4o-mini-tts")
        XCTAssertEqual(
            networkManager.voiceSuggestions,
            ProviderSuggestions(provider: .openAI, values: currentOpenAIVoices),
            "The republished catalog must be the one the edited model offers."
        )
        begun = metadataRequestsBegun(by: networkManager)

        settings.typeAPIKey("replacement-openai-key")
        XCTAssertEqual(
            metadataRequestsBegun(by: networkManager) - begun,
            2,
            "A key edit must rediscover models and republish the voice catalog."
        )
        XCTAssertEqual(networkManager.requestSettingsSnapshot().apiKey, "replacement-openai-key")
        settings.release()
    }
}

/// The OpenAI voices every model other than `tts-1` and `tts-1-hd` offers, as the manager lists them.
private let currentOpenAIVoices = [
    "alloy", "ash", "ballad", "coral", "echo", "fable", "onyx", "nova", "sage",
    "shimmer", "verse", "marin", "cedar"
]

/// Returns how many model and voice metadata requests the manager has begun so far.
///
/// Every begun request takes the next identifier synchronously, before any publication or network
/// work, so the difference across one settled edit counts exactly the refreshes that edit started.
private func metadataRequestsBegun(by manager: TTSNetworkManager) -> UInt64 {
    manager.stateQueue.sync { manager.nextMetadataRequestIdentifier }
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

    /// The fields in a `Form`, as Settings renders them, over state the host owns.
    private struct EditableFields: View {
        @State var model: String
        @State var voice: String
        let networkManager: TTSNetworkManager
        let provider: APIKeyProvider
        let counter: CallbackCounter

        var body: some View {
            Form {
                ModelVoiceConfigurationView(
                    ttsModel: $model,
                    ttsVoice: $voice,
                    networkManager: networkManager,
                    provider: provider,
                    onModelChange: { counter.counts.model += 1 },
                    onVoiceChange: { counter.counts.voice += 1 }
                )
            }
        }
    }

    private let counter = CallbackCounter()
    private var host: NSHostingView<EditableFields>?

    var callbackCounts: CallbackCounts { counter.counts }

    init(networkManager: TTSNetworkManager,
         provider: APIKeyProvider,
         model: String,
         voice: String,
         testCase: XCTestCase,
         file: StaticString = #filePath,
         line: UInt = #line) {
        let host = NSHostingView(rootView: EditableFields(
            model: model,
            voice: voice,
            networkManager: networkManager,
            provider: provider,
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
