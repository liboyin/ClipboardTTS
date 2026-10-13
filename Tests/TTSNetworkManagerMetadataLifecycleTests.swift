import XCTest
@testable import ClipboardTTSApp

final class TTSNetworkManagerMetadataLifecycleTests: MetadataTestCase {
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
        // WHY: This is the trade-off the replacement guard has to respect. `syncSettings` asks
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

        let modelsPublished = expectPublication(
            manager.$modelSuggestions,
            of: ProviderSuggestions(provider: .openAI, values: ["tts-1"]),
            "The model list published"
        )
        let voicesPublished = expectPublication(
            manager.$voiceSuggestions,
            of: ProviderSuggestions(
                provider: .openAI,
                values: ["alloy", "ash", "coral", "echo", "fable", "onyx", "nova", "sage", "shimmer"]
            ),
            "The voice catalog published"
        )

        // The order `SettingsView.syncSettings` uses.
        manager.fetchAvailableModels(baseURL: endpoint, apiKey: "openai-key", selectedProvider: "OpenAI")
        wait(for: [modelsRequestStarted], timeout: 2.0)
        manager.fetchAvailableVoices(baseURL: endpoint, selectedProvider: "OpenAI")

        releaseModelsResponse.signal()
        wait(for: [modelsResponseReturned, modelsPublished, voicesPublished], timeout: 2.0)
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

        // Observed before the replacement starts, because its response is not withheld.
        let replacementPublished = expectPublication(
            manager.$modelSuggestions,
            of: ProviderSuggestions(provider: .custom, values: ["live-tts-model"]),
            "The replacing refresh published its models"
        )
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
        wait(for: [abandonedResponseReturned, replacementResponseReturned, replacementPublished], timeout: 3.0)
    }

    func testTheCompletionObserverReportsAPublicationOnMainAfterItsListIsPublished() {
        // WHY: A stale-result test trusts this report to mean the completion's handling is final.
        // A report made before the publication it describes would let such a test read the list
        // while the publication that should change it is still pending.
        let (manager, completions) = makeMetadataManager()
        let endpoint = "https://generativelanguage.googleapis.com/v1beta"
        manager.updateSettings(
            baseURL: endpoint,
            apiKey: "gemini-key",
            model: "gemini-3.1-flash-tts-preview",
            voice: "Aoede",
            selectedProvider: "Gemini"
        )

        manager.fetchAvailableModels(baseURL: endpoint, apiKey: "gemini-key", selectedProvider: "Gemini")
        waitForCompletions(in: completions, "The Gemini models publication was reported") {
            $0.kind == .models && $0.outcome == .published
        }

        let report = completions.records.last
        XCTAssertEqual(report?.onMainThread, true, "A publication must be reported where it was published.")
        XCTAssertEqual(
            report?.listAtReport,
            ProviderSuggestions(provider: .gemini, values: ["gemini-3.1-flash-tts-preview"]),
            "A publication must be reported after its list is published."
        )
    }

    func testAPublicationExpectationIgnoresTheReplayedAndAlreadyQueuedValues() {
        // WHY: Combine replays the current list on subscription, and a publication an earlier
        // action queued can still be waiting on the main queue. Either one satisfying the
        // expectation would let a positive test pass without the action it describes having
        // published anything. Every positive metadata test is the counterweight: each fails if
        // a publication made after the expectation cannot satisfy it.
        let manager = TestNetworkFactory.makeManager()
        let list = ProviderSuggestions(provider: .openAI, values: ["tts-1"])
        manager.modelSuggestions = list
        DispatchQueue.main.async { manager.modelSuggestions = list }

        let published = expectPublication(manager.$modelSuggestions, of: list, "No publication made after the expectation")
        drainMainQueue()
        // Every candidate publication has already run, so an immediate check is not a settle.
        XCTAssertEqual(
            XCTWaiter().wait(for: [published], timeout: 0),
            .timedOut,
            "Neither the replayed list nor a publication queued before the expectation may satisfy it."
        )
    }

    func testAClosedRecorderCountsALateCompletionAndFulfilsNothing() {
        // WHY: A completion can still be reported after its test has ended, when a scope that did
        // not quiesce finishes later. Fulfilling that test's expectation then, or recording it as
        // the test's own, would let late work act on a test that is no longer running.
        let recorder = MetadataCompletionRecorder()
        let late = TTSNetworkManager.MetadataCompletion(
            kind: .models,
            token: TTSNetworkManager.MetadataRequestToken(identifier: 1, generation: 0, provider: .openAI),
            outcome: .superseded
        )
        let awaited = recorder.expectation("A completion its test stopped waiting for") { $0 == late }

        recorder.close()
        recorder.record(late)

        XCTAssertEqual(recorder.lateCompletionCount, 1)
        XCTAssertEqual(recorder.records, [])
        XCTAssertEqual(XCTWaiter().wait(for: [awaited], timeout: 0), .timedOut, "A closed recorder must fulfil nothing.")
    }
}
