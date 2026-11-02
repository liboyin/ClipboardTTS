import Foundation

/// The model and voice choices each provider documents, independent of when they may be offered.
///
/// A catalog states what a provider publishes about itself, which is a property of that provider
/// rather than of the app's request state. Whether an answer may still be shown belongs to
/// `TTSNetworkManager+Metadata`, which carries every publication on a token naming the provider that
/// earned it. Keeping the two apart is what lets the documented sets be stated and checked without a
/// manager, a session, or a main-queue turn: a drifted catalog is then a failing equality rather
/// than a provider contract read out of an asynchronous publication.
enum ProviderMetadataCatalog {
    /// The OpenAI Realtime models the app supports and offers as suggestions, the default first.
    ///
    /// Both speak through the Realtime WebSocket API, verified live 2026-11-02. Mini is OpenAI's named
    /// replacement for the retiring `tts-1` speech models. The default is repeated as each settings
    /// fallback and as the target of `RequestSettings.migrateRetiredOpenAISpeechSettings`, so change
    /// those with this order.
    static let openAIModels = ["gpt-realtime-2.1-mini", "gpt-realtime-2.1"]
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
    /// replacement for `gemini-3.1-flash-tts-preview`; Flash covers languages Flash-Lite does not.
    /// The default is repeated as each settings fallback, so change those with this order.
    private static let geminiModels = ["gemini-3.8-flash-lite-tts", "gemini-3.8-flash-tts"]

    /// The models `provider` documents itself, or `nil` when only its endpoint can answer.
    ///
    /// OpenAI's and Gemini's supported speech models are the app's own answer and need no request:
    /// Gemini publishes no model-discovery endpoint, and OpenAI's model list also names Realtime
    /// models that cannot speak, such as `gpt-realtime-whisper`. A Custom deployment answers for
    /// itself, which is what `nil` says here; `OpenAIModelDiscovery` owns asking it.
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
    /// set, so there is nothing to offer and nothing to publish, whereas an empty list would state
    /// that the provider offers no voices at all. Every supported model of a provider offers the same
    /// voices, so the catalog does not depend on the configured model.
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
