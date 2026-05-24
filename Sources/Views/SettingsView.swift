import SwiftUI

struct SettingsView: View {
    @ObservedObject var networkManager: TTSNetworkManager
    @ObservedObject var audioPlayer: AudioPlayerManager
    
    @AppStorage("ttsProvider") private var ttsProvider: String = "OpenAI"
    @AppStorage("apiBaseURL") private var apiBaseURL: String = "https://api.openai.com/v1/audio/speech"
    @AppStorage("apiKey") private var openaiAPIKey: String = ""
    @AppStorage("geminiAPIKey") private var geminiAPIKey: String = ""
    @AppStorage("customAPIKey") private var customAPIKey: String = ""
    @AppStorage("ttsModel") private var ttsModel: String = "tts-1"
    @AppStorage("ttsVoice") private var ttsVoice: String = "alloy"
    
    private var currentAPIKey: String {
        if ttsProvider == "OpenAI" { return openaiAPIKey }
        if ttsProvider == "Gemini" { return geminiAPIKey }
        return customAPIKey
    }
    
    private var currentBaseURL: String {
        if ttsProvider == "OpenAI" { return "https://api.openai.com/v1/audio/speech" }
        if ttsProvider == "Gemini" { return "https://generativelanguage.googleapis.com/v1beta" }
        return apiBaseURL
    }
    let providers = ["OpenAI", "Gemini", "Custom"]
    
    var body: some View {
        Form {
            Section(header: Text("API Configuration").font(.headline)) {
                Picker("Provider", selection: $ttsProvider) {
                    ForEach(providers, id: \.self) { provider in
                        Text(provider).tag(provider)
                    }
                }
                .onChange(of: ttsProvider) { newValue in
                    if newValue == "OpenAI" {
                        ttsModel = "tts-1"
                        ttsVoice = "alloy"
                    } else if newValue == "Gemini" {
                        ttsModel = "gemini-3.1-flash"
                        ttsVoice = "Aoede"
                    }
                    syncSettings()
                }

                if ttsProvider == "Custom" {
                    TextField("Base URL", text: $apiBaseURL)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .onChange(of: apiBaseURL) { _ in syncSettings() }
                }
                
                if ttsProvider == "OpenAI" {
                    SecureField("API Key", text: $openaiAPIKey)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .onChange(of: openaiAPIKey) { _ in syncSettings() }
                } else if ttsProvider == "Gemini" {
                    SecureField("API Key", text: $geminiAPIKey)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .onChange(of: geminiAPIKey) { _ in syncSettings() }
                } else {
                    SecureField("API Key", text: $customAPIKey)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .onChange(of: customAPIKey) { _ in syncSettings() }
                }
            }
            .padding(.bottom, 10)
            
            Section(header: Text("Model & Voice").font(.headline)) {
                HStack {
                    TextField("Model (e.g., tts-1)", text: $ttsModel)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .onChange(of: ttsModel) { _ in syncSettings() }
                    
                    if ttsProvider != "Custom" && !networkManager.availableModels.isEmpty {
                        Picker("", selection: $ttsModel) {
                            ForEach(networkManager.availableModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 30)
                        .onChange(of: ttsModel) { _ in syncSettings() }
                    }
                }
                
                HStack {
                    TextField("Voice (e.g., alloy)", text: $ttsVoice)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .onChange(of: ttsVoice) { _ in syncSettings() }
                    
                    if ttsProvider != "Custom" && !networkManager.availableVoices.isEmpty {
                        Picker("", selection: $ttsVoice) {
                            ForEach(networkManager.availableVoices, id: \.self) { voice in
                                Text(voice).tag(voice)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 30)
                        .onChange(of: ttsVoice) { _ in syncSettings() }
                    }
                }
            }
            
            HStack {
                Button("Test Voice") {
                    networkManager.updateSettings(
                        baseURL: currentBaseURL,
                        apiKey: currentAPIKey,
                        model: ttsModel,
                        voice: ttsVoice
                    )
                    networkManager.stopStreaming()
                    audioPlayer.stop()
                    networkManager.streamTTS(text: "Hello! This is a test of your text to speech configuration.") { data in
                        audioPlayer.scheduleAudio(data: data)
                    }
                }
                .buttonStyle(.bordered)
                
                Spacer()
                Button("Save") {
                    networkManager.updateSettings(
                        baseURL: currentBaseURL,
                        apiKey: currentAPIKey,
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
            syncSettings()
        }
    }
    
    private func syncSettings() {
        networkManager.updateSettings(
            baseURL: currentBaseURL,
            apiKey: currentAPIKey,
            model: ttsModel,
            voice: ttsVoice
        )
        fetchMetadata()
    }
    
    private func fetchMetadata() {
        if ttsProvider == "Custom" { return }
        networkManager.fetchAvailableModels(baseURL: currentBaseURL, apiKey: currentAPIKey)
        networkManager.fetchAvailableVoices(baseURL: currentBaseURL, apiKey: currentAPIKey)
    }
}
