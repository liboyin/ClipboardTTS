import XCTest
@testable import ClipboardTTSApp

final class TTSNetworkManagerMetadataTests: MetadataTestCase {
    func testDelayedOpenAIModelsCannotReplaceGeminiModels() {
        // WHY: Cancellation races with URLSession completion, so a delayed OpenAI response must not
        // overwrite the Gemini models that the user selected after starting the original request.
        let (manager, completions) = makeMetadataManager()
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
            model: "gemini-3.8-flash-lite-tts",
            voice: "Aoede",
            selectedProvider: "Gemini"
        )
        XCTAssertEqual(manager.modelSuggestions.values, [])
        let geminiModelsPublished = expectPublication(
            manager.$modelSuggestions,
            of: ProviderSuggestions(provider: .gemini, values: ["gemini-3.8-flash-lite-tts", "gemini-3.8-flash-tts"]),
            "Gemini models published"
        )
        manager.fetchAvailableModels(
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            apiKey: "gemini-test-key",
            selectedProvider: "Gemini"
        )
        wait(for: [geminiModelsPublished], timeout: 1.0)

        // URLSession can cancel before delivering a mock response, but a production completion
        // might already be queued. Deliver that race through the same publication path.
        manager.publishMetadataForTesting(["stale-tts-model"], for: .models, token: staleToken)
        releaseOldResponse.signal()
        wait(for: [oldResponseReturned], timeout: 1.0)

        // The stale token completes twice: the synthetic publication above, and the cancelled
        // task's own completion. Both must have been refused before the list is read.
        waitForCompletions(in: completions, count: 2, "Both stale OpenAI completions were refused") {
            $0.kind == .models && $0.token == staleToken && $0.outcome == .superseded
        }
        XCTAssertEqual(manager.modelSuggestions.values, ["gemini-3.8-flash-lite-tts", "gemini-3.8-flash-tts"])
    }

    func testDelayedCustomModelsCannotReplaceModelsFromNewEndpoint() {
        // WHY: Two Custom endpoints share the same request contract, so provider identity alone
        // cannot prevent endpoint A's late models from replacing endpoint B's current models.
        let (manager, completions) = makeMetadataManager()
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
        guard let staleToken = manager.metadataTokenForTesting(for: .models) else {
            XCTFail("Expected the first Custom request to own model metadata state.")
            releaseOldResponse.signal()
            return
        }

        manager.updateSettings(
            baseURL: secondEndpoint,
            apiKey: "custom-b-key",
            model: "model-b",
            voice: "voice-b",
            selectedProvider: "Custom"
        )
        XCTAssertEqual(manager.modelSuggestions.values, [])
        let currentModelsPublished = expectPublication(
            manager.$modelSuggestions,
            of: ProviderSuggestions(provider: .custom, values: ["current-tts-model"]),
            "Second Custom models published"
        )
        manager.fetchAvailableModels(baseURL: secondEndpoint, apiKey: "custom-b-key", selectedProvider: "Custom")

        // The mock protocol may serialize its loads, so release endpoint A only after endpoint B
        // has been requested rather than requiring B's request to begin concurrently.
        releaseOldResponse.signal()
        wait(for: [oldResponseReturned, secondRequestCompleted, currentModelsPublished], timeout: 1.0)

        waitForCompletions(in: completions, "The stale Custom models completion was refused") {
            $0.kind == .models && $0.token == staleToken && $0.outcome == .superseded
        }
        XCTAssertEqual(manager.modelSuggestions.values, ["current-tts-model"])
    }

    func testAVoiceCatalogPublishedForTheOldProviderCannotReplaceTheNewOne() throws {
        // WHY: Voice suggestions are provider-defined constants, but their publication is still
        // asynchronous, so a switch made in that window must invalidate the catalog already in
        // flight. Voice metadata therefore needs freshness state of its own, independent of the
        // models request that Settings starts beside it.
        let (manager, completions) = makeMetadataManager()
        let geminiEndpoint = "https://generativelanguage.googleapis.com/v1beta"
        manager.updateSettings(
            baseURL: geminiEndpoint,
            apiKey: "gemini-key",
            model: "gemini-3.8-flash-lite-tts",
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

        waitForCompletions(in: completions, count: 2, "Both stale Gemini catalogs were refused") {
            $0.kind == .voices && $0.token == staleToken && $0.outcome == .superseded
        }
        XCTAssertEqual(manager.voiceSuggestions, .unpublished)
    }

    func testMalformedMetadataDoesNotReplaceCurrentLists() {
        // WHY: A malformed response must not turn a known-good current-provider list into an
        // arbitrary value; only a successful, decodable response is allowed to publish.
        let (manager, completions) = makeMetadataManager()
        let endpoint = "https://custom.example/v1/audio/speech"
        manager.updateSettings(baseURL: endpoint, apiKey: "custom-key", model: "model", voice: "voice", selectedProvider: "Custom")
        manager.modelSuggestions = ProviderSuggestions(provider: .custom, values: ["known-tts-model"])

        let requestCompleted = expectation(description: "Malformed metadata request completed")
        MockURLProtocol.installRequestHandler { request in
            requestCompleted.fulfill()
            return metadataResponse(for: request, json: "{ \"data\": {} }")
        }

        manager.fetchAvailableModels(baseURL: endpoint, apiKey: "custom-key", selectedProvider: "Custom")
        wait(for: [requestCompleted], timeout: 1.0)
        waitForCompletions(in: completions, "The malformed response was abandoned") {
            $0.kind == .models && $0.outcome == .abandoned
        }

        XCTAssertEqual(manager.modelSuggestions.values, ["known-tts-model"])
        // WHY: Declining to publish is only half the transition. The refusal must also release
        // the slot, and the finished task it retains, that its own token held. Nothing else
        // observes that release, so without this assertion the shared clearing the publishing
        // and abandoning paths now share could be dropped entirely with every gate still green.
        XCTAssertNil(
            manager.metadataTokenForTesting(for: .models),
            "An abandoned refresh must release the request slot its own token held."
        )
    }

    func testEmptySuccessfulMetadataResponsesClearCurrentLists() {
        // WHY: An empty successful response is authoritative for the current source and must clear
        // old entries rather than leave users selecting metadata that no longer exists.
        let manager = TestNetworkFactory.makeManager()
        let endpoint = "https://custom.example/v1/audio/speech"
        manager.updateSettings(baseURL: endpoint, apiKey: "custom-key", model: "model", voice: "voice", selectedProvider: "Custom")
        manager.modelSuggestions = ProviderSuggestions(provider: .custom, values: ["old-tts-model"])

        let requestCompleted = expectation(description: "Empty metadata request completed")
        MockURLProtocol.installRequestHandler { request in
            requestCompleted.fulfill()
            return metadataResponse(for: request, json: "{ \"data\": [] }")
        }
        let emptyListPublished = expectPublication(
            manager.$modelSuggestions,
            of: ProviderSuggestions(provider: .custom, values: []),
            "Empty metadata list published"
        )

        manager.fetchAvailableModels(baseURL: endpoint, apiKey: "custom-key", selectedProvider: "Custom")
        wait(for: [requestCompleted, emptyListPublished], timeout: 1.0)
    }
}
