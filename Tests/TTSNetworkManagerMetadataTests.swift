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
        XCTAssertEqual(manager.modelSuggestions.values, [])
        manager.fetchAvailableModels(
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            apiKey: "gemini-test-key",
            selectedProvider: "Gemini"
        )

        let geminiModelsPublished = expectation(description: "Gemini models published")
        DispatchQueue.main.async {
            XCTAssertEqual(manager.modelSuggestions.values, ["gemini-3.1-flash-tts-preview"])
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
            XCTAssertEqual(manager.modelSuggestions.values, ["gemini-3.1-flash-tts-preview"])
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
        XCTAssertEqual(manager.modelSuggestions.values, [])
        manager.fetchAvailableModels(baseURL: secondEndpoint, apiKey: "custom-b-key", selectedProvider: "Custom")

        // The mock protocol may serialize its loads, so release endpoint A only after endpoint B
        // has been requested rather than requiring B's request to begin concurrently.
        releaseOldResponse.signal()
        wait(for: [oldResponseReturned, secondRequestCompleted], timeout: 1.0)

        let currentModelsPublished = expectation(description: "Second Custom models published")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(manager.modelSuggestions.values, ["current-tts-model"])
            currentModelsPublished.fulfill()
        }
        wait(for: [currentModelsPublished], timeout: 1.0)

        let staleResponseIgnored = expectation(description: "Stale Custom models response ignored")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(manager.modelSuggestions.values, ["current-tts-model"])
            staleResponseIgnored.fulfill()
        }
        wait(for: [staleResponseIgnored], timeout: 1.0)
    }

    func testAVoiceCatalogPublishedForTheOldProviderCannotReplaceTheNewOne() throws {
        // WHY: Voice suggestions are provider-defined constants, but their publication is still
        // asynchronous, so a switch made in that window must invalidate the catalog already in
        // flight. Voice metadata therefore needs freshness state of its own, independent of the
        // models request that Settings starts beside it.
        let manager = TestNetworkFactory.makeManager()
        let geminiEndpoint = "https://generativelanguage.googleapis.com/v1beta"
        manager.updateSettings(
            baseURL: geminiEndpoint,
            apiKey: "gemini-key",
            model: "gemini-3.1-flash-tts-preview",
            voice: "Aoede",
            selectedProvider: "Gemini"
        )

        manager.fetchAvailableVoices(baseURL: geminiEndpoint, selectedProvider: "Gemini")
        let staleToken = try XCTUnwrap(
            manager.metadataTokenForTesting(for: .voices),
            "The started voice request must own voice metadata state until its publication runs."
        )

        manager.updateSettings(
            baseURL: "https://api.openai.com/v1/audio/speech",
            apiKey: "openai-key",
            model: "tts-1",
            voice: "alloy",
            selectedProvider: "OpenAI"
        )
        XCTAssertEqual(manager.voiceSuggestions.values, [])

        // The Gemini publication is already queued for the main queue at this point; deliver a
        // second one through the same production guard so both races are covered.
        manager.publishMetadataForTesting(documentedGeminiTTSVoices, for: .voices, token: staleToken)

        let staleCatalogIgnored = expectation(description: "Stale Gemini catalog ignored")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(manager.voiceSuggestions, .unpublished)
            staleCatalogIgnored.fulfill()
        }
        wait(for: [staleCatalogIgnored], timeout: 1.0)
    }

    func testScopeChangesCancelThePendingModelRequest() {
        // WHY: Freshness guards prevent stale publication, but cancellation also matters because
        // abandoned metadata work must not continue consuming a provider connection after a switch.
        // Only model discovery issues a request, so it is the only one there is a task to cancel.
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
        let releaseModelRequest = DispatchSemaphore(value: 0)
        defer { releaseModelRequest.signal() }
        MockURLProtocol.installRequestHandler { request in
            modelRequestStarted.fulfill()
            _ = releaseModelRequest.wait(timeout: .now() + 1.0)
            modelRequestReleased.fulfill()
            return metadataResponse(for: request, json: "{ \"data\": [] }")
        }

        manager.fetchAvailableModels(baseURL: firstEndpoint, apiKey: "custom-a-key", selectedProvider: "Custom")
        wait(for: [modelRequestStarted], timeout: 1.0)
        guard let modelTask = manager.modelMetadataTaskForTesting() else {
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
    }

    func testRefreshingTheSameSourceCancelsTheModelRequestItReplaces() {
        // WHY: Every keystroke in a Settings API-key field runs `syncSettings`, which refreshes
        // metadata for the provider and endpoint already selected. The scope has not changed, so
        // `updateSettings` invalidates nothing, and this replacement is the only thing that stops
        // the discovery request the keystroke discarded: without it, typing a key would leave one
        // provider connection in flight per character.
        let manager = TestNetworkFactory.makeManager()
        let endpoint = "https://api.openai.com/v1/audio/speech"
        let partialKey = "openai-ke"
        let completeKey = "openai-key"
        manager.updateSettings(
            baseURL: endpoint,
            apiKey: partialKey,
            model: "tts-1",
            voice: "alloy",
            selectedProvider: "OpenAI"
        )

        let replacedRequestStarted = expectation(description: "The replaced model request started")
        let replacedRequestReleased = expectation(description: "The replaced model request finished")
        let replacementCompleted = expectation(description: "The replacing model request finished")
        let releaseReplacedRequest = DispatchSemaphore(value: 0)
        defer { releaseReplacedRequest.signal() }
        MockURLProtocol.installRequestHandler { request in
            // The two refreshes are told apart by the key each keystroke had produced so far.
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(partialKey)" else {
                replacementCompleted.fulfill()
                return metadataResponse(for: request, json: "{ \"data\": [] }")
            }
            replacedRequestStarted.fulfill()
            _ = releaseReplacedRequest.wait(timeout: .now() + 1.0)
            replacedRequestReleased.fulfill()
            return metadataResponse(for: request, json: "{ \"data\": [] }")
        }

        manager.fetchAvailableModels(baseURL: endpoint, apiKey: partialKey, selectedProvider: "OpenAI")
        wait(for: [replacedRequestStarted], timeout: 1.0)
        guard let replacedTask = manager.modelMetadataTaskForTesting() else {
            XCTFail("Expected the first refresh to own a pending model metadata task.")
            return
        }

        manager.fetchAvailableModels(baseURL: endpoint, apiKey: completeKey, selectedProvider: "OpenAI")
        XCTAssertNotEqual(
            replacedTask.state,
            .running,
            "Refreshing the same source must cancel the discovery request it replaces."
        )

        releaseReplacedRequest.signal()
        wait(for: [replacedRequestReleased, replacementCompleted], timeout: 3.0)
    }

    func testOneSettingsRefreshPublishesBothTheModelListAndTheVoiceCatalog() {
        // WHY: This is the trade-off the replacement guard has to respect. `fetchMetadata` asks
        // for models and then voices in a single refresh, and both go through the same guard, so
        // one that did not distinguish the two kinds would let the voice request cancel the model
        // request started beside it and leave the model picker permanently empty.
        let manager = TestNetworkFactory.makeManager()
        let endpoint = "https://api.openai.com/v1/audio/speech"
        manager.updateSettings(
            baseURL: endpoint,
            apiKey: "openai-key",
            model: "tts-1",
            voice: "alloy",
            selectedProvider: "OpenAI"
        )

        // The models response is withheld until the voice half of the refresh has been asked for.
        // Without that, the model request could finish first and leave nothing for an
        // over-restricted guard to cancel, so the assertion below would hold either way.
        let modelsRequestStarted = expectation(description: "The model discovery request started")
        let modelsResponseReturned = expectation(description: "The model discovery response returned")
        let releaseModelsResponse = DispatchSemaphore(value: 0)
        defer { releaseModelsResponse.signal() }
        MockURLProtocol.installRequestHandler { request in
            modelsRequestStarted.fulfill()
            _ = releaseModelsResponse.wait(timeout: .now() + 2.0)
            modelsResponseReturned.fulfill()
            return metadataResponse(for: request, json: "{ \"data\": [{\"id\": \"tts-1\"}] }")
        }

        // The order `SettingsView.fetchMetadata` uses.
        manager.fetchAvailableModels(baseURL: endpoint, apiKey: "openai-key", selectedProvider: "OpenAI")
        wait(for: [modelsRequestStarted], timeout: 2.0)
        manager.fetchAvailableVoices(baseURL: endpoint, selectedProvider: "OpenAI")

        releaseModelsResponse.signal()
        wait(for: [modelsResponseReturned], timeout: 2.0)

        let bothListsPublished = expectation(description: "Both suggestion lists published")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(manager.modelSuggestions.values, ["tts-1"])
            XCTAssertEqual(
                manager.voiceSuggestions.values,
                ["alloy", "ash", "coral", "echo", "fable", "onyx", "nova", "sage", "shimmer"]
            )
            bothListsPublished.fulfill()
        }
        wait(for: [bothListsPublished], timeout: 2.0)
    }

    func testMalformedMetadataDoesNotReplaceCurrentLists() {
        // WHY: A malformed response must not turn a known-good current-provider list into an
        // arbitrary value; only a successful, decodable response is allowed to publish.
        let manager = TestNetworkFactory.makeManager()
        let endpoint = "https://custom.example/v1/audio/speech"
        manager.updateSettings(baseURL: endpoint, apiKey: "custom-key", model: "model", voice: "voice", selectedProvider: "Custom")
        manager.modelSuggestions = ProviderSuggestions(provider: "Custom", values: ["known-tts-model"])

        let requestCompleted = expectation(description: "Malformed metadata request completed")
        MockURLProtocol.installRequestHandler { request in
            requestCompleted.fulfill()
            return metadataResponse(for: request, json: "{ \"data\": {} }")
        }

        manager.fetchAvailableModels(baseURL: endpoint, apiKey: "custom-key", selectedProvider: "Custom")
        wait(for: [requestCompleted], timeout: 1.0)

        let malformedResponseIgnored = expectation(description: "Malformed metadata was not published")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(manager.modelSuggestions.values, ["known-tts-model"])
            malformedResponseIgnored.fulfill()
        }
        wait(for: [malformedResponseIgnored], timeout: 1.0)
    }

    func testEmptySuccessfulMetadataResponsesClearCurrentLists() {
        // WHY: An empty successful response is authoritative for the current source and must clear
        // old entries rather than leave users selecting metadata that no longer exists.
        let manager = TestNetworkFactory.makeManager()
        let endpoint = "https://custom.example/v1/audio/speech"
        manager.updateSettings(baseURL: endpoint, apiKey: "custom-key", model: "model", voice: "voice", selectedProvider: "Custom")
        manager.modelSuggestions = ProviderSuggestions(provider: "Custom", values: ["old-tts-model"])

        let requestCompleted = expectation(description: "Empty metadata request completed")
        MockURLProtocol.installRequestHandler { request in
            requestCompleted.fulfill()
            return metadataResponse(for: request, json: "{ \"data\": [] }")
        }

        manager.fetchAvailableModels(baseURL: endpoint, apiKey: "custom-key", selectedProvider: "Custom")
        wait(for: [requestCompleted], timeout: 1.0)

        let emptyListPublished = expectation(description: "Empty metadata list published")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(manager.modelSuggestions.values, [])
            emptyListPublished.fulfill()
        }
        wait(for: [emptyListPublished], timeout: 1.0)
    }

}

private func metadataResponse(for request: URLRequest, json: String) -> (HTTPURLResponse, Data?) {
    guard let url = request.url,
          let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
        return (HTTPURLResponse(), Data())
    }
    return (response, Data(json.utf8))
}
