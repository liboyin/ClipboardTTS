import Foundation

/// Names of values stored in `UserDefaults` by the app.
///
/// API-key names remain here only as legacy migration and test-isolation keys until Task 8
/// moves their values to the Keychain. Keychain account identifiers intentionally do not belong
/// in this namespace because they identify a different storage system.
enum SettingsKeys {
    static let ttsProvider = "ttsProvider"
    static let apiBaseURL = "apiBaseURL"
    static let openAIModel = "openaiModel"
    static let openAIVoice = "openaiVoice"
    static let geminiModel = "geminiModel"
    static let geminiVoice = "geminiVoice"

    static let legacyOpenAIAPIKey = "apiKey"
    static let legacyGeminiAPIKey = "geminiAPIKey"
    static let legacyCustomAPIKey = "customAPIKey"

    /// Every key the app currently reads from or writes to `UserDefaults`.
    static let allUserDefaultsKeys = [
        ttsProvider,
        apiBaseURL,
        openAIModel,
        openAIVoice,
        geminiModel,
        geminiVoice,
        legacyOpenAIAPIKey,
        legacyGeminiAPIKey,
        legacyCustomAPIKey
    ]
}
