import Foundation

extension TTSNetworkManager.RequestSettings {
    /// OpenAI's speech endpoint, which a Custom provider falls back to before one is typed. OpenAI
    /// itself now speaks through `OpenAIRealtimeSpeech.endpoint`.
    private static let openAISpeechEndpoint = "https://api.openai.com/v1/audio/speech"
    /// The OpenAI voice a retired speech-only voice is replaced with, which is also the default.
    static let defaultOpenAIVoice = "alloy"
    /// The speech-only OpenAI voices the Realtime API rejects.
    private static let retiredOpenAIVoices: Set = ["fable", "nova", "onyx"]
    /// Gemini's fixed API root. Its speech path is built per request from the configured model,
    /// so what is stored here is the root rather than a complete endpoint.
    private static let geminiAPIRoot = "https://generativelanguage.googleapis.com/v1beta"

    /// The configuration a launch resolves for `provider` from `defaults`, carrying the key that
    /// startup's secret path produced.
    ///
    /// Pure, and deliberately separate from the manager: which endpoint, model, and voice a provider
    /// starts with is decided by what is stored, not by the state of any request, so a launch's
    /// configuration can be stated and checked without building a manager or a session. The key is
    /// passed in rather than read here, because migrating and reading a saved key is
    /// `APIKeyStartupState`'s decision and reading the store a second time is what that type exists
    /// to avoid.
    ///
    /// Only a Custom deployment's endpoint is configurable; OpenAI's and Gemini's are fixed, because
    /// the app sends their speech requests to one documented address. A Custom provider selected
    /// before an endpoint was typed falls back to OpenAI's address rather than to nothing, so the
    /// configuration always names a real HTTPS endpoint, and an empty Custom model or voice is what
    /// the request path refuses by name.
    static func resolved(provider: APIKeyProvider,
                         apiKey: String,
                         defaults: UserDefaults) -> Self {
        switch provider {
        case .openAI:
            return Self(
                baseURL: OpenAIRealtimeSpeech.endpoint,
                apiKey: apiKey,
                model: defaults.string(forKey: SettingsKeys.openAIModel) ?? "gpt-realtime-2.1-mini",
                voice: defaults.string(forKey: SettingsKeys.openAIVoice) ?? defaultOpenAIVoice,
                provider: provider
            )
        case .gemini:
            return Self(
                baseURL: geminiAPIRoot,
                apiKey: apiKey,
                model: defaults.string(forKey: SettingsKeys.geminiModel) ?? "gemini-3.8-flash-lite-tts",
                voice: defaults.string(forKey: SettingsKeys.geminiVoice) ?? "Aoede",
                provider: provider
            )
        case .custom:
            return Self(
                baseURL: defaults.string(forKey: SettingsKeys.apiBaseURL) ?? openAISpeechEndpoint,
                apiKey: apiKey,
                model: defaults.string(forKey: SettingsKeys.customModel) ?? "",
                voice: defaults.string(forKey: SettingsKeys.customVoice) ?? "",
                provider: provider
            )
        }
    }

    /// Rewrites a saved OpenAI model or voice that only the retired speech API accepted.
    ///
    /// OpenAI speech now runs on the Realtime API, which rejects every `tts` speech model and the
    /// speech-only voices outright, so a saved one could only fail. A saved speech model becomes the
    /// default Realtime model and a retired voice becomes the default voice, so speech keeps working
    /// after the update without the user visiting Settings. Any other saved value is kept, including
    /// a model the catalog does not list, because the user may have typed one deliberately. Runs at
    /// manager construction, before anything reads either setting.
    static func migrateRetiredOpenAISpeechSettings(in defaults: UserDefaults) {
        if let model = defaults.string(forKey: SettingsKeys.openAIModel), model.contains("tts") {
            defaults.set(ProviderMetadataCatalog.openAIModels[0], forKey: SettingsKeys.openAIModel)
        }
        if let voice = defaults.string(forKey: SettingsKeys.openAIVoice), retiredOpenAIVoices.contains(voice) {
            defaults.set(defaultOpenAIVoice, forKey: SettingsKeys.openAIVoice)
        }
    }
}
