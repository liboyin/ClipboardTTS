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
            // WHY: Declining to publish is only half the transition. The refusal must also release
            // the slot, and the finished task it retains, that its own token held. Nothing else
            // observes that release, so without this assertion the shared clearing the publishing
            // and abandoning paths now share could be dropped entirely with every gate still green.
            XCTAssertNil(
                manager.metadataTokenForTesting(for: .models),
                "An abandoned refresh must release the request slot its own token held."
            )
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
