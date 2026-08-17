import SwiftUI

/// The model and voice fields shared by every provider's Settings form, each paired with the
/// suggestion list its provider publishes.
struct ModelVoiceConfigurationView: View {
    @Binding var ttsModel: String
    @Binding var ttsVoice: String
    @ObservedObject var networkManager: TTSNetworkManager
    var onSync: () -> Void

    var body: some View {
        Section(header: Text("Model & Voice").font(.headline)) {
            HStack {
                TextField("Model", text: $ttsModel)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .onChange(of: ttsModel) { _ in onSync() }

                if !networkManager.availableModels.isEmpty {
                    Picker("", selection: $ttsModel) {
                        ForEach(networkManager.availableModels, id: \.self) { model in
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

                if !networkManager.availableVoices.isEmpty {
                    Picker("", selection: $ttsVoice) {
                        ForEach(networkManager.availableVoices, id: \.self) { voice in
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
