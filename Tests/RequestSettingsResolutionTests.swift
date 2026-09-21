import XCTest
@testable import ClipboardTTSApp

/// The configuration a launch resolves for one provider from stored preferences.
///
/// This suite owns what each provider starts with and where each value comes from. That a manager
/// then serves that configuration to requests, and replaces it when Settings edits it, belongs to
/// the startup and manager suites, which drive the real composition.
final class RequestSettingsResolutionTests: XCTestCase {
    func testEachProviderStartsFromItsOwnStoredModelAndVoice() {
        // WHY: All three providers keep their model and voice under separate keys, so a launch must
        // read the selected provider's pair. Reading another provider's would speak a configuration
        // the user last used somewhere else, with the endpoint and key of the one they selected.
        let defaults = makeOwnedDefaults([
            SettingsKeys.openAIModel: "stored-openai-model",
            SettingsKeys.openAIVoice: "stored-openai-voice",
            SettingsKeys.geminiModel: "stored-gemini-model",
            SettingsKeys.geminiVoice: "stored-gemini-voice",
            SettingsKeys.apiBaseURL: "https://stored.custom/v1/audio/speech",
            SettingsKeys.customModel: "stored-custom-model",
            SettingsKeys.customVoice: "stored-custom-voice"
        ])

        let openAI = TTSNetworkManager.RequestSettings.resolved(
            provider: .openAI, apiKey: "openai-key", defaults: defaults
        )
        XCTAssertEqual(openAI.baseURL, "https://api.openai.com/v1/audio/speech")
        XCTAssertEqual(openAI.model, "stored-openai-model")
        XCTAssertEqual(openAI.voice, "stored-openai-voice")
        XCTAssertEqual(openAI.provider, .openAI)

        let gemini = TTSNetworkManager.RequestSettings.resolved(
            provider: .gemini, apiKey: "gemini-key", defaults: defaults
        )
        XCTAssertEqual(gemini.baseURL, "https://generativelanguage.googleapis.com/v1beta")
        XCTAssertEqual(gemini.model, "stored-gemini-model")
        XCTAssertEqual(gemini.voice, "stored-gemini-voice")
        XCTAssertEqual(gemini.provider, .gemini)

        let custom = TTSNetworkManager.RequestSettings.resolved(
            provider: .custom, apiKey: "custom-key", defaults: defaults
        )
        XCTAssertEqual(custom.baseURL, "https://stored.custom/v1/audio/speech")
        XCTAssertEqual(custom.model, "stored-custom-model")
        XCTAssertEqual(custom.voice, "stored-custom-voice")
        XCTAssertEqual(custom.provider, .custom)
    }

    func testOnlyACustomDeploymentsEndpointComesFromStorage() {
        // WHY: OpenAI and Gemini each publish one documented address, so a stored endpoint must not
        // redirect them: a value left behind by a Custom deployment would otherwise send the
        // selected provider's key somewhere it was never issued for.
        let defaults = makeOwnedDefaults([SettingsKeys.apiBaseURL: "https://elsewhere.example/v1/audio/speech"])

        XCTAssertEqual(
            TTSNetworkManager.RequestSettings.resolved(provider: .openAI, apiKey: "k", defaults: defaults).baseURL,
            "https://api.openai.com/v1/audio/speech"
        )
        XCTAssertEqual(
            TTSNetworkManager.RequestSettings.resolved(provider: .gemini, apiKey: "k", defaults: defaults).baseURL,
            "https://generativelanguage.googleapis.com/v1beta"
        )
        XCTAssertEqual(
            TTSNetworkManager.RequestSettings.resolved(provider: .custom, apiKey: "k", defaults: defaults).baseURL,
            "https://elsewhere.example/v1/audio/speech"
        )
    }

    func testAFirstLaunchFallsBackToWorkingFixedProviderDefaultsAndAnEmptyCustomConfiguration() {
        // WHY: Nothing is stored before Settings is first opened. OpenAI and Gemini must still be
        // usable, so each falls back to a model and voice its own endpoint accepts. Custom cannot be
        // guessed, so its model and voice stay empty for the request path to refuse by name, while
        // its endpoint falls back to a real HTTPS address rather than to a URL nothing can build.
        let defaults = makeOwnedDefaults()

        let openAI = TTSNetworkManager.RequestSettings.resolved(provider: .openAI, apiKey: "", defaults: defaults)
        XCTAssertEqual(openAI.model, "tts-1")
        XCTAssertEqual(openAI.voice, "alloy")

        let gemini = TTSNetworkManager.RequestSettings.resolved(provider: .gemini, apiKey: "", defaults: defaults)
        XCTAssertEqual(gemini.model, "gemini-3.1-flash-tts-preview")
        XCTAssertEqual(gemini.voice, "Aoede")

        let custom = TTSNetworkManager.RequestSettings.resolved(provider: .custom, apiKey: "", defaults: defaults)
        XCTAssertEqual(custom.baseURL, "https://api.openai.com/v1/audio/speech")
        XCTAssertEqual(custom.model, "")
        XCTAssertEqual(custom.voice, "")
    }

    func testTheKeyIsTheOneSuppliedRatherThanOneReadFromPreferences() {
        // WHY: Migrating and reading a saved key is `APIKeyStartupState`'s decision, and reading the
        // store a second time is what that type exists to avoid. A resolver that read a key here
        // would also read one from plaintext preferences a migration had already secured.
        let defaults = makeOwnedDefaults([
            SettingsKeys.legacyOpenAIAPIKey: "plaintext-key-that-must-not-be-used",
            SettingsKeys.legacyCustomAPIKey: "plaintext-key-that-must-not-be-used"
        ])

        for provider in APIKeyProvider.allCases {
            let settings = TTSNetworkManager.RequestSettings.resolved(
                provider: provider, apiKey: "supplied-key", defaults: defaults
            )
            XCTAssertEqual(settings.apiKey, "supplied-key", "\(provider) must carry the supplied key.")
        }
        XCTAssertEqual(
            defaults.string(forKey: SettingsKeys.legacyOpenAIAPIKey),
            "plaintext-key-that-must-not-be-used",
            "Resolving a configuration must not migrate or consume a stored key."
        )
    }
}
