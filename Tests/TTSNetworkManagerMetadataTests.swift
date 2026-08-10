import XCTest
@testable import ClipboardTTSApp

final class TTSNetworkManagerMetadataTests: MockURLProtocolTestCase {
    func testDelayedOpenAIModelsCannotReplaceGeminiModels() {
        // WHY: Cancellation races with URLSession completion, so a delayed OpenAI response must not
        // overwrite the Gemini models that the user selected after starting the original request.
        let manager = TestNetworkFactory.makeManager()
        manager.updateSettings(
            baseURL: "https://api.openai.com/v1/audio/speech",
            apiKey: "openai-test-key",
            model: "tts-1",
            voice: "alloy",
            selectedProvider: "OpenAI"
        )

        let oldRequestStarted = expectation(description: "OpenAI metadata request started")
        let oldResponseReturned = expectation(description: "OpenAI metadata response returned")
        let releaseOldResponse = DispatchSemaphore(value: 0)
        MockURLProtocol.installRequestHandler { request in
            oldRequestStarted.fulfill()
            _ = releaseOldResponse.wait(timeout: .now() + 1.0)
            oldResponseReturned.fulfill()
            return metadataResponse(
                for: request,
                json: "{ \"data\": [{\"id\": \"stale-tts-model\"}] }"
            )
        }

        manager.fetchAvailableModels(
            baseURL: "https://api.openai.com/v1/audio/speech",
            apiKey: "openai-test-key",
            selectedProvider: "OpenAI"
        )
        wait(for: [oldRequestStarted], timeout: 1.0)
        guard let staleToken = manager.metadataTokenForTesting(for: .models) else {
            XCTFail("Expected the delayed OpenAI request to own model metadata state.")
            releaseOldResponse.signal()
            return
        }

        manager.updateSettings(
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            apiKey: "gemini-test-key",
            model: "gemini-3.1-flash-tts-preview",
            voice: "Aoede",
            selectedProvider: "Gemini"
        )
        XCTAssertEqual(manager.availableModels, [])
        manager.fetchAvailableModels(
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            apiKey: "gemini-test-key",
            selectedProvider: "Gemini"
        )

        let geminiModelsPublished = expectation(description: "Gemini models published")
        DispatchQueue.main.async {
            XCTAssertEqual(manager.availableModels, ["gemini-3.1-flash-tts-preview"])
            geminiModelsPublished.fulfill()
        }
        wait(for: [geminiModelsPublished], timeout: 1.0)

        // URLSession can cancel before delivering a mock response, but a production completion
        // might already be queued. Deliver that race through the same publication path.
        manager.publishMetadataForTesting(["stale-tts-model"], for: .models, token: staleToken)
        releaseOldResponse.signal()
        wait(for: [oldResponseReturned], timeout: 1.0)

        let staleResponseIgnored = expectation(description: "Stale OpenAI response ignored")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(manager.availableModels, ["gemini-3.1-flash-tts-preview"])
            staleResponseIgnored.fulfill()
        }
        wait(for: [staleResponseIgnored], timeout: 1.0)
    }

    func testDelayedCustomModelsCannotReplaceModelsFromNewEndpoint() {
        // WHY: Two Custom endpoints share the same request contract, so provider identity alone
        // cannot prevent endpoint A's late models from replacing endpoint B's current models.
        let manager = TestNetworkFactory.makeManager()
        let firstEndpoint = "https://custom-a.example/v1/audio/speech"
        let secondEndpoint = "https://custom-b.example/v1/audio/speech"
        manager.updateSettings(
            baseURL: firstEndpoint,
            apiKey: "custom-a-key",
            model: "model-a",
            voice: "voice-a",
            selectedProvider: "Custom"
        )

        let oldRequestStarted = expectation(description: "First Custom models request started")
        let oldResponseReturned = expectation(description: "First Custom models response returned")
        let secondRequestCompleted = expectation(description: "Second Custom models request completed")
        let releaseOldResponse = DispatchSemaphore(value: 0)
        MockURLProtocol.installRequestHandler { request in
            if request.url?.host == "custom-a.example" {
                oldRequestStarted.fulfill()
                _ = releaseOldResponse.wait(timeout: .now() + 1.0)
                oldResponseReturned.fulfill()
                return metadataResponse(for: request, json: "{ \"data\": [{\"id\": \"stale-tts-model\"}] }")
            }

            secondRequestCompleted.fulfill()
            return metadataResponse(for: request, json: "{ \"data\": [{\"id\": \"current-tts-model\"}] }")
        }

        manager.fetchAvailableModels(baseURL: firstEndpoint, apiKey: "custom-a-key", selectedProvider: "Custom")
        wait(for: [oldRequestStarted], timeout: 1.0)

        manager.updateSettings(
            baseURL: secondEndpoint,
            apiKey: "custom-b-key",
            model: "model-b",
            voice: "voice-b",
            selectedProvider: "Custom"
        )
        XCTAssertEqual(manager.availableModels, [])
        manager.fetchAvailableModels(baseURL: secondEndpoint, apiKey: "custom-b-key", selectedProvider: "Custom")

        // The mock protocol may serialize its loads, so release endpoint A only after endpoint B
        // has been requested rather than requiring B's request to begin concurrently.
        releaseOldResponse.signal()
        wait(for: [oldResponseReturned, secondRequestCompleted], timeout: 1.0)

        let currentModelsPublished = expectation(description: "Second Custom models published")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(manager.availableModels, ["current-tts-model"])
            currentModelsPublished.fulfill()
        }
        wait(for: [currentModelsPublished], timeout: 1.0)

        let staleResponseIgnored = expectation(description: "Stale Custom models response ignored")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(manager.availableModels, ["current-tts-model"])
            staleResponseIgnored.fulfill()
        }
        wait(for: [staleResponseIgnored], timeout: 1.0)
    }

    func testDelayedCustomVoicesCannotReplaceVoicesFromNewEndpoint() throws {
        // WHY: Voice metadata is independently requested and must have its own cancellation and
        // freshness state, otherwise a late response can repopulate the picker with old voices.
        let manager = TestNetworkFactory.makeManager()
        let firstEndpoint = "https://custom-a.example/v1/audio/speech"
        let secondEndpoint = "https://custom-b.example/v1/audio/speech"
        manager.updateSettings(
            baseURL: firstEndpoint,
            apiKey: "custom-a-key",
            model: "model-a",
            voice: "voice-a",
            selectedProvider: "Custom"
        )

        let oldRequestStarted = expectation(description: "First Custom voices request started")
        let oldResponseReturned = expectation(description: "First Custom voices response returned")
        let secondRequestCompleted = expectation(description: "Second Custom voices request completed")
        let releaseOldResponse = DispatchSemaphore(value: 0)
        defer { releaseOldResponse.signal() }
        MockURLProtocol.installRequestHandler { request in
            if request.url?.host == "custom-a.example" {
                oldRequestStarted.fulfill()
                _ = releaseOldResponse.wait(timeout: .now() + 1.0)
                oldResponseReturned.fulfill()
                return metadataResponse(for: request, json: "{ \"voices\": [\"stale-voice\"] }")
            }

            secondRequestCompleted.fulfill()
            return metadataResponse(for: request, json: "{ \"voices\": [\"current-voice\"] }")
        }

        manager.fetchAvailableVoices(baseURL: firstEndpoint, apiKey: "custom-a-key", selectedProvider: "Custom")
        wait(for: [oldRequestStarted], timeout: 1.0)
        let staleToken = try XCTUnwrap(manager.metadataTokenForTesting(for: .voices))

        manager.updateSettings(
            baseURL: secondEndpoint,
            apiKey: "custom-b-key",
            model: "model-b",
            voice: "voice-b",
            selectedProvider: "Custom"
        )
        XCTAssertEqual(manager.availableVoices, [])
        manager.fetchAvailableVoices(baseURL: secondEndpoint, apiKey: "custom-b-key", selectedProvider: "Custom")

        releaseOldResponse.signal()
        wait(for: [oldResponseReturned, secondRequestCompleted], timeout: 1.0)

        let currentVoicesPublished = expectation(description: "Second Custom voices published")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(manager.availableVoices, ["current-voice"])
            currentVoicesPublished.fulfill()
        }
        wait(for: [currentVoicesPublished], timeout: 1.0)

        // Cancellation can race with a response already enqueued for the main queue, so route a
        // synthetic late completion through the production guard before checking the final list.
        manager.publishMetadataForTesting(["stale-voice"], for: .voices, token: staleToken)

        let staleResponseIgnored = expectation(description: "Stale Custom voices response ignored")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(manager.availableVoices, ["current-voice"])
            staleResponseIgnored.fulfill()
        }
        wait(for: [staleResponseIgnored], timeout: 1.0)
    }

    func testScopeChangesCancelPendingModelAndVoiceRequests() {
        // WHY: Freshness guards prevent stale publication, but cancellation also matters because
        // abandoned metadata work must not continue consuming a provider connection after a switch.
        let manager = TestNetworkFactory.makeManager()
        let firstEndpoint = "https://custom-a.example/v1/audio/speech"
        let secondEndpoint = "https://custom-b.example/v1/audio/speech"
        manager.updateSettings(
            baseURL: firstEndpoint,
            apiKey: "custom-a-key",
            model: "model-a",
            voice: "voice-a",
            selectedProvider: "Custom"
        )

        let modelRequestStarted = expectation(description: "First model request started")
        let modelRequestReleased = expectation(description: "First model request released")
        let voiceRequestStarted = expectation(description: "Second voice request started")
        let voiceRequestReleased = expectation(description: "Second voice request released")
        let releaseModelRequest = DispatchSemaphore(value: 0)
        let releaseVoiceRequest = DispatchSemaphore(value: 0)
        defer {
            releaseModelRequest.signal()
            releaseVoiceRequest.signal()
        }
        MockURLProtocol.installRequestHandler { request in
            if request.url?.path.hasSuffix("/models") == true {
                modelRequestStarted.fulfill()
                _ = releaseModelRequest.wait(timeout: .now() + 1.0)
                modelRequestReleased.fulfill()
                return metadataResponse(for: request, json: "{ \"data\": [] }")
            }

            voiceRequestStarted.fulfill()
            _ = releaseVoiceRequest.wait(timeout: .now() + 1.0)
            voiceRequestReleased.fulfill()
            return metadataResponse(for: request, json: "{ \"voices\": [] }")
        }

        manager.fetchAvailableModels(baseURL: firstEndpoint, apiKey: "custom-a-key", selectedProvider: "Custom")
        wait(for: [modelRequestStarted], timeout: 1.0)
        guard let modelTask = manager.metadataTaskForTesting(for: .models) else {
            XCTFail("Expected a pending model metadata task.")
            return
        }

        manager.updateSettings(
            baseURL: secondEndpoint,
            apiKey: "custom-b-key",
            model: "model-b",
            voice: "voice-b",
            selectedProvider: "Custom"
        )
        XCTAssertNotEqual(modelTask.state, .running, "Changing endpoints must cancel the pending model request.")
        releaseModelRequest.signal()
        wait(for: [modelRequestReleased], timeout: 1.0)

        manager.fetchAvailableVoices(baseURL: secondEndpoint, apiKey: "custom-b-key", selectedProvider: "Custom")
        wait(for: [voiceRequestStarted], timeout: 1.0)
        guard let voiceTask = manager.metadataTaskForTesting(for: .voices) else {
            XCTFail("Expected a pending voice metadata task.")
            return
        }

        manager.updateSettings(
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            apiKey: "gemini-key",
            model: "gemini-3.1-flash-tts-preview",
            voice: "Aoede",
            selectedProvider: "Gemini"
        )
        XCTAssertNotEqual(voiceTask.state, .running, "Changing providers must cancel the pending voice request.")
        releaseVoiceRequest.signal()
        wait(for: [voiceRequestReleased], timeout: 1.0)
    }

    func testMalformedMetadataDoesNotReplaceCurrentLists() {
        // WHY: A malformed response must not turn a known-good current-provider list into an
        // arbitrary value; only a successful, decodable response is allowed to publish.
        let manager = TestNetworkFactory.makeManager()
        let endpoint = "https://custom.example/v1/audio/speech"
        manager.updateSettings(baseURL: endpoint, apiKey: "custom-key", model: "model", voice: "voice", selectedProvider: "Custom")
        manager.availableModels = ["known-tts-model"]
        manager.availableVoices = ["known-voice"]

        let requestsCompleted = expectation(description: "Malformed metadata requests completed")
        requestsCompleted.expectedFulfillmentCount = 2
        MockURLProtocol.installRequestHandler { request in
            requestsCompleted.fulfill()
            let json = request.url?.path.hasSuffix("/models") == true
                ? "{ \"data\": {} }"
                : "{ \"data\": [{\"id\": \"valid-voice\"}, {}] }"
            return metadataResponse(for: request, json: json)
        }

        manager.fetchAvailableModels(baseURL: endpoint, apiKey: "custom-key", selectedProvider: "Custom")
        manager.fetchAvailableVoices(baseURL: endpoint, apiKey: "custom-key", selectedProvider: "Custom")
        wait(for: [requestsCompleted], timeout: 1.0)

        let malformedResponsesIgnored = expectation(description: "Malformed metadata was not published")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(manager.availableModels, ["known-tts-model"])
            XCTAssertEqual(manager.availableVoices, ["known-voice"])
            malformedResponsesIgnored.fulfill()
        }
        wait(for: [malformedResponsesIgnored], timeout: 1.0)
    }

    func testEmptySuccessfulMetadataResponsesClearCurrentLists() {
        // WHY: An empty successful response is authoritative for the current source and must clear
        // old entries rather than leave users selecting metadata that no longer exists.
        let manager = TestNetworkFactory.makeManager()
        let endpoint = "https://custom.example/v1/audio/speech"
        manager.updateSettings(baseURL: endpoint, apiKey: "custom-key", model: "model", voice: "voice", selectedProvider: "Custom")
        manager.availableModels = ["old-tts-model"]
        manager.availableVoices = ["old-voice"]

        let requestsCompleted = expectation(description: "Empty metadata requests completed")
        requestsCompleted.expectedFulfillmentCount = 2
        MockURLProtocol.installRequestHandler { request in
            requestsCompleted.fulfill()
            let json = request.url?.path.hasSuffix("/models") == true ? "{ \"data\": [] }" : "{ \"voices\": [] }"
            return metadataResponse(for: request, json: json)
        }

        manager.fetchAvailableModels(baseURL: endpoint, apiKey: "custom-key", selectedProvider: "Custom")
        manager.fetchAvailableVoices(baseURL: endpoint, apiKey: "custom-key", selectedProvider: "Custom")
        wait(for: [requestsCompleted], timeout: 1.0)

        let emptyListsPublished = expectation(description: "Empty metadata lists published")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(manager.availableModels, [])
            XCTAssertEqual(manager.availableVoices, [])
            emptyListsPublished.fulfill()
        }
        wait(for: [emptyListsPublished], timeout: 1.0)
    }

}

private func metadataResponse(for request: URLRequest, json: String) -> (HTTPURLResponse, Data?) {
    guard let url = request.url,
          let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
        return (HTTPURLResponse(), Data())
    }
    return (response, Data(json.utf8))
}
