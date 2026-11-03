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
        XCTAssertEqual(openAI.baseURL, "wss://api.openai.com/v1/realtime")
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
            "wss://api.openai.com/v1/realtime"
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
        // its endpoint falls back to the native Kokoro server README documents (D34), which keeps
        // the Custom key on this Mac rather than sending it to a provider the user never chose.
        let defaults = makeOwnedDefaults()

        let openAI = TTSNetworkManager.RequestSettings.resolved(provider: .openAI, apiKey: "", defaults: defaults)
        XCTAssertEqual(openAI.baseURL, "wss://api.openai.com/v1/realtime")
        XCTAssertEqual(openAI.model, "gpt-realtime-2.1-mini")
        XCTAssertEqual(openAI.voice, "alloy")

        let gemini = TTSNetworkManager.RequestSettings.resolved(provider: .gemini, apiKey: "", defaults: defaults)
        XCTAssertEqual(gemini.model, "gemini-3.8-flash-lite-tts")
        XCTAssertEqual(gemini.voice, "Aoede")

        let custom = TTSNetworkManager.RequestSettings.resolved(provider: .custom, apiKey: "", defaults: defaults)
        XCTAssertEqual(custom.baseURL, "http://127.0.0.1:8881/v1/audio/speech")
        XCTAssertEqual(custom.model, "")
        XCTAssertEqual(custom.voice, "")
    }

    func testASavedSpeechModelOrRetiredVoiceIsRewrittenForTheRealtimeAPI() {
        // WHY: OpenAI speech now runs on the Realtime API, which rejects every `tts` speech model and
        // the speech-only voices outright. A user upgrading with either saved would otherwise find
        // speech failing until they visited Settings, so both are rewritten to working defaults.
        for (savedModel, savedVoice) in [("tts-1", "nova"), ("tts-1-hd", "fable"), ("gpt-4o-mini-tts", "onyx")] {
            let defaults = makeOwnedDefaults([SettingsKeys.openAIModel: savedModel, SettingsKeys.openAIVoice: savedVoice])

            TTSNetworkManager.RequestSettings.migrateRetiredOpenAISpeechSettings(in: defaults)

            XCTAssertEqual(defaults.string(forKey: SettingsKeys.openAIModel), "gpt-realtime-2.1-mini", savedModel)
            XCTAssertEqual(defaults.string(forKey: SettingsKeys.openAIVoice), "alloy", savedVoice)
        }
    }

    func testTheRealtimeMigrationKeepsEveryValueTheRealtimeAPICanUse() {
        // WHY: The rewrite exists only for values that can no longer work. A supported model, a model
        // the user typed deliberately, a voice both APIs accept, and settings never saved must all
        // survive it, or every launch would undo a choice the user made.
        let defaults = makeOwnedDefaults([SettingsKeys.openAIModel: "gpt-realtime-2.1", SettingsKeys.openAIVoice: "marin"])
        TTSNetworkManager.RequestSettings.migrateRetiredOpenAISpeechSettings(in: defaults)
        XCTAssertEqual(defaults.string(forKey: SettingsKeys.openAIModel), "gpt-realtime-2.1")
        XCTAssertEqual(defaults.string(forKey: SettingsKeys.openAIVoice), "marin")

        let typed = makeOwnedDefaults([SettingsKeys.openAIModel: "gpt-realtime-future", SettingsKeys.openAIVoice: "alloy"])
        TTSNetworkManager.RequestSettings.migrateRetiredOpenAISpeechSettings(in: typed)
        XCTAssertEqual(typed.string(forKey: SettingsKeys.openAIModel), "gpt-realtime-future")
        XCTAssertEqual(typed.string(forKey: SettingsKeys.openAIVoice), "alloy")

        let unsaved = makeOwnedDefaults()
        TTSNetworkManager.RequestSettings.migrateRetiredOpenAISpeechSettings(in: unsaved)
        XCTAssertNil(unsaved.object(forKey: SettingsKeys.openAIModel))
        XCTAssertNil(unsaved.object(forKey: SettingsKeys.openAIVoice))
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
