import XCTest
@testable import ClipboardTTSApp

/// Google's documented Gemini TTS voices, transcribed independently of the production catalog.
///
/// Read from the "Voice options" table of the official speech-generation guide
/// (https://ai.google.dev/gemini-api/docs/speech-generation) on 2026-08-16. Tests compare the
/// app's catalog and the Settings pickers against this transcription, so an assertion measures
/// agreement with the provider contract rather than agreement of the app with itself.
let documentedGeminiTTSVoices = [
    "Zephyr", "Puck", "Charon", "Kore", "Fenrir", "Leda", "Orus", "Aoede", "Callirrhoe",
    "Autonoe", "Enceladus", "Iapetus", "Umbriel", "Algieba", "Despina", "Erinome", "Algenib",
    "Rasalgethi", "Laomedeia", "Achernar", "Alnilam", "Schedar", "Gacrux", "Pulcherrima",
    "Achird", "Zubenelgenubi", "Vindemiatrix", "Sadachbia", "Sadaltager", "Sulafat"
]

/// What each provider documents about its own models and voices.
///
/// This suite owns the contract — which sets are offered, and the difference between a provider that
/// documents an empty catalog and one that documents none. Which catalog a Settings form offers is a
/// separate property, owned by `SettingsVoiceMetadataTests`: those hosted tests fail if a form
/// offers another provider's catalog, or offers any catalog for a Custom endpoint.
final class ProviderMetadataCatalogTests: XCTestCase {
    /// The ten built-in voices the Realtime API names when it rejects a voice, verified 2026-11-02.
    /// Transcribed here rather than read from the production constant, so an assertion measures
    /// agreement with that contract rather than the app agreeing with itself.
    private let documentedRealtimeOpenAIVoices = [
        "alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse", "marin", "cedar"
    ]

    func testOpenAIOffersExactlyTheRealtimeVoicesInTheAPIsOrder() {
        // WHY: The Realtime API rejects the speech-only `fable`, `nova`, and `onyx`, so offering them
        // would suggest a choice whose request the provider refuses, and leaving any listed voice out
        // would make it unreachable in the only place a voice is chosen.
        XCTAssertEqual(ProviderMetadataCatalog.voices(for: .openAI), documentedRealtimeOpenAIVoices)
    }

    func testGeminiOffersTheDocumentedCatalogInTheGuidesOrder() {
        // WHY: Gemini publishes no voice discovery, so exact agreement with the documented table —
        // order included — is the only check that catches a catalog that drifted in either direction.
        XCTAssertEqual(ProviderMetadataCatalog.voices(for: .gemini), documentedGeminiTTSVoices)
    }

    func testACustomEndpointDocumentsNoVoiceCatalogRatherThanAnEmptyOne() {
        // WHY: A Custom deployment has no discovery contract, so the app knows nothing about its
        // voices. Answering with an empty list would state that it offers none; answering with nothing
        // is what leaves its form without a picker and the user's configured voice alone.
        XCTAssertNil(ProviderMetadataCatalog.voices(for: .custom))
    }

    func testOpenAIAndGeminiOfferFixedModelCatalogsAndCustomOffersNone() {
        // WHY: The app sends no model-discovery request, so these catalogs are the only model
        // suggestions Settings offers. Gemini documents no discovery endpoint, and OpenAI's list also
        // names Realtime models that cannot speak, so the supported speech models are the app's own
        // answer for both, the default first. A Custom deployment documents nothing, so `nil` leaves
        // its configured model alone.
        XCTAssertEqual(
            ProviderMetadataCatalog.models(for: .openAI),
            ["gpt-realtime-2.1-mini", "gpt-realtime-2.1"],
            "Mini must lead as the default, with the full model offered beside it."
        )
        XCTAssertEqual(
            ProviderMetadataCatalog.models(for: .gemini),
            ["gemini-3.8-flash-lite-tts", "gemini-3.8-flash-tts"],
            "Flash-Lite must lead as the default, with Flash offered beside it."
        )
        XCTAssertNil(ProviderMetadataCatalog.models(for: .custom))
    }
}
