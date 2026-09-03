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

final class TTSNetworkManagerMetadataProviderTests: MockURLProtocolTestCase {
    func testFetchAvailableModels() {
        let manager = TestNetworkFactory.makeManager()

        // Provider-defined lists use the same guarded publication path as network-backed metadata.
        manager.updateSettings(
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            apiKey: "gemini-token",
            model: "gemini-3.1-flash-tts-preview",
            voice: "Aoede",
            selectedProvider: "Gemini"
        )
        manager.fetchAvailableModels(
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            apiKey: "gemini-token",
            selectedProvider: "Gemini"
        )
        let geminiModelsPublished = expectation(description: "Gemini models published")
        DispatchQueue.main.async {
            XCTAssertEqual(manager.modelSuggestions.values, ["gemini-3.1-flash-tts-preview"])
            geminiModelsPublished.fulfill()
        }
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
        manager.fetchAvailableModels(
            baseURL: "https://api.openai.com/v1/audio/speech",
            apiKey: "openai-token",
            selectedProvider: "OpenAI"
        )
        let openAIModelsPublished = expectation(description: "OpenAI models published")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(manager.modelSuggestions.values, ["tts-1", "tts-1-hd"])
            openAIModelsPublished.fulfill()
        }
        wait(for: [openAIModelsPublished], timeout: 1.0)
    }

    func testFetchAvailableVoices() {
        let manager = TestNetworkFactory.makeManager()
        manager.updateSettings(
            baseURL: "https://api.openai.com/v1/audio/speech",
            apiKey: "openai-token",
            model: "tts-1",
            voice: "alloy",
            selectedProvider: "OpenAI"
        )
        manager.fetchAvailableVoices(
            baseURL: "https://api.openai.com/v1/audio/speech",
            selectedProvider: "OpenAI"
        )
        let openAIVoicesPublished = expectation(description: "OpenAI voices published")
        DispatchQueue.main.async {
            XCTAssertEqual(
                manager.voiceSuggestions.values,
                ["alloy", "ash", "coral", "echo", "fable", "onyx", "nova", "sage", "shimmer"]
            )
            openAIVoicesPublished.fulfill()
        }
        wait(for: [openAIVoicesPublished], timeout: 1.0)

        manager.updateSettings(
            baseURL: "https://api.openai.com/v1/audio/speech",
            apiKey: "openai-token",
            model: "tts-1-hd",
            voice: "alloy",
            selectedProvider: "OpenAI"
        )
        manager.fetchAvailableVoices(
            baseURL: "https://api.openai.com/v1/audio/speech",
            selectedProvider: "OpenAI"
        )
        let openAIHDVoicesPublished = expectation(description: "OpenAI HD voices published")
        DispatchQueue.main.async {
            XCTAssertEqual(
                manager.voiceSuggestions.values,
                ["alloy", "ash", "coral", "echo", "fable", "onyx", "nova", "sage", "shimmer"]
            )
            openAIHDVoicesPublished.fulfill()
        }
        wait(for: [openAIHDVoicesPublished], timeout: 1.0)

        manager.updateSettings(
            baseURL: "https://api.openai.com/v1/audio/speech",
            apiKey: "openai-token",
            model: "gpt-4o-mini-tts",
            voice: "marin",
            selectedProvider: "OpenAI"
        )
        manager.fetchAvailableVoices(
            baseURL: "https://api.openai.com/v1/audio/speech",
            selectedProvider: "OpenAI"
        )
        let currentOpenAIVoicesPublished = expectation(description: "Current OpenAI voices published")
        DispatchQueue.main.async {
            XCTAssertEqual(
                manager.voiceSuggestions.values,
                [
                    "alloy", "ash", "ballad", "coral", "echo", "fable", "onyx", "nova", "sage",
                    "shimmer", "verse", "marin", "cedar"
                ]
            )
            currentOpenAIVoicesPublished.fulfill()
        }
        wait(for: [currentOpenAIVoicesPublished], timeout: 1.0)

        manager.updateSettings(
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            apiKey: "gemini-token",
            model: "gemini-3.1-flash-tts-preview",
            voice: "Aoede",
            selectedProvider: "Gemini"
        )
        manager.fetchAvailableVoices(
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            selectedProvider: "Gemini"
        )
        let geminiVoicesPublished = expectation(description: "Gemini voices published")
        DispatchQueue.main.async {
            // WHY: Gemini has no discovery endpoint, so an omitted voice is simply unreachable for
            // the user. Exact agreement with the documented table is the only check that catches a
            // catalog that drifted from the provider contract, in either direction. Order is part
            // of that agreement: presenting the voices in the guide's order is what makes the two
            // comparable at a glance, so a deliberate reordering has to be restated here.
            XCTAssertEqual(manager.voiceSuggestions.values, documentedGeminiTTSVoices)
            geminiVoicesPublished.fulfill()
        }
        wait(for: [geminiVoicesPublished], timeout: 1.0)

        // WHY: A Custom endpoint has no discovery contract, so there is no catalog to offer and no
        // request to make for one. Publishing anything here would either invent choices the
        // endpoint never declared or send the saved key to a path the user never configured. No
        // handler is installed, so this scope's unhandled-request accounting fails if one is sent.
        //
        // `SettingsView.fetchMetadata` is what keeps Settings from asking; this arm is the
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
        let customVoicesRefused = expectation(description: "Custom publishes no voice catalog")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(manager.voiceSuggestions, .unpublished)
            customVoicesRefused.fulfill()
        }
        wait(for: [customVoicesRefused], timeout: 1.0)
    }

    func testPublishingTheGeminiCatalogLeavesAValidSavedVoiceOnTheNextRequest() {
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
        manager.fetchAvailableVoices(
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            selectedProvider: "Gemini"
        )
        let voicesPublished = expectation(description: "Gemini catalog published before the request")
        DispatchQueue.main.async {
            XCTAssertEqual(manager.voiceSuggestions.values, documentedGeminiTTSVoices)
            voicesPublished.fulfill()
        }
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
