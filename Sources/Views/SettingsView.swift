import SwiftUI

struct SettingsView: View {
    @ObservedObject var networkManager: TTSNetworkManager
    
    @AppStorage("apiBaseURL") private var apiBaseURL: String = "https://api.openai.com/v1/audio/speech"
    @AppStorage("apiKey") private var apiKey: String = ""
    @AppStorage("ttsModel") private var ttsModel: String = "tts-1"
    @AppStorage("ttsVoice") private var ttsVoice: String = "alloy"
    
    var body: some View {
        Form {
            Section(header: Text("API Configuration").font(.headline)) {
                TextField("Base URL", text: $apiBaseURL)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                
                SecureField("API Key", text: $apiKey)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
            .padding(.bottom, 10)
            
            Section(header: Text("Model & Voice").font(.headline)) {
                TextField("Model (e.g., tts-1)", text: $ttsModel)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                
                TextField("Voice (e.g., alloy, echo, fable)", text: $ttsVoice)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
            
            HStack {
                Spacer()
                Button("Save") {
                    networkManager.updateSettings(
                        baseURL: apiBaseURL,
                        apiKey: apiKey,
                        model: ttsModel,
                        voice: ttsVoice
                    )
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top)
        }
        .padding()
        .frame(width: 400, height: 280)
        .onAppear {
            networkManager.updateSettings(
                baseURL: apiBaseURL,
                apiKey: apiKey,
                model: ttsModel,
                voice: ttsVoice
            )
        }
    }
}
