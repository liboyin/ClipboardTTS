import XCTest
@testable import ClipboardTTSApp

final class TTSNetworkManagerMetadataTests: MetadataTestCase {
    func testAModelCatalogPublishedForTheOldProviderCannotReplaceTheNewOne() throws {
        // WHY: A catalog's publication waits for a main-queue turn, so a provider switch made in
        // that window must refuse it. Otherwise OpenAI's models would replace the Gemini models the
        // user switched to, offering choices Gemini's endpoint cannot serve.
        let (manager, completions) = makeMetadataManager()
        manager.updateSettings(baseURL: OpenAIRealtimeSpeech.endpoint, apiKey: "openai-key",
                               model: "gpt-realtime-2.1-mini", voice: "alloy", selectedProvider: "OpenAI")
        manager.fetchAvailableModels(baseURL: OpenAIRealtimeSpeech.endpoint, selectedProvider: "OpenAI")
        let staleToken = try XCTUnwrap(
            manager.metadataTokenForTesting(for: .models),
            "The started model request must own model metadata state until its publication runs."
        )

        let geminiEndpoint = "https://generativelanguage.googleapis.com/v1beta"
        manager.updateSettings(baseURL: geminiEndpoint, apiKey: "gemini-key", model: "gemini-3.8-flash-lite-tts",
                               voice: "Aoede", selectedProvider: "Gemini")
        XCTAssertEqual(manager.modelSuggestions.values, [])
        let geminiModelsPublished = expectPublication(
            manager.$modelSuggestions,
            of: ProviderSuggestions(provider: .gemini, values: ["gemini-3.8-flash-lite-tts", "gemini-3.8-flash-tts"]),
            "Gemini models published"
        )
        manager.fetchAvailableModels(baseURL: geminiEndpoint, selectedProvider: "Gemini")
        wait(for: [geminiModelsPublished], timeout: 1.0)

        // The OpenAI publication was queued before the switch; deliver a second one through the
        // same production guard so both races are covered.
        manager.publishMetadataForTesting(["gpt-realtime-2.1-mini"], for: .models, token: staleToken)

        waitForCompletions(in: completions, count: 2, "Both stale OpenAI catalogs were refused") {
            $0.kind == .models && $0.token == staleToken && $0.outcome == .superseded
        }
        XCTAssertEqual(manager.modelSuggestions.values, ["gemini-3.8-flash-lite-tts", "gemini-3.8-flash-tts"])
    }

    func testAnEndpointChangeInvalidatesListsPublishedForTheOldEndpoint() throws {
        // WHY: Metadata belongs to a provider and an endpoint together. A direct caller that keeps
        // the provider and changes the endpoint must refuse the publication queued for the old one
        // and clear both lists, exactly as a provider switch does.
        let (manager, completions) = makeMetadataManager()
        manager.updateSettings(baseURL: OpenAIRealtimeSpeech.endpoint, apiKey: "openai-key",
                               model: "gpt-realtime-2.1-mini", voice: "alloy", selectedProvider: "OpenAI")
        manager.modelSuggestions = ProviderSuggestions(provider: .openAI, values: ["gpt-realtime-2.1-mini"])
        manager.fetchAvailableModels(baseURL: OpenAIRealtimeSpeech.endpoint, selectedProvider: "OpenAI")
        let staleToken = try XCTUnwrap(manager.metadataTokenForTesting(for: .models))

        manager.updateSettings(baseURL: "wss://elsewhere.example/v1/realtime", apiKey: "openai-key",
                               model: "gpt-realtime-2.1-mini", voice: "alloy", selectedProvider: "OpenAI")

        XCTAssertNil(manager.metadataTokenForTesting(for: .models))
        XCTAssertEqual(manager.modelSuggestions, .unpublished)
        waitForCompletions(in: completions, "The old endpoint's catalog was refused") {
            $0.kind == .models && $0.token == staleToken && $0.outcome == .superseded
        }
        XCTAssertEqual(manager.modelSuggestions, .unpublished)
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

    func testAProviderWithoutACatalogLeavesTheListsAloneAndReleasesItsSlot() {
        // WHY: A Custom endpoint documents no models, so its request is abandoned rather than
        // published. Abandoning must not turn the lists into an arbitrary value, and it must release
        // the slot its own token held: nothing else observes that release, so without this assertion
        // the clearing the publishing and abandoning paths share could be dropped with every other
        // gate still green.
        let (manager, completions) = makeMetadataManager()
        let endpoint = "https://custom.example/v1/audio/speech"
        manager.updateSettings(baseURL: endpoint, apiKey: "custom-key", model: "model", voice: "voice", selectedProvider: "Custom")
        manager.modelSuggestions = ProviderSuggestions(provider: .custom, values: ["known-tts-model"])

        manager.fetchAvailableModels(baseURL: endpoint, selectedProvider: "Custom")

        waitForCompletions(in: completions, "The request was abandoned") {
            $0.kind == .models && $0.outcome == .abandoned
        }
        XCTAssertEqual(manager.modelSuggestions.values, ["known-tts-model"])
        XCTAssertNil(
            manager.metadataTokenForTesting(for: .models),
            "An abandoned refresh must release the request slot its own token held."
        )
    }
}
