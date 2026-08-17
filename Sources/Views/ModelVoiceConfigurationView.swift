import SwiftUI

/// The model and voice fields shared by every provider's Settings form, each paired with the
/// suggestion list its own provider published.
struct ModelVoiceConfigurationView: View {
    @Binding var ttsModel: String
    @Binding var ttsVoice: String
    @ObservedObject var networkManager: TTSNetworkManager
    /// The persisted provider whose form this is; only suggestions published for it may be offered.
    let provider: String
    var onSync: () -> Void

    /// The choices a suggestion picker may offer for `selection`, or none when it must not render.
    ///
    /// A list published for another provider is refused outright, because this form renders a newly
    /// selected provider's saved values one render before `onChange` resynchronizes the manager.
    /// `selection` is always among the choices returned: SwiftUI documents a picker whose selection
    /// has no matching tag as undefined, so a model or voice the provider does not list is offered
    /// as it was typed, keeping it selected while the catalog it can be corrected from stays usable.
    static func pickerChoices(from suggestions: ProviderSuggestions,
                              for provider: String,
                              selection: String) -> [String] {
        let choices = suggestions.values(for: provider)
        guard !choices.isEmpty, !choices.contains(selection) else { return choices }
        return [selection] + choices
    }

    private var modelChoices: [String] {
        Self.pickerChoices(from: networkManager.modelSuggestions, for: provider, selection: ttsModel)
    }

    private var voiceChoices: [String] {
        Self.pickerChoices(from: networkManager.voiceSuggestions, for: provider, selection: ttsVoice)
    }

    var body: some View {
        Section(header: Text("Model & Voice").font(.headline)) {
            HStack {
                TextField("Model", text: $ttsModel)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .onChange(of: ttsModel) { _ in onSync() }

                if !modelChoices.isEmpty {
                    Picker("", selection: $ttsModel) {
                        ForEach(modelChoices, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 30)
                    .onChange(of: ttsModel) { _ in onSync() }
                }
            }

            HStack {
                TextField("Voice", text: $ttsVoice)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .onChange(of: ttsVoice) { _ in onSync() }

                if !voiceChoices.isEmpty {
                    Picker("", selection: $ttsVoice) {
                        ForEach(voiceChoices, id: \.self) { voice in
                            Text(voice).tag(voice)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 30)
                    .onChange(of: ttsVoice) { _ in onSync() }
                }
            }
        }
    }
}
