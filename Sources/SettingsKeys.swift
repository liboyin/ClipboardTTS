import Foundation

/// Names of values stored in `UserDefaults` by the app.
///
/// API-key names remain solely for one-time legacy migration and test isolation. Keychain account
/// identifiers intentionally do not belong in this namespace because they identify a different
/// storage system.
enum SettingsKeys {
    static let ttsProvider = "ttsProvider"
    static let apiBaseURL = "apiBaseURL"
    static let openAIModel = "openaiModel"
    static let openAIVoice = "openaiVoice"
    static let geminiModel = "geminiModel"
    static let geminiVoice = "geminiVoice"
    static let customModel = "customModel"
    static let customVoice = "customVoice"
    static let customSampleRate = "customSampleRate"

    static let legacyOpenAIAPIKey = "apiKey"
    static let legacyGeminiAPIKey = "geminiAPIKey"
    static let legacyCustomAPIKey = "customAPIKey"

    /// Every preference key the app reads or writes, including legacy migration source keys.
    static let allUserDefaultsKeys = [
        ttsProvider,
        apiBaseURL,
        openAIModel,
        openAIVoice,
        geminiModel,
        geminiVoice,
        customModel,
        customVoice,
        customSampleRate,
        legacyOpenAIAPIKey,
        legacyGeminiAPIKey,
        legacyCustomAPIKey
    ]
}
