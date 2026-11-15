import Foundation

/// The settings a fresh install starts with, before the user has stored any.
///
/// This is the one owner of those values: launch resolution, the Settings form's fallbacks, and the
/// retired-speech migration all read them here, so the form and the first request cannot disagree
/// about a value nobody has typed. Each provider's catalog lists its default model first by building
/// on these names rather than the other way round, so reordering a catalog cannot move a default.
enum ProviderDefaults {
    /// The provider a launch and the Settings sidebar select when none is stored.
    static let provider = APIKeyProvider.openAI
    /// OpenAI's default Realtime model, named by OpenAI as the replacement for `tts-1`.
    static let openAIModel = "gpt-realtime-2.1-mini"
    /// OpenAI's default voice, which also replaces a retired speech-only voice.
    static let openAIVoice = "alloy"
    /// Gemini's default TTS model, Google's replacement for `gemini-3.1-flash-tts-preview`.
    static let geminiModel = "gemini-3.8-flash-lite-tts"
    /// Gemini's default voice.
    static let geminiVoice = "Aoede"
    /// Custom's model before one is typed: empty, because a Custom deployment's names cannot be
    /// guessed, so the request path refuses it by name instead.
    static let customModel = ""
    /// Custom's voice before one is typed, empty for the same reason as its model.
    static let customVoice = ""
    /// The native Kokoro server's speech URL from README, which a Custom provider falls back to
    /// before one is typed (D34). Plain HTTP is allowed because the host is a loopback literal.
    static let customEndpoint = "http://127.0.0.1:8881/v1/audio/speech"
}

/// The model and voice choices each provider documents, which Settings offers as suggestions.
///
/// A catalog states what a provider publishes about itself, which is a property of that provider
/// rather than of the app's request state, so it is pure and needs no manager, session, or
/// main-queue turn: a drifted catalog is a failing equality. Each Settings form looks up the
/// catalog of the provider it renders (`ModelVoiceConfigurationView`), so no list is ever held for
/// one provider while another's form is on screen (D38).
enum ProviderMetadataCatalog {
    /// The OpenAI Realtime models the app supports and offers as suggestions, the default first.
    ///
    /// Both speak through the Realtime WebSocket API, verified live 2026-11-02. Mini, the default
    /// `ProviderDefaults` names, is OpenAI's named replacement for the retiring `tts-1` speech models.
    private static let openAIModels = [ProviderDefaults.openAIModel, "gpt-realtime-2.1"]
    /// The built-in Realtime voices, in the order the Realtime API lists them.
    ///
    /// Transcribed from the supported values the API names when it rejects a voice, verified
    /// 2026-11-02; it rejects the speech-only `fable`, `nova`, and `onyx` outright.
    private static let openAIVoices = [
        "alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse", "marin", "cedar"
    ]
    /// The complete Gemini TTS voice catalog, in the order Google's guide lists it.
    ///
    /// Gemini documents no voice-discovery endpoint, so this list is the app's only source of
    /// truth for the Settings suggestions, which are the only place a voice is chosen. Transcribed
    /// from the "Voice options" table of https://ai.google.dev/gemini-api/docs/speech-generation,
    /// verified 2026-11-01, when the guide gave one set for every model it lists; it must be
    /// re-verified against that guide whenever Google changes the documented set.
    private static let geminiVoices = [
        "Zephyr", "Puck", "Charon", "Kore", "Fenrir", "Leda", "Orus", "Aoede", "Callirrhoe",
        "Autonoe", "Enceladus", "Iapetus", "Umbriel", "Algieba", "Despina", "Erinome", "Algenib",
        "Rasalgethi", "Laomedeia", "Achernar", "Alnilam", "Schedar", "Gacrux", "Pulcherrima",
        "Achird", "Zubenelgenubi", "Vindemiatrix", "Sadachbia", "Sadaltager", "Sulafat"
    ]
    /// The Gemini TTS models the app supports and offers as suggestions, the default first.
    ///
    /// Both stream from `:streamGenerateContent`, verified live 2026-11-01. Flash-Lite is Google's
    /// replacement for `gemini-3.1-flash-tts-preview` and the default `ProviderDefaults` names;
    /// Flash covers languages Flash-Lite does not.
    private static let geminiModels = [ProviderDefaults.geminiModel, "gemini-3.8-flash-tts"]

    /// The models `provider` documents, or `nil` for a provider that documents none.
    ///
    /// OpenAI's and Gemini's supported speech models are the app's own answer and need no request:
    /// Gemini publishes no model-discovery endpoint, and OpenAI's model list also names Realtime
    /// models that cannot speak, such as `gpt-realtime-whisper`. A Custom deployment is not asked,
    /// so `nil` leaves its model whatever Settings has configured, as for its voice.
    static func models(for provider: APIKeyProvider) -> [String]? {
        switch provider {
        case .openAI:
            return openAIModels
        case .gemini:
            return geminiModels
        case .custom:
            return nil
        }
    }

    /// The voices `provider` documents, or `nil` for a provider that documents none.
    ///
    /// `nil` is not an empty catalog. A Custom endpoint has no discovery contract and no documented
    /// set, so there is nothing to offer, whereas an empty list would state that the provider offers
    /// no voices at all. Every supported model of a provider offers the same voices, so the catalog
    /// does not depend on the configured model.
    static func voices(for provider: APIKeyProvider) -> [String]? {
        switch provider {
        case .openAI:
            return openAIVoices
        case .gemini:
            return geminiVoices
        case .custom:
            return nil
        }
    }
}
