import Foundation

extension TTSNetworkManager.RequestSettings {
    /// OpenAI's fixed speech endpoint, which a Custom provider also falls back to.
    private static let openAISpeechEndpoint = "https://api.openai.com/v1/audio/speech"
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
                baseURL: openAISpeechEndpoint,
                apiKey: apiKey,
                model: defaults.string(forKey: SettingsKeys.openAIModel) ?? "tts-1",
                voice: defaults.string(forKey: SettingsKeys.openAIVoice) ?? "alloy",
                provider: provider
            )
        case .gemini:
            return Self(
                baseURL: geminiAPIRoot,
                apiKey: apiKey,
                model: defaults.string(forKey: SettingsKeys.geminiModel) ?? "gemini-3.1-flash-tts-preview",
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
}
