import XCTest
@testable import ClipboardTTSApp

final class TTSNetworkManagerMetadataProviderTests: MockURLProtocolTestCase {
    override func setUp() {
        super.setUp()
        isolateAppSettingsDefaults()
    }

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
            XCTAssertTrue(manager.availableVoices.contains("Aoede"))
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
}
