import SwiftUI

struct SettingsView: View {
    @ObservedObject private var networkManager: TTSNetworkManager
    @ObservedObject private var audioPlayer: AudioPlayerManager
    @StateObject private var secretState: SettingsSecretState
    private let aboutAction: AboutAction

    @AppStorage(SettingsKeys.ttsProvider) private var ttsProvider: String = "OpenAI"
    @AppStorage(SettingsKeys.apiBaseURL) private var apiBaseURL: String = "https://api.openai.com/v1/audio/speech"
    @AppStorage(SettingsKeys.openAIModel) private var openaiModel: String = "tts-1"
    @AppStorage(SettingsKeys.openAIVoice) private var openaiVoice: String = "alloy"
    @AppStorage(SettingsKeys.geminiModel) private var geminiModel: String = "gemini-3.1-flash-tts-preview"
    @AppStorage(SettingsKeys.geminiVoice) private var geminiVoice: String = "Aoede"
    @AppStorage(SettingsKeys.customModel) private var customModel: String = ""
    @AppStorage(SettingsKeys.customVoice) private var customVoice: String = ""
    @AppStorage(SettingsKeys.customSampleRate) private var customSampleRate: Double = AudioPlayerManager.defaultSampleRate
    @State private var customSampleRateText = ""
    @State private var isCustomSampleRateDraftValid = true

    init(networkManager: TTSNetworkManager,
         audioPlayer: AudioPlayerManager,
         secretStore: SecretStoring = KeychainSecretStore(),
         aboutAction: AboutAction = AboutAction()) {
        self.networkManager = networkManager
        self.audioPlayer = audioPlayer
        self.aboutAction = aboutAction
        _secretState = StateObject(wrappedValue: SettingsSecretState(secretStore: secretStore))
    }

    private var selectedProvider: APIKeyProvider {
        APIKeyProvider(selectedProvider: ttsProvider)
    }

    private var currentAPIKey: String {
        secretState.secret(for: selectedProvider)
    }

    private var currentBaseURL: String {
        switch selectedProvider {
        case .openAI:
            return "https://api.openai.com/v1/audio/speech"
        case .gemini:
            return "https://generativelanguage.googleapis.com/v1beta"
        case .custom:
            return apiBaseURL
        }
    }

    private var currentModel: String {
        switch selectedProvider {
        case .openAI:
            return openaiModel
        case .gemini:
            return geminiModel
        case .custom:
            return customModel
        }
    }

    private var currentVoice: String {
        switch selectedProvider {
        case .openAI:
            return openaiVoice
        case .gemini:
            return geminiVoice
        case .custom:
            return customVoice
        }
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

            VStack(spacing: 0) {
                Form {
                    if let secretStoreError = secretState.errorMessage {
                        Text(secretStoreError)
                            .foregroundStyle(.red)
                    }
                    if selectedProvider == .openAI {
                        openAISettings
                    } else if selectedProvider == .gemini {
                        geminiSettings
                    } else {
                        customSettings
                    }
                }
                .padding(20)

                aboutButton
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 600, height: 350)
        .onAppear {
            customSampleRateText = String(format: "%.0f", customSampleRate)
            isCustomSampleRateDraftValid = AudioPlayerManager.isSupportedSampleRate(customSampleRate)
            syncSettings()
        }
    }

    private var openAISettings: some View {
        Group {
            Section(header: Text("OpenAI Configuration").font(.headline)) {
                SecureField("API Key", text: secretBinding(for: .openAI))
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }

            ModelVoiceConfigurationView(ttsModel: $openaiModel, ttsVoice: $openaiVoice,
                                        networkManager: networkManager, onSync: syncSettings)

            testVoiceButton
        }
    }

    private var geminiSettings: some View {
        Group {
            Section(header: Text("Gemini Configuration").font(.headline)) {
                SecureField("API Key", text: secretBinding(for: .gemini))
                    .textFieldStyle(RoundedBorderTextFieldStyle())
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

                SecureField("API Key", text: secretBinding(for: .custom))
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }

            ModelVoiceConfigurationView(ttsModel: $customModel, ttsVoice: $customVoice,
                                        networkManager: networkManager, onSync: syncSettings)

            Section(header: Text("Audio Format").font(.headline)) {
                TextField("PCM Sample Rate (Hz)", text: $customSampleRateText)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .onChange(of: customSampleRateText) { updateCustomSampleRate(from: $0) }
                if let sampleRateError = audioPlayer.sampleRateError {
                    Text(sampleRateError)
                        .foregroundStyle(.red)
                }
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

    private var aboutButton: some View {
        VStack(spacing: 0) {
            Divider()

            HStack {
                SettingsAboutButton(action: showAbout)

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    func showAbout() {
        aboutAction.showAbout()
    }

    func runTestVoice() {
        normalizeSelectedProvider()
        guard syncAudioFormat() else { return }
        networkManager.updateSettings(
            baseURL: currentBaseURL,
            apiKey: currentAPIKey,
            model: currentModel,
            voice: currentVoice,
            selectedProvider: selectedProvider.settingsValue
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
        normalizeSelectedProvider()
        networkManager.updateSettings(
            baseURL: currentBaseURL,
            apiKey: currentAPIKey,
            model: currentModel,
            voice: currentVoice,
            selectedProvider: selectedProvider.settingsValue
        )
        _ = syncAudioFormat()
        fetchMetadata()
    }

    /// Selects the fixed provider format or the validated Custom override for future audio.
    @discardableResult
    func syncAudioFormat() -> Bool {
        guard selectedProvider != .custom || (isCustomSampleRateDraftValid && audioPlayer.hasValidSampleRateInput) else {
            _ = audioPlayer.setSampleRate(.nan)
            return false
        }
        let customDraftSampleRate = Double(customSampleRateText) ?? customSampleRate
        let targetSampleRate = selectedProvider == .custom ? customDraftSampleRate : AudioPlayerManager.defaultSampleRate
        switch audioPlayer.setSampleRate(targetSampleRate) {
        case .updated, .unchanged:
            if selectedProvider == .custom {
                customSampleRate = customDraftSampleRate
            }
            return true
        case .invalid, .engineStartFailed:
            return false
        }
    }

    /// Validates a Custom sample-rate edit before replacing the persisted last-known-good value.
    func updateCustomSampleRate(from text: String) {
        guard let sampleRate = Double(text) else {
            isCustomSampleRateDraftValid = false
            _ = audioPlayer.setSampleRate(.nan)
            return
        }
        switch audioPlayer.setSampleRate(sampleRate) {
        case .updated, .unchanged:
            isCustomSampleRateDraftValid = true
            customSampleRate = sampleRate
        case .invalid:
            isCustomSampleRateDraftValid = false
        case .engineStartFailed:
            isCustomSampleRateDraftValid = true
        }
    }

    func fetchMetadata() {
        guard selectedProvider != .custom else { return }
        networkManager.fetchAvailableModels(
            baseURL: currentBaseURL,
            apiKey: currentAPIKey,
            selectedProvider: selectedProvider.settingsValue
        )
        networkManager.fetchAvailableVoices(
            baseURL: currentBaseURL,
            apiKey: currentAPIKey,
            selectedProvider: selectedProvider.settingsValue
        )
    }

    private func normalizeSelectedProvider() {
        let normalizedValue = selectedProvider.settingsValue
        if ttsProvider != normalizedValue {
            ttsProvider = normalizedValue
        }
    }

    private func secretBinding(for provider: APIKeyProvider) -> Binding<String> {
        Binding(
            get: { secretState.secret(for: provider) },
            set: {
                secretState.saveSecret($0, for: provider)
                syncSettings()
            }
        )
    }
}

/// Holds the Settings form's API keys and surfaces safe Keychain failures to the user.
final class SettingsSecretState: ObservableObject {
    @Published private var secrets: [APIKeyProvider: String] = [:]
    @Published private(set) var errorMessage: String?
    private let secretStore: SecretStoring

    init(secretStore: SecretStoring) {
        self.secretStore = secretStore
        for provider in APIKeyProvider.allCases {
            do {
                secrets[provider] = try secretStore.secret(for: provider) ?? ""
            } catch {
                secrets[provider] = ""
                if errorMessage == nil {
                    errorMessage = "Couldn't read the saved \(provider.displayName) API key. Check Keychain access and try again."
                }
            }
        }
    }

    /// Returns the key currently shown for a provider without reading preferences or the Keychain again.
    func secret(for provider: APIKeyProvider) -> String {
        secrets[provider] ?? ""
    }

    /// Persists a user edit immediately so future clipboard and Services requests use the same key.
    func saveSecret(_ secret: String, for provider: APIKeyProvider) {
        do {
            if secret.isEmpty {
                try secretStore.deleteSecret(for: provider)
            } else {
                try secretStore.saveSecret(secret, for: provider)
            }
            errorMessage = nil
            secrets[provider] = secret
        } catch {
            errorMessage = "Couldn't save the \(provider.displayName) API key. Check Keychain access and try again."
        }
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
