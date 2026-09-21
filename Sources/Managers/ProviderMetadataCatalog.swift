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
    private static let legacyOpenAIVoices = [
        "alloy", "ash", "coral", "echo", "fable", "onyx", "nova", "sage", "shimmer"
    ]
    private static let currentOpenAIVoices = [
        "alloy", "ash", "ballad", "coral", "echo", "fable", "onyx", "nova", "sage",
        "shimmer", "verse", "marin", "cedar"
    ]
    /// The complete Gemini TTS voice catalog, in the order Google's guide lists it.
    ///
    /// Gemini documents no voice-discovery endpoint, so this list is the app's only source of
    /// truth for the Settings suggestions, which are the only place a voice is chosen. Transcribed
    /// from the "Voice options" table of https://ai.google.dev/gemini-api/docs/speech-generation,
    /// verified 2026-08-20; it must be re-verified against that guide whenever Google changes the
    /// documented set.
    private static let geminiVoices = [
        "Zephyr", "Puck", "Charon", "Kore", "Fenrir", "Leda", "Orus", "Aoede", "Callirrhoe",
        "Autonoe", "Enceladus", "Iapetus", "Umbriel", "Algieba", "Despina", "Erinome", "Algenib",
        "Rasalgethi", "Laomedeia", "Achernar", "Alnilam", "Schedar", "Gacrux", "Pulcherrima",
        "Achird", "Zubenelgenubi", "Vindemiatrix", "Sadachbia", "Sadaltager", "Sulafat"
    ]
    /// The one Gemini TTS model the app supports, which is also the model it offers as a suggestion.
    private static let geminiModels = ["gemini-3.1-flash-tts-preview"]

    /// The models `provider` documents itself, or `nil` when only its endpoint can answer.
    ///
    /// Gemini publishes no model-discovery endpoint, so the supported TTS model is the app's own
    /// answer and needs no request. An OpenAI-compatible or Custom deployment answers for itself,
    /// which is what `nil` says here; `OpenAIModelDiscovery` owns asking it.
    static func models(for provider: APIKeyProvider) -> [String]? {
        switch provider {
        case .gemini:
            return geminiModels
        case .openAI, .custom:
            return nil
        }
    }

    /// The voices `provider` documents for `model`, or `nil` for a provider that documents none.
    ///
    /// `nil` is not an empty catalog. A Custom endpoint has no discovery contract and no documented
    /// set, so there is nothing to offer and nothing to publish, whereas an empty list would state
    /// that the provider offers no voices at all. Only OpenAI's catalog depends on `model`; the
    /// others ignore it, so a caller may pass the configured model without deciding that first.
    static func voices(for provider: APIKeyProvider, model: String) -> [String]? {
        switch provider {
        case .openAI:
            return openAIVoices(for: model)
        case .gemini:
            return geminiVoices
        case .custom:
            return nil
        }
    }

    /// OpenAI's voices for one model: the two legacy TTS models offer fewer than the current ones.
    private static func openAIVoices(for model: String) -> [String] {
        switch model {
        case "tts-1", "tts-1-hd":
            return legacyOpenAIVoices
        default:
            return currentOpenAIVoices
        }
    }
}
