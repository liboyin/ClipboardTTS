import Combine
import XCTest
@testable import ClipboardTTSApp

final class TTSNetworkManagerMetadataSourceTests: MetadataTestCase {
    func testMismatchedMetadataSourceCannotStartRequest() {
        // WHY: An old endpoint or provider identity must not mint a current token after a switch,
        // otherwise it can publish metadata that belongs to no selected source. Each half is
        // mismatched on its own here, because Settings changes both in the same edit and a guard
        // that checked only one would still admit the other's stale call.
        let (manager, completions) = makeMetadataManager()
        let geminiEndpoint = "https://generativelanguage.googleapis.com/v1beta"
        let openAIEndpoint = "https://api.openai.com/v1/audio/speech"
        manager.updateSettings(
            baseURL: geminiEndpoint,
            apiKey: "gemini-key",
            model: "gemini-3.1-flash-tts-preview",
            voice: "Aoede",
            selectedProvider: "Gemini"
        )
        manager.modelSuggestions = ProviderSuggestions(provider: .gemini, values: ["current-model"])
        manager.voiceSuggestions = ProviderSuggestions(provider: .gemini, values: ["current-voice"])

        // No handler is installed: this scope's unhandled-request accounting fails if any of these
        // calls sends a request.
        // The selected endpoint, but the identity the user just switched away from.
        manager.fetchAvailableModels(baseURL: geminiEndpoint, selectedProvider: "OpenAI")
        manager.fetchAvailableVoices(baseURL: geminiEndpoint, selectedProvider: "OpenAI")
        // The selected identity, but the endpoint the user just switched away from.
        manager.fetchAvailableModels(baseURL: openAIEndpoint, selectedProvider: "Gemini")
        manager.fetchAvailableVoices(baseURL: openAIEndpoint, selectedProvider: "Gemini")

        // The source guard refuses each call before it mints a token, so there is no request,
        // queued publication, or completion to wait for: the refusal is already final here.
        XCTAssertNil(manager.metadataTokenForTesting(for: .models), "A mismatched source must not own model metadata state.")
        XCTAssertNil(manager.metadataTokenForTesting(for: .voices), "A mismatched source must not own voice metadata state.")
        XCTAssertEqual(completions.records, [])
        XCTAssertEqual(manager.modelSuggestions.values, ["current-model"])
        XCTAssertEqual(manager.voiceSuggestions.values, ["current-voice"])
    }

    func testAProviderOnlySwitchInvalidatesMetadataFetchedForTheSameEndpoint() throws {
        // WHY: Metadata belongs to a provider and an endpoint together, so a direct caller that
        // keeps the endpoint and changes only the provider must invalidate it exactly as an endpoint
        // change does: clear both lists and refuse whatever the old requests publish late. The
        // same-scope edit made first is the counterweight: changing the key, model, and voice leaves
        // the provider and endpoint alone, so it must invalidate nothing, and it is what attributes
        // the invalidation below to the provider rather than to any edit at all.
        let (manager, completions) = makeMetadataManager()
        let sharedEndpoint = "https://generativelanguage.googleapis.com/v1beta"
        manager.updateSettings(baseURL: sharedEndpoint, apiKey: "gemini-key", model: "gemini-3.8-flash-lite-tts",
                               voice: "Aoede", selectedProvider: "Gemini")
        let geminiModels = ProviderSuggestions(provider: .gemini, values: ["gemini-3.8-flash-lite-tts"])
        let geminiVoices = ProviderSuggestions(provider: .gemini, values: ["Aoede"])
        manager.modelSuggestions = geminiModels
        manager.voiceSuggestions = geminiVoices

        // Both publications wait for a main-queue turn, which this test does not give them yet.
        manager.fetchAvailableModels(baseURL: sharedEndpoint, selectedProvider: "Gemini")
        manager.fetchAvailableVoices(baseURL: sharedEndpoint, selectedProvider: "Gemini")
        let staleModelToken = try XCTUnwrap(manager.metadataTokenForTesting(for: .models))
        let staleVoiceToken = try XCTUnwrap(manager.metadataTokenForTesting(for: .voices))

        manager.updateSettings(baseURL: sharedEndpoint, apiKey: "gemini-replacement-key",
                               model: "gemini-3.8-flash-tts", voice: "Puck", selectedProvider: "Gemini")
        XCTAssertEqual(manager.metadataTokenForTesting(for: .models), staleModelToken,
                       "An edit within one provider and endpoint must not invalidate metadata.")
        XCTAssertEqual(manager.metadataTokenForTesting(for: .voices), staleVoiceToken)
        XCTAssertEqual(manager.modelSuggestions, geminiModels)
        XCTAssertEqual(manager.voiceSuggestions, geminiVoices)

        manager.updateSettings(baseURL: sharedEndpoint, apiKey: "openai-key", model: "gpt-realtime-2.1-mini",
                               voice: "alloy", selectedProvider: "OpenAI")
        XCTAssertNil(manager.metadataTokenForTesting(for: .models))
        XCTAssertNil(manager.metadataTokenForTesting(for: .voices))
        XCTAssertEqual(manager.modelSuggestions, .unpublished)
        XCTAssertEqual(manager.voiceSuggestions, .unpublished)

        // Deliver a second late answer for each through the same publication guard, beside the
        // publications already queued.
        manager.publishMetadataForTesting(["gemini-3.8-flash-lite-tts"], for: .models, token: staleModelToken)
        manager.publishMetadataForTesting(["Aoede"], for: .voices, token: staleVoiceToken)

        waitForCompletions(in: completions, count: 2, "Both late Gemini model publications were refused") {
            $0.kind == .models && $0.token == staleModelToken && $0.outcome == .superseded
        }
        waitForCompletions(in: completions, count: 2, "Both late Gemini voice publications were refused") {
            $0.kind == .voices && $0.token == staleVoiceToken && $0.outcome == .superseded
        }
        XCTAssertEqual(manager.modelSuggestions, .unpublished)
        XCTAssertEqual(manager.voiceSuggestions, .unpublished)
    }

    func testReentrantScopeChangeClearsMetadataAfterPublication() {
        // WHY: @Published sends synchronously before assigning its new value. A subscriber that
        // changes provider at that point must leave no stale metadata after the assignment returns.
        let manager = TestNetworkFactory.makeManager()
        manager.updateSettings(baseURL: OpenAIRealtimeSpeech.endpoint, apiKey: "openai-key",
                               model: "gpt-realtime-2.1-mini", voice: "alloy", selectedProvider: "OpenAI")
        let openAIModels = ProviderMetadataCatalog.models(for: .openAI) ?? []

        let scopeChangeObserved = expectation(description: "Reentrant scope change observed")
        let subscription = manager.$modelSuggestions.dropFirst().sink { models in
            guard models.values == openAIModels else { return }
            manager.updateSettings(
                baseURL: "https://generativelanguage.googleapis.com/v1beta",
                apiKey: "gemini-key",
                model: "gemini-3.8-flash-lite-tts",
                voice: "Aoede",
                selectedProvider: "Gemini"
            )
            scopeChangeObserved.fulfill()
        }
        defer { subscription.cancel() }

        manager.fetchAvailableModels(baseURL: OpenAIRealtimeSpeech.endpoint, selectedProvider: "OpenAI")
        wait(for: [scopeChangeObserved], timeout: 1.0)

        let staleMetadataCleared = expectation(description: "Stale metadata cleared after publication")
        DispatchQueue.main.async {
            XCTAssertEqual(manager.modelSuggestions.values, [])
            staleMetadataCleared.fulfill()
        }
        wait(for: [staleMetadataCleared], timeout: 1.0)
    }
}
