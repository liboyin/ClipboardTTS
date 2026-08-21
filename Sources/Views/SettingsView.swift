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

    /// Builds the form. `defaults` has no default value on purpose: the migration this form can
    /// retry reads and clears legacy keys, so it must be the same domain the app migrated at
    /// startup rather than whichever one `.standard` names in the caller's process.
    ///
    /// It reaches only that migration. The properties below are plain `@AppStorage`, which resolves
    /// against the process's default store, so the app must pass the domain its own preferences
    /// live in — production passes `AppStartupDependencies.defaults`, which is `UserDefaults`
    /// `.standard`. Passing a domain that holds different provider settings makes the form migrate
    /// one domain's keys while displaying another's configuration.
    init(networkManager: TTSNetworkManager,
         audioPlayer: AudioPlayerManager,
         secretStore: SecretStoring = KeychainSecretStore(),
         defaults: UserDefaults,
         aboutAction: AboutAction = AboutAction()) {
        self.networkManager = networkManager
        self.audioPlayer = audioPlayer
        self.aboutAction = aboutAction
        _secretState = StateObject(wrappedValue: SettingsSecretState(secretStore: secretStore, defaults: defaults))
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
            VStack(spacing: 0) {
                List(selection: $ttsProvider) {
                    Text("OpenAI").tag("OpenAI")
                    Text("Gemini").tag("Gemini")
                    Text("Custom").tag("Custom")
                }
                .listStyle(.sidebar)
                .onChange(of: ttsProvider) { newValue in
                    providerDidChange(to: newValue)
                }

                aboutButton
            }
            .frame(width: 170)

            Divider()

            Form {
                if let secretStoreError = secretState.errorMessage {
                    Text(secretStoreError)
                        .foregroundStyle(.red)
                }

                legacyKeyMigrationRecovery

                if selectedProvider == .openAI {
                    openAISettings
                } else if selectedProvider == .gemini {
                    geminiSettings
                } else {
                    customSettings
                }
            }
            .padding(20)
        }
        // The content grows with the window instead of floating at a fixed size, so a resized
        // or restored window cannot strand blank margins around it; the scene's default size
        // still opens it at the former fixed size.
        .frame(minWidth: 600, minHeight: 350)
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
                                        networkManager: networkManager,
                                        provider: selectedProvider.settingsValue,
                                        onSync: syncSettings)

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
                                        networkManager: networkManager,
                                        provider: selectedProvider.settingsValue,
                                        onSync: syncSettings)

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
                                        networkManager: networkManager,
                                        provider: selectedProvider.settingsValue,
                                        onSync: syncSettings)

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

    /// The recovery offered while a saved key is still waiting to be moved into the Keychain.
    ///
    /// Migration otherwise reruns only when a new `TTSNetworkManager` is created, so the guidance's
    /// "try again" would mean relaunching the app. It is rendered for every pending provider,
    /// because one that keeps failing must stay visible after another one succeeds.
    @ViewBuilder
    private var legacyKeyMigrationRecovery: some View {
        if !secretState.pendingMigrationProviders.isEmpty {
            Section {
                ForEach(secretState.pendingMigrationProviders, id: \.self) { provider in
                    Text(APIKeyMigrationService.failureMessage(for: provider))
                        .foregroundStyle(.red)
                }

                HStack {
                    SettingsActionButton(title: "Retry Securing Saved Keys", action: retrySecuringSavedKeys)
                        .fixedSize()

                    Spacer()
                }
            }
        }
    }

    private var testVoiceButton: some View {
        HStack {
            // An `NSViewRepresentable` is greedy by default, so `.fixedSize()` keeps this control
            // hugging its title the way `.buttonStyle(.bordered)` laid it out.
            SettingsActionButton(title: "Test Voice", action: runTestVoice)
                .fixedSize()

            Spacer()
        }
        .padding(.top)
    }

    /// The sidebar footer presenting the About panel. About is app-level rather than
    /// provider-level, so it sits beside the provider list instead of under the active
    /// provider's form. The representable is greedy, so the button takes the sidebar's width
    /// and its title stays clear of the sidebar's edges.
    private var aboutButton: some View {
        VStack(spacing: 0) {
            Divider()

            SettingsActionButton(title: "About Clipboard TTS", action: showAbout)
                .padding(8)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    func showAbout() {
        aboutAction.showAbout()
    }

    /// Retries the legacy-key migration at the user's request and republishes what it changed.
    ///
    /// The manager's future-request credentials are refreshed without re-fetching provider
    /// metadata or rebuilding the audio graph, because securing a stored key changes neither the
    /// selected endpoint nor the audio format.
    func retrySecuringSavedKeys() {
        secretState.retryLegacyKeyMigration()
        applyCredentialsToFutureRequests()
        refreshMigrationWarning()
    }

    /// Points the menu bar's migration warning at whatever is still unsecured, or withdraws it.
    ///
    /// Every path that can resolve a pending provider calls this, because saving or clearing a key
    /// retires that provider's plaintext copy just as securing it does.
    private func refreshMigrationWarning() {
        networkManager.updateMigrationFailureWarning(for: secretState.pendingMigrationProviders.first)
    }

    func runTestVoice() {
        normalizeSelectedProvider()
        guard syncAudioFormat() else { return }
        applyCredentialsToFutureRequests()
        networkManager.stopStreaming()
        audioPlayer.stop()
        let gen = audioPlayer.startNewStream()
        networkManager.streamTTS(text: "Hello! This is a test of your text to speech configuration.") { [audioPlayer] data in
            audioPlayer.scheduleAudio(data: data, streamGeneration: gen)
        }
    }

    func providerDidChange(to newValue: String) {
        syncSettings()
    }

    func syncSettings() {
        normalizeSelectedProvider()
        applyCredentialsToFutureRequests()
        _ = syncAudioFormat()
        fetchMetadata()
    }

    /// Hands the form's current provider configuration to requests that start after this call.
    private func applyCredentialsToFutureRequests() {
        networkManager.updateSettings(
            baseURL: currentBaseURL,
            apiKey: currentAPIKey,
            model: currentModel,
            voice: currentVoice,
            selectedProvider: selectedProvider.settingsValue
        )
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
                refreshMigrationWarning()
                syncSettings()
            }
        )
    }
}
