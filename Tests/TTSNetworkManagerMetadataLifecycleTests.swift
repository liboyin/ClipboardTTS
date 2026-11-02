import XCTest
@testable import ClipboardTTSApp

final class TTSNetworkManagerMetadataLifecycleTests: MetadataTestCase {
    func testOneSettingsRefreshPublishesBothTheModelListAndTheVoiceCatalog() {
        // WHY: `syncSettings` asks for models and then voices in a single refresh, before either
        // publication has run. Both go through the same guard, so one that did not keep the two kinds
        // apart would let the voice request replace the model request and leave the model picker empty.
        let (manager, completions) = makeMetadataManager()
        manager.updateSettings(baseURL: OpenAIRealtimeSpeech.endpoint, apiKey: "openai-key",
                               model: "gpt-realtime-2.1-mini", voice: "alloy", selectedProvider: "OpenAI")
        let modelsPublished = expectPublication(
            manager.$modelSuggestions,
            of: ProviderSuggestions(provider: .openAI, values: ProviderMetadataCatalog.models(for: .openAI) ?? []),
            "The model list published"
        )
        let voicesPublished = expectPublication(
            manager.$voiceSuggestions,
            of: ProviderSuggestions(provider: .openAI, values: ProviderMetadataCatalog.voices(for: .openAI) ?? []),
            "The voice catalog published"
        )

        // The order `SettingsView.syncSettings` uses, with no main-queue turn between the two.
        manager.fetchAvailableModels(baseURL: OpenAIRealtimeSpeech.endpoint, selectedProvider: "OpenAI")
        manager.fetchAvailableVoices(baseURL: OpenAIRealtimeSpeech.endpoint, selectedProvider: "OpenAI")

        wait(for: [modelsPublished, voicesPublished], timeout: 2.0)
        waitForCompletions(in: completions, count: 2, "Both requests published") { $0.outcome == .published }
    }

    func testAnAbandonedModelRequestCannotClearTheRequestThatReplacedIt() {
        // WHY: An abandoning completion and a publishing one clear the same slot, so the abandoning
        // half must check the token for the same reason the publishing half does. By the time a
        // request reports itself abandoned, a later refresh for the same source may already own the
        // model slot. Clearing without matching the token would discard the live request, and the
        // replacement's own publication would then find nothing to match and publish nothing,
        // leaving the Settings model picker empty with no error anywhere to explain it.
        let manager = TestNetworkFactory.makeManager()
        let endpoint = "https://generativelanguage.googleapis.com/v1beta"
        manager.updateSettings(baseURL: endpoint, apiKey: "gemini-key", model: "gemini-3.8-flash-lite-tts",
                               voice: "Aoede", selectedProvider: "Gemini")

        // Each catalog publication waits for a main-queue turn, so both requests are current in turn
        // before either publishes.
        manager.fetchAvailableModels(baseURL: endpoint, selectedProvider: "Gemini")
        guard let abandonedToken = manager.metadataTokenForTesting(for: .models) else {
            XCTFail("Expected the first refresh to own model metadata state.")
            return
        }
        let replacementPublished = expectPublication(
            manager.$modelSuggestions,
            of: ProviderSuggestions(provider: .gemini, values: ProviderMetadataCatalog.models(for: .gemini) ?? []),
            "The replacing refresh published its models"
        )
        manager.fetchAvailableModels(baseURL: endpoint, selectedProvider: "Gemini")
        guard let replacementToken = manager.metadataTokenForTesting(for: .models) else {
            XCTFail("Expected the replacing refresh to own model metadata state.")
            return
        }
        XCTAssertNotEqual(abandonedToken, replacementToken)

        // Deliver the first request's abandonment through the same guard the production abandonment
        // path calls, while the replacement still owns the slot.
        manager.finishMetadataRequestForTesting(for: .models, token: abandonedToken)
        XCTAssertEqual(
            manager.metadataTokenForTesting(for: .models),
            replacementToken,
            "An abandoned refresh must clear only its own request, never the one that replaced it."
        )
        wait(for: [replacementPublished], timeout: 2.0)
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

        manager.fetchAvailableModels(baseURL: endpoint, selectedProvider: "Gemini")
        waitForCompletions(in: completions, "The Gemini models publication was reported") {
            $0.kind == .models && $0.outcome == .published
        }

        let report = completions.records.last
        XCTAssertEqual(report?.onMainThread, true, "A publication must be reported where it was published.")
        XCTAssertEqual(
            report?.listAtReport,
            ProviderSuggestions(provider: .gemini, values: ["gemini-3.8-flash-lite-tts", "gemini-3.8-flash-tts"]),
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
