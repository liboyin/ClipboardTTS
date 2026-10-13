import Combine
import XCTest
@testable import ClipboardTTSApp

/// Google's documented Gemini TTS voices, transcribed independently of the production catalog.
///
/// Read from the "Voice options" table of the official speech-generation guide
/// (https://ai.google.dev/gemini-api/docs/speech-generation) on 2026-08-16. Tests compare the
/// app's published catalog against this transcription, so an assertion measures agreement with the
/// provider contract rather than agreement of the app with itself.
let documentedGeminiTTSVoices = [
    "Zephyr", "Puck", "Charon", "Kore", "Fenrir", "Leda", "Orus", "Aoede", "Callirrhoe",
    "Autonoe", "Enceladus", "Iapetus", "Umbriel", "Algieba", "Despina", "Erinome", "Algenib",
    "Rasalgethi", "Laomedeia", "Achernar", "Alnilam", "Schedar", "Gacrux", "Pulcherrima",
    "Achird", "Zubenelgenubi", "Vindemiatrix", "Sadachbia", "Sadaltager", "Sulafat"
]

final class TTSNetworkManagerMetadataProviderTests: MetadataTestCase {
    func testModelCatalogsReflectProviderCapabilities() {
        let manager = TestNetworkFactory.makeManager()

        // Provider-defined lists use the same guarded publication path as network-backed metadata.
        manager.updateSettings(
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            apiKey: "gemini-token",
            model: "gemini-3.1-flash-tts-preview",
            voice: "Aoede",
            selectedProvider: "Gemini"
        )
        let geminiModelsPublished = expectPublication(
            manager.$modelSuggestions,
            of: ProviderSuggestions(provider: .gemini, values: ["gemini-3.1-flash-tts-preview"]),
            "Gemini models published"
        )
        manager.fetchAvailableModels(
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            apiKey: "gemini-token",
            selectedProvider: "Gemini"
        )
        wait(for: [geminiModelsPublished], timeout: 1.0)

        MockURLProtocol.installRequestHandler { request in
            let data = Data("{ \"data\": [{\"id\": \"tts-1\"}, {\"id\": \"tts-1-hd\"}, {\"id\": \"gpt-4\"}] }".utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        manager.updateSettings(
            baseURL: "https://api.openai.com/v1/audio/speech",
            apiKey: "openai-token",
            model: "tts-1",
            voice: "alloy",
            selectedProvider: "OpenAI"
        )
        let openAIModelsPublished = expectPublication(
            manager.$modelSuggestions,
            of: ProviderSuggestions(provider: .openAI, values: ["tts-1", "tts-1-hd"]),
            "OpenAI models published"
        )
        manager.fetchAvailableModels(
            baseURL: "https://api.openai.com/v1/audio/speech",
            apiKey: "openai-token",
            selectedProvider: "OpenAI"
        )
        wait(for: [openAIModelsPublished], timeout: 1.0)
    }

    func testCustomGoogleLookingHostUsesOpenAICompatibleModelDiscovery() {
        // WHY: Model discovery must take its protocol from the selected identity just as speech
        // does. Otherwise a Custom host containing Google's hostname would get Gemini's static
        // list and no request for the catalog it actually exposes.
        let endpoint = "https://generativelanguage.googleapis.com.custom.example/v1/audio/speech"
        let manager = TestNetworkFactory.makeManager()
        manager.updateSettings(
            baseURL: endpoint,
            apiKey: "custom-token",
            model: "custom-model",
            voice: "custom-voice",
            selectedProvider: "Custom"
        )
        let discoveryRequested = expectation(description: "Custom model discovery is requested")
        MockURLProtocol.installRequestHandler { request in
            XCTAssertEqual(request.url?.absoluteString, "https://generativelanguage.googleapis.com.custom.example/v1/models")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer custom-token")
            XCTAssertNil(request.value(forHTTPHeaderField: "x-goog-api-key"))
            discoveryRequested.fulfill()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("{ \"data\": [{\"id\": \"custom-tts-model\"}] }".utf8))
        }
        let modelsPublished = expectation(description: "Custom discovered models are published")
        let observation = manager.$modelSuggestions.dropFirst().sink { suggestions in
            guard suggestions.values == ["custom-tts-model"] else { return }
            XCTAssertEqual(suggestions.provider, .custom)
            modelsPublished.fulfill()
        }
        defer { observation.cancel() }

        manager.fetchAvailableModels(baseURL: endpoint, apiKey: "custom-token", selectedProvider: "Custom")
        wait(for: [discoveryRequested, modelsPublished], timeout: 2.0)
    }

    func testVoiceCatalogsReflectProviderAndModelCapabilities() {
        let (manager, completions) = makeMetadataManager()
        let openAIVoices = ["alloy", "ash", "coral", "echo", "fable", "onyx", "nova", "sage", "shimmer"]
        manager.updateSettings(
            baseURL: "https://api.openai.com/v1/audio/speech",
            apiKey: "openai-token",
            model: "tts-1",
            voice: "alloy",
            selectedProvider: "OpenAI"
        )
        let openAIVoicesPublished = expectPublication(
            manager.$voiceSuggestions,
            of: ProviderSuggestions(provider: .openAI, values: openAIVoices),
            "OpenAI voices published"
        )
        manager.fetchAvailableVoices(
            baseURL: "https://api.openai.com/v1/audio/speech",
            selectedProvider: "OpenAI"
        )
        wait(for: [openAIVoicesPublished], timeout: 1.0)

        manager.updateSettings(
            baseURL: "https://api.openai.com/v1/audio/speech",
            apiKey: "openai-token",
            model: "tts-1-hd",
            voice: "alloy",
            selectedProvider: "OpenAI"
        )
        // The same list as before, so only a publication made after this point can satisfy it.
        let openAIHDVoicesPublished = expectPublication(
            manager.$voiceSuggestions,
            of: ProviderSuggestions(provider: .openAI, values: openAIVoices),
            "OpenAI HD voices published"
        )
        manager.fetchAvailableVoices(
            baseURL: "https://api.openai.com/v1/audio/speech",
            selectedProvider: "OpenAI"
        )
        wait(for: [openAIHDVoicesPublished], timeout: 1.0)

        manager.updateSettings(
            baseURL: "https://api.openai.com/v1/audio/speech",
            apiKey: "openai-token",
            model: "gpt-4o-mini-tts",
            voice: "marin",
            selectedProvider: "OpenAI"
        )
        let currentOpenAIVoicesPublished = expectPublication(
            manager.$voiceSuggestions,
            of: ProviderSuggestions(
                provider: .openAI,
                values: [
                    "alloy", "ash", "ballad", "coral", "echo", "fable", "onyx", "nova", "sage",
                    "shimmer", "verse", "marin", "cedar"
                ]
            ),
            "Current OpenAI voices published"
        )
        manager.fetchAvailableVoices(
            baseURL: "https://api.openai.com/v1/audio/speech",
            selectedProvider: "OpenAI"
        )
        wait(for: [currentOpenAIVoicesPublished], timeout: 1.0)

        manager.updateSettings(
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            apiKey: "gemini-token",
            model: "gemini-3.1-flash-tts-preview",
            voice: "Aoede",
            selectedProvider: "Gemini"
        )
        // WHY: Gemini has no discovery endpoint, so an omitted voice is simply unreachable for
        // the user. Exact agreement with the documented table is the only check that catches a
        // catalog that drifted from the provider contract, in either direction. Order is part
        // of that agreement: presenting the voices in the guide's order is what makes the two
        // comparable at a glance, so a deliberate reordering has to be restated here.
        let geminiVoicesPublished = expectPublication(
            manager.$voiceSuggestions,
            of: ProviderSuggestions(provider: .gemini, values: documentedGeminiTTSVoices),
            "Gemini voices published"
        )
        manager.fetchAvailableVoices(
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            selectedProvider: "Gemini"
        )
        wait(for: [geminiVoicesPublished], timeout: 1.0)

        // WHY: A Custom endpoint has no discovery contract, so there is no catalog to offer and no
        // request to make for one. Publishing anything here would either invent choices the
        // endpoint never declared or send the saved key to a path the user never configured. No
        // handler is installed, so this scope's unhandled-request accounting fails if one is sent.
        //
        // `SettingsView.syncSettings` is what keeps Settings from asking; this arm is the
        // manager's own answer, kept so the contract does not depend on that one caller alone.
        manager.updateSettings(
            baseURL: "https://custom.api/v1/audio/speech",
            apiKey: "custom-token",
            model: "custom-model",
            voice: "custom-voice",
            selectedProvider: "Custom"
        )
        manager.fetchAvailableVoices(
            baseURL: "https://custom.api/v1/audio/speech",
            selectedProvider: "Custom"
        )
        // The refusal is decided before the call returns: its request is abandoned on this thread,
        // so nothing is left queued that could still publish a catalog.
        let refusal = completions.records.last?.completion
        XCTAssertEqual(refusal?.kind, .voices)
        XCTAssertEqual(refusal?.outcome, .abandoned, "Custom's voice refusal must be final before the call returns.")
        XCTAssertEqual(manager.voiceSuggestions, .unpublished)
    }

    func testGeminiVoiceCatalogRefreshPreservesSavedVoiceInSpeechRequest() {
        // WHY: The catalog is provider metadata, not a selection. A refresh that also wrote a voice
        // would speak in a voice the user never chose while Settings still displays theirs, and the
        // saved choice's position in the published order is no reason to replace it. The saved voice
        // here is the catalog's last entry, so any reset toward the list's beginning is visible in
        // the one place it matters: the next request's payload.
        let manager = TestNetworkFactory.makeManager()
        manager.updateSettings(
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            apiKey: "gemini-token",
            model: "gemini-3.1-flash-tts-preview",
            voice: "Sulafat",
            selectedProvider: "Gemini"
        )
        let voicesPublished = expectPublication(
            manager.$voiceSuggestions,
            of: ProviderSuggestions(provider: .gemini, values: documentedGeminiTTSVoices),
            "Gemini catalog published before the request"
        )
        manager.fetchAvailableVoices(
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            selectedProvider: "Gemini"
        )
        wait(for: [voicesPublished], timeout: 1.0)

        let requestStarted = expectation(description: "The saved Gemini voice survives the metadata refresh")
        MockURLProtocol.installRequestHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            guard let bodyData = requestBodyData(from: request),
                  let body = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
                XCTFail("The Gemini request should contain a JSON speech payload.")
                requestStarted.fulfill()
                return (response, Data())
            }
            let generationConfig = body["generationConfig"] as? [String: Any]
            let speechConfig = generationConfig?["speechConfig"] as? [String: Any]
            let voiceConfig = speechConfig?["voiceConfig"] as? [String: Any]
            let prebuiltVoiceConfig = voiceConfig?["prebuiltVoiceConfig"] as? [String: Any]
            XCTAssertEqual(prebuiltVoiceConfig?["voiceName"] as? String, "Sulafat")
            requestStarted.fulfill()
            return (response, Data())
        }

        manager.streamTTS(text: "Keep the saved voice") { _ in }
        wait(for: [requestStarted], timeout: 2.0)
    }
}
