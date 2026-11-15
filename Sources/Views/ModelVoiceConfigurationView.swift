import SwiftUI

/// The model and voice fields shared by every provider's Settings form, each paired with the
/// catalog its own provider documents.
struct ModelVoiceConfigurationView: View {
    @Binding var ttsModel: String
    @Binding var ttsVoice: String
    /// The provider whose form this is, which alone names the catalogs its pickers offer.
    ///
    /// The choices are looked up from this value on every render rather than held anywhere, so the
    /// render a provider switch makes before `onChange` resynchronizes the manager already offers
    /// the new provider's catalogs (D38).
    let provider: APIKeyProvider
    /// Runs once per change to `ttsModel`, whichever control made it.
    var onModelChange: () -> Void
    /// Runs once per change to `ttsVoice`, whichever control made it.
    var onVoiceChange: () -> Void

    /// The choices a suggestion picker may offer for `selection`, or none when it must not render.
    ///
    /// A provider that documents no catalog (`nil`), such as Custom, renders no picker. `selection`
    /// is otherwise always among the choices returned, so the picker always shows a selected item:
    /// a model or voice the provider does not list is offered first, as it was typed, keeping it
    /// selected while the catalog it can be corrected from stays usable.
    static func pickerChoices(from catalog: [String]?, selection: String) -> [String] {
        guard let catalog, !catalog.isEmpty, !catalog.contains(selection) else { return catalog ?? [] }
        return [selection] + catalog
    }

    private var modelChoices: [String] {
        Self.pickerChoices(from: ProviderMetadataCatalog.models(for: provider), selection: ttsModel)
    }

    private var voiceChoices: [String] {
        Self.pickerChoices(from: ProviderMetadataCatalog.voices(for: provider), selection: ttsVoice)
    }

    var body: some View {
        Section(header: Text("Model & Voice").font(.headline)) {
            HStack {
                TextField("Model", text: $ttsModel)
                    .textFieldStyle(RoundedBorderTextFieldStyle())

                if !modelChoices.isEmpty {
                    SuggestionPicker(choices: modelChoices, selection: $ttsModel)
                        .frame(width: 30)
                }
            }
            // Each row observes its binding rather than each control: the field and the picker edit
            // the same value, so an observer on both would run the callback twice for one edit.
            .onChange(of: ttsModel) { onModelChange() }

            HStack {
                TextField("Voice", text: $ttsVoice)
                    .textFieldStyle(RoundedBorderTextFieldStyle())

                if !voiceChoices.isEmpty {
                    SuggestionPicker(choices: voiceChoices, selection: $ttsVoice)
                        .frame(width: 30)
                }
            }
            .onChange(of: ttsVoice) { onVoiceChange() }
        }
    }
}
