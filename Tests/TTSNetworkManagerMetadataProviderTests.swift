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
            XCTAssertEqual(manager.availableModels, ["gemini-3.1-flash-tts-preview"])
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
            XCTAssertEqual(manager.availableModels, ["tts-1", "tts-1-hd"])
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
            apiKey: "openai-token",
            selectedProvider: "OpenAI"
        )
        let openAIVoicesPublished = expectation(description: "OpenAI voices published")
        DispatchQueue.main.async {
            XCTAssertEqual(
                manager.availableVoices,
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
            apiKey: "openai-token",
            selectedProvider: "OpenAI"
        )
        let openAIHDVoicesPublished = expectation(description: "OpenAI HD voices published")
        DispatchQueue.main.async {
            XCTAssertEqual(
                manager.availableVoices,
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
            apiKey: "openai-token",
            selectedProvider: "OpenAI"
        )
        let currentOpenAIVoicesPublished = expectation(description: "Current OpenAI voices published")
        DispatchQueue.main.async {
            XCTAssertEqual(
                manager.availableVoices,
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
            apiKey: "gemini-token",
            selectedProvider: "Gemini"
        )
        let geminiVoicesPublished = expectation(description: "Gemini voices published")
        DispatchQueue.main.async {
            // WHY: Gemini has no discovery endpoint, so an omitted voice is simply unreachable for
            // the user. Exact agreement with the documented table is the only check that catches a
            // catalog that drifted from the provider contract, in either direction. Order is part
            // of that agreement: presenting the voices in the guide's order is what makes the two
            // comparable at a glance, so a deliberate reordering has to be restated here.
            XCTAssertEqual(manager.availableVoices, documentedGeminiTTSVoices)
            geminiVoicesPublished.fulfill()
        }
        wait(for: [geminiVoicesPublished], timeout: 1.0)

        MockURLProtocol.installRequestHandler { request in
            let data = Data("{ \"voices\": [\"custom-voice-1\", \"custom-voice-2\"] }".utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        manager.updateSettings(
            baseURL: "https://custom.api/v1/audio/speech",
            apiKey: "custom-token",
            model: "custom-model",
            voice: "custom-voice",
            selectedProvider: "Custom"
        )
        manager.fetchAvailableVoices(
            baseURL: "https://custom.api/v1/audio/speech",
            apiKey: "custom-token",
            selectedProvider: "Custom"
        )
        let customVoicesPublished = expectation(description: "Custom voices published")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(manager.availableVoices, ["custom-voice-1", "custom-voice-2"])
            customVoicesPublished.fulfill()
        }
        wait(for: [customVoicesPublished], timeout: 1.0)
    }

    func testPublishingTheGeminiCatalogLeavesAValidSavedVoiceOnTheNextRequest() {
        // WHY: The catalog is provider metadata, not a selection. A refresh that also wrote a voice
        // would speak in a voice the user never chose while the menu and Settings still display
        // theirs, and the saved choice's position in the published order is no reason to replace
        // it. The saved voice here is the catalog's last entry, so any reset toward the list's
        // beginning is visible in the one place it matters: the next request's payload.
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
            apiKey: "gemini-token",
            selectedProvider: "Gemini"
        )
        let voicesPublished = expectation(description: "Gemini catalog published before the request")
        DispatchQueue.main.async {
            XCTAssertEqual(manager.availableVoices, documentedGeminiTTSVoices)
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
