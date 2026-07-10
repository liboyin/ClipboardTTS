import SwiftUI

struct SettingsView: View {
    @ObservedObject var networkManager: TTSNetworkManager
    @ObservedObject var audioPlayer: AudioPlayerManager

    @AppStorage("ttsProvider") private var ttsProvider: String = "OpenAI"
    @AppStorage("apiBaseURL") private var apiBaseURL: String = "https://api.openai.com/v1/audio/speech"
    @AppStorage("apiKey") private var openaiAPIKey: String = ""
    @AppStorage("geminiAPIKey") private var geminiAPIKey: String = ""
    @AppStorage("customAPIKey") private var customAPIKey: String = ""
    @AppStorage("openaiModel") private var openaiModel: String = "tts-1"
    @AppStorage("openaiVoice") private var openaiVoice: String = "alloy"
    @AppStorage("geminiModel") private var geminiModel: String = "gemini-3.1-flash-tts-preview"
    @AppStorage("geminiVoice") private var geminiVoice: String = "Aoede"
    var currentAPIKey: String {
        if ttsProvider == "OpenAI" { return openaiAPIKey }
        if ttsProvider == "Gemini" { return geminiAPIKey }
        return customAPIKey
    }

    var currentBaseURL: String {
        if ttsProvider == "OpenAI" { return "https://api.openai.com/v1/audio/speech" }
        if ttsProvider == "Gemini" { return "https://generativelanguage.googleapis.com/v1beta" }
        return apiBaseURL
    }

    var currentModel: String {
        if ttsProvider == "OpenAI" { return openaiModel }
        if ttsProvider == "Gemini" { return geminiModel }
        return ""
    }

    var currentVoice: String {
        if ttsProvider == "OpenAI" { return openaiVoice }
        if ttsProvider == "Gemini" { return geminiVoice }
        return ""
    }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $ttsProvider) {
                Text("OpenAI").tag("OpenAI")
                Text("Gemini").tag("Gemini")
                Text("Custom").tag("Custom")
            }
            .listStyle(.sidebar)
            .frame(width: 150)
            .onChange(of: ttsProvider) { newValue in
                providerDidChange(to: newValue)
            }

            Divider()

            Form {
                if ttsProvider == "OpenAI" {
                    openAISettings
                } else if ttsProvider == "Gemini" {
                    geminiSettings
                } else {
                    customSettings
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 600, height: 350)
        .onAppear {
            syncSettings()
        }
    }

    private var openAISettings: some View {
        Group {
            Section(header: Text("OpenAI Configuration").font(.headline)) {
                SecureField("API Key", text: $openaiAPIKey)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .onChange(of: openaiAPIKey) { _ in syncSettings() }
            }

            ModelVoiceConfigurationView(ttsModel: $openaiModel, ttsVoice: $openaiVoice,
                                        networkManager: networkManager, onSync: syncSettings)

            testVoiceButton
        }
    }

    private var geminiSettings: some View {
        Group {
            Section(header: Text("Gemini Configuration").font(.headline)) {
                SecureField("API Key", text: $geminiAPIKey)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .onChange(of: geminiAPIKey) { _ in syncSettings() }
            }

            ModelVoiceConfigurationView(ttsModel: $geminiModel, ttsVoice: $geminiVoice,
                                        networkManager: networkManager, onSync: syncSettings)

            testVoiceButton
        }
    }

    private var customSettings: some View {
        Group {
            Section(header: Text("Custom Configuration").font(.headline)) {
                TextField("Base URL", text: $apiBaseURL)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .onChange(of: apiBaseURL) { _ in syncSettings() }

                SecureField("API Key", text: $customAPIKey)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .onChange(of: customAPIKey) { _ in syncSettings() }
            }

            testVoiceButton
        }
    }

    private var testVoiceButton: some View {
        HStack {
            Button("Test Voice") {
                runTestVoice()
            }
            .buttonStyle(.bordered)

            Spacer()
        }
        .padding(.top)
    }

    func runTestVoice() {
        networkManager.updateSettings(
            baseURL: currentBaseURL,
            apiKey: currentAPIKey,
            model: currentModel,
            voice: currentVoice
        )
        networkManager.stopStreaming()
        audioPlayer.stop()
        let gen = audioPlayer.startNewStream()
        networkManager.streamTTS(text: "Hello! This is a test of your text to speech configuration.") { data in
            audioPlayer.scheduleAudio(data: data, streamGeneration: gen)
        }
    }

    func providerDidChange(to newValue: String) {
        syncSettings()
    }

    func syncSettings() {
        networkManager.updateSettings(
            baseURL: currentBaseURL,
            apiKey: currentAPIKey,
            model: currentModel,
            voice: currentVoice
        )
        fetchMetadata()
    }

    func fetchMetadata() {
        if ttsProvider == "Custom" { return }
        networkManager.fetchAvailableModels(baseURL: currentBaseURL, apiKey: currentAPIKey)
        networkManager.fetchAvailableVoices(baseURL: currentBaseURL, apiKey: currentAPIKey)
    }
}

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
