import XCTest
@testable import ClipboardTTSApp

/// What each provider documents about its own models and voices.
///
/// This suite owns the contract — which sets are offered, and the difference between a provider that
/// documents an empty catalog and one that documents none. How a catalog reaches the UI is a separate
/// property, owned by `TTSNetworkManagerMetadataProviderTests`: that suite drives the guarded
/// publication path and is what fails if the manager stops passing the configured model, tagging a
/// list with the provider that earned it, or refusing to publish for a provider with no catalog.
final class ProviderMetadataCatalogTests: XCTestCase {
    /// OpenAI's two legacy TTS models and the nine voices README records for them from the official
    /// Text-to-Speech guide. Transcribed here rather than read from the production constant, so an
    /// assertion measures agreement with that contract rather than the app agreeing with itself.
    /// Re-verifying the guide itself is a provider-contract change, not part of this suite.
    private let documentedLegacyOpenAIVoices = [
        "alloy", "ash", "coral", "echo", "fable", "onyx", "nova", "sage", "shimmer"
    ]
    private let documentedCurrentOpenAIVoices = [
        "alloy", "ash", "ballad", "coral", "echo", "fable", "onyx", "nova", "sage",
        "shimmer", "verse", "marin", "cedar"
    ]

    func testTheTwoLegacyOpenAITTSModelsOfferTheSmallerDocumentedVoiceSet() {
        // WHY: `tts-1` and `tts-1-hd` reject the voices added for the later models, so offering the
        // full set under them would suggest a choice whose request the provider refuses.
        XCTAssertEqual(
            ProviderMetadataCatalog.voices(for: .openAI, model: "tts-1"),
            documentedLegacyOpenAIVoices
        )
        XCTAssertEqual(
            ProviderMetadataCatalog.voices(for: .openAI, model: "tts-1-hd"),
            documentedLegacyOpenAIVoices
        )
    }

    func testEveryOtherOpenAIModelOffersTheCurrentDocumentedVoiceSet() {
        // WHY: The legacy set is the exception, named model by model. Anything else — a current
        // model, a preview, or a name the app has never seen — has to reach the wider catalog, or a
        // voice the user's model accepts becomes unreachable in the only place a voice is chosen.
        for model in ["gpt-4o-mini-tts", "tts-2-unreleased", "", "TTS-1"] {
            XCTAssertEqual(
                ProviderMetadataCatalog.voices(for: .openAI, model: model),
                documentedCurrentOpenAIVoices,
                "\(model) is not one of the two legacy models and must offer the current catalog."
            )
        }
    }

    func testGeminiOffersTheDocumentedCatalogInTheGuidesOrderWhateverModelIsConfigured() {
        // WHY: Gemini publishes no voice discovery, so exact agreement with the documented table —
        // order included — is the only check that catches a catalog that drifted in either
        // direction. The model is passed for every provider, so this also pins that Gemini's answer
        // does not depend on it: a per-model Gemini catalog would be an invention.
        XCTAssertEqual(
            ProviderMetadataCatalog.voices(for: .gemini, model: "gemini-3.1-flash-tts-preview"),
            documentedGeminiTTSVoices
        )
        XCTAssertEqual(ProviderMetadataCatalog.voices(for: .gemini, model: "tts-1"), documentedGeminiTTSVoices)
        XCTAssertEqual(ProviderMetadataCatalog.voices(for: .gemini, model: ""), documentedGeminiTTSVoices)
    }

    func testACustomEndpointDocumentsNoVoiceCatalogRatherThanAnEmptyOne() {
        // WHY: A Custom deployment has no discovery contract, so the app knows nothing about its
        // voices. Answering with an empty list would state that it offers none, which would be
        // published as that provider's catalog; answering with nothing is what leaves the
        // suggestions unpublished and the user's configured voice alone.
        XCTAssertNil(ProviderMetadataCatalog.voices(for: .custom, model: "custom-model"))
        XCTAssertNil(ProviderMetadataCatalog.voices(for: .custom, model: "tts-1"))
    }

    func testGeminiIsTheOnlyProviderWhoseModelListNeedsNoDiscoveryRequest() {
        // WHY: Which providers the app can answer for itself decides which ones send a credential
        // to a discovery endpoint. Gemini documents no such endpoint, so its supported TTS model is
        // the app's own answer; OpenAI and Custom deployments answer for themselves, and claiming
        // otherwise here would replace a live model list with a guess.
        XCTAssertEqual(ProviderMetadataCatalog.models(for: .gemini), ["gemini-3.1-flash-tts-preview"])
        XCTAssertNil(ProviderMetadataCatalog.models(for: .openAI))
        XCTAssertNil(ProviderMetadataCatalog.models(for: .custom))
    }
}
