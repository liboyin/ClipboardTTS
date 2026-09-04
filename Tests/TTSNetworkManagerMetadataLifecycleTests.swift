import XCTest
@testable import ClipboardTTSApp

final class TTSNetworkManagerMetadataLifecycleTests: MockURLProtocolTestCase {
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

    func testAnAbandonedModelRequestCannotClearTheRequestThatReplacedIt() {
        // WHY: An abandoning completion and a publishing one clear the same slot, so the abandoning
        // half must check the token for the same reason the publishing half does. A refresh that
        // fails to decode still has to report itself as finished, and by then a later refresh for
        // the same source may already own the model slot. Clearing without matching the token would
        // discard the live request, and the replacement's own completion would then find nothing to
        // match and publish nothing — leaving the Settings model picker permanently empty after any
        // malformed response, with no error anywhere to explain it.
        let manager = TestNetworkFactory.makeManager()
        let endpoint = "https://custom.example/v1/audio/speech"
        let abandonedKey = "custom-ke"
        let replacementKey = "custom-key"
        manager.updateSettings(
            baseURL: endpoint,
            apiKey: abandonedKey,
            model: "model",
            voice: "voice",
            selectedProvider: "Custom"
        )

        let abandonedRequestStarted = expectation(description: "The abandoned model request started")
        let abandonedResponseReturned = expectation(description: "The abandoned model response returned")
        let replacementResponseReturned = expectation(description: "The replacement model response returned")
        let releaseAbandonedResponse = DispatchSemaphore(value: 0)
        defer { releaseAbandonedResponse.signal() }
        MockURLProtocol.installRequestHandler { request in
            // The two refreshes are told apart by the key each keystroke had produced so far.
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(abandonedKey)" else {
                replacementResponseReturned.fulfill()
                return metadataResponse(for: request, json: "{ \"data\": [{\"id\": \"live-tts-model\"}] }")
            }
            abandonedRequestStarted.fulfill()
            _ = releaseAbandonedResponse.wait(timeout: .now() + 1.0)
            abandonedResponseReturned.fulfill()
            // Undecodable, so this refresh takes the abandonment path rather than publishing.
            return metadataResponse(for: request, json: "{ \"data\": {} }")
        }

        manager.fetchAvailableModels(baseURL: endpoint, apiKey: abandonedKey, selectedProvider: "Custom")
        wait(for: [abandonedRequestStarted], timeout: 1.0)
        guard let abandonedToken = manager.metadataTokenForTesting(for: .models) else {
            XCTFail("Expected the first refresh to own model metadata state.")
            return
        }

        manager.fetchAvailableModels(baseURL: endpoint, apiKey: replacementKey, selectedProvider: "Custom")
        guard let replacementToken = manager.metadataTokenForTesting(for: .models) else {
            XCTFail("Expected the replacing refresh to own model metadata state.")
            return
        }
        XCTAssertNotEqual(abandonedToken, replacementToken)

        // URLSession completion timing cannot order the abandonment against the replacement, so
        // deliver that race through the same guard the production abandonment paths call.
        manager.finishMetadataRequestForTesting(for: .models, token: abandonedToken)
        XCTAssertEqual(
            manager.metadataTokenForTesting(for: .models),
            replacementToken,
            "An abandoned refresh must clear only its own request, never the one that replaced it."
        )

        releaseAbandonedResponse.signal()
        wait(for: [abandonedResponseReturned, replacementResponseReturned], timeout: 3.0)

        let replacementPublished = expectation(description: "The replacing refresh published its models")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(manager.modelSuggestions.values, ["live-tts-model"])
            replacementPublished.fulfill()
        }
        wait(for: [replacementPublished], timeout: 1.0)
    }
}
