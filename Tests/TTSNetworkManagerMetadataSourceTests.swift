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
        manager.fetchAvailableModels(baseURL: geminiEndpoint, apiKey: "old-key", selectedProvider: "OpenAI")
        manager.fetchAvailableVoices(baseURL: geminiEndpoint, selectedProvider: "OpenAI")
        // The selected identity, but the endpoint the user just switched away from.
        manager.fetchAvailableModels(baseURL: openAIEndpoint, apiKey: "old-key", selectedProvider: "Gemini")
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
        // WHY: OpenAI and a Custom provider with no saved endpoint share OpenAI's speech endpoint,
        // so switching between them changes the provider alone. Metadata fetched for OpenAI is not
        // Custom's, so that switch must invalidate it exactly as an endpoint change does: cancel the
        // discovery still in flight, clear both lists, and refuse whatever the old requests publish
        // late. The same-scope edit made first is the counterweight: changing the key, model, and
        // voice leaves the provider and endpoint alone, so it must invalidate nothing, and it is what
        // attributes the invalidation below to the provider rather than to any edit at all.
        let (manager, completions) = makeMetadataManager()
        let sharedEndpoint = "https://api.openai.com/v1/audio/speech"
        manager.updateSettings(
            baseURL: sharedEndpoint,
            apiKey: "openai-key",
            model: "tts-1",
            voice: "alloy",
            selectedProvider: "OpenAI"
        )
        let openAIModels = ProviderSuggestions(provider: .openAI, values: ["tts-1"])
        let openAIVoices = ProviderSuggestions(provider: .openAI, values: ["alloy"])
        manager.modelSuggestions = openAIModels
        manager.voiceSuggestions = openAIVoices

        let modelRequestStarted = expectation(description: "The OpenAI model request started")
        let modelRequestReleased = expectation(description: "The OpenAI model request released")
        let releaseModelRequest = DispatchSemaphore(value: 0)
        defer { releaseModelRequest.signal() }
        MockURLProtocol.installRequestHandler { request in
            modelRequestStarted.fulfill()
            _ = releaseModelRequest.wait(timeout: .now() + 2.0)
            modelRequestReleased.fulfill()
            return metadataResponse(for: request, json: "{ \"data\": [{\"id\": \"stale-tts-model\"}] }")
        }

        manager.fetchAvailableModels(baseURL: sharedEndpoint, apiKey: "openai-key", selectedProvider: "OpenAI")
        wait(for: [modelRequestStarted], timeout: 2.0)
        let modelTask = try XCTUnwrap(manager.modelMetadataTaskForTesting(), "Expected a pending model request.")
        let staleModelToken = try XCTUnwrap(manager.metadataTokenForTesting(for: .models))

        manager.updateSettings(
            baseURL: sharedEndpoint,
            apiKey: "openai-replacement-key",
            model: "tts-1-hd",
            voice: "ash",
            selectedProvider: "OpenAI"
        )
        XCTAssertEqual(modelTask.state, .running, "An edit within one provider and endpoint must not cancel discovery.")
        XCTAssertEqual(manager.metadataTokenForTesting(for: .models), staleModelToken)
        XCTAssertEqual(manager.modelSuggestions, openAIModels)
        XCTAssertEqual(manager.voiceSuggestions, openAIVoices)

        // Its publication is queued for the main queue and has not run yet, so the switch below
        // must also refuse a voice catalog that is already on its way.
        manager.fetchAvailableVoices(baseURL: sharedEndpoint, selectedProvider: "OpenAI")
        let staleVoiceToken = try XCTUnwrap(manager.metadataTokenForTesting(for: .voices))

        manager.updateSettings(
            baseURL: sharedEndpoint,
            apiKey: "custom-key",
            model: "custom-model",
            voice: "custom-voice",
            selectedProvider: "Custom"
        )
        XCTAssertNotEqual(modelTask.state, .running, "A provider-only switch must cancel the pending model request.")
        XCTAssertNil(manager.metadataTokenForTesting(for: .models))
        XCTAssertNil(manager.metadataTokenForTesting(for: .voices))
        XCTAssertEqual(manager.modelSuggestions, .unpublished)
        XCTAssertEqual(manager.voiceSuggestions, .unpublished)

        // URLSession can cancel before delivering the mock response, but a production completion
        // might already be queued; deliver both late answers through the same publication guard.
        manager.publishMetadataForTesting(["stale-tts-model"], for: .models, token: staleModelToken)
        manager.publishMetadataForTesting(["alloy"], for: .voices, token: staleVoiceToken)
        releaseModelRequest.signal()
        wait(for: [modelRequestReleased], timeout: 2.0)

        // Each stale token completes twice: models through the synthetic publication and the
        // cancelled task's own completion, voices through the synthetic publication and the
        // catalog's own queued one. All four must have been refused before the lists are read.
        waitForCompletions(in: completions, count: 2, "Both late OpenAI model completions were refused") {
            $0.kind == .models && $0.token == staleModelToken && $0.outcome == .superseded
        }
        waitForCompletions(in: completions, count: 2, "Both late OpenAI voice completions were refused") {
            $0.kind == .voices && $0.token == staleVoiceToken && $0.outcome == .superseded
        }
        XCTAssertEqual(manager.modelSuggestions, .unpublished)
        XCTAssertEqual(manager.voiceSuggestions, .unpublished)
    }

    func testCleartextMetadataSourceCannotStartARequestOrPublishLists() {
        // WHY: Discovery carries the same bearer key as speech, so an endpoint the speech path
        // refuses must not leak that key through Settings instead. No handler is installed: this
        // scope's unhandled-request accounting fails if a request is created.
        //
        // Settings cannot produce this configuration today, because the only discovery request it
        // makes uses OpenAI's fixed HTTPS endpoint. The guard is kept, and exercised here, as
        // defense in depth for a later caller that derives the discovery URL from a saved value.
        let (manager, completions) = makeMetadataManager()
        let endpoint = "http://custom-metadata.example.com/v1/audio/speech"
        manager.updateSettings(
            baseURL: endpoint,
            apiKey: "cleartext-metadata-key",
            model: "custom-model",
            voice: "custom-voice",
            selectedProvider: "Custom"
        )

        manager.fetchAvailableModels(baseURL: endpoint, apiKey: "cleartext-metadata-key", selectedProvider: "Custom")

        // The transport refusal is decided before any task exists, so the request is abandoned
        // before the call returns and nothing is left queued that could still publish a list.
        XCTAssertEqual(completions.records.map(\.completion.outcome), [.abandoned])
        XCTAssertEqual(manager.modelSuggestions.values, [])
    }

    func testLoopbackMetadataSourceStillDiscoversModels() {
        // WHY: This is the over-restriction counterweight to the refusal above. If loopback HTTP
        // were refused too, the transport rule would silently deny discovery to the one endpoint
        // kind that legitimately cannot serve HTTPS. It shares that test's reachability note.
        let manager = TestNetworkFactory.makeManager()
        let endpoint = "http://127.0.0.1:8080/v1/audio/speech"
        manager.updateSettings(
            baseURL: endpoint,
            apiKey: "loopback-metadata-key",
            model: "local-model",
            voice: "local-voice",
            selectedProvider: "Custom"
        )

        MockURLProtocol.installRequestHandler { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer loopback-metadata-key")
            XCTAssertEqual(request.url?.path, "/v1/models")
            return sourceTestResponse(for: request, json: "{ \"data\": [{\"id\": \"local-tts-model\"}] }")
        }

        let modelsPublished = expectation(description: "Loopback models published")
        let observation = manager.$modelSuggestions.dropFirst().sink { models in
            guard models.values == ["local-tts-model"] else { return }
            modelsPublished.fulfill()
        }
        defer { observation.cancel() }

        manager.fetchAvailableModels(baseURL: endpoint, apiKey: "loopback-metadata-key", selectedProvider: "Custom")
        wait(for: [modelsPublished], timeout: 2.0)
    }

    func testReentrantScopeChangeClearsMetadataAfterPublication() {
        // WHY: @Published sends synchronously before assigning its new value. A subscriber that
        // changes provider at that point must leave no stale metadata after the assignment returns.
        let manager = TestNetworkFactory.makeManager()
        let endpoint = "https://api.openai.com/v1/audio/speech"
        manager.updateSettings(
            baseURL: endpoint,
            apiKey: "openai-key",
            model: "tts-1",
            voice: "alloy",
            selectedProvider: "OpenAI"
        )

        let scopeChangeObserved = expectation(description: "Reentrant scope change observed")
        let subscription = manager.$modelSuggestions.dropFirst().sink { models in
            guard models.values == ["stale-tts-model"] else { return }
            manager.updateSettings(
                baseURL: "https://generativelanguage.googleapis.com/v1beta",
                apiKey: "gemini-key",
                model: "gemini-3.1-flash-tts-preview",
                voice: "Aoede",
                selectedProvider: "Gemini"
            )
            scopeChangeObserved.fulfill()
        }
        defer { subscription.cancel() }

        MockURLProtocol.installRequestHandler { request in
            sourceTestResponse(for: request, json: "{ \"data\": [{\"id\": \"stale-tts-model\"}] }")
        }
        manager.fetchAvailableModels(baseURL: endpoint, apiKey: "openai-key", selectedProvider: "OpenAI")
        wait(for: [scopeChangeObserved], timeout: 1.0)

        let staleMetadataCleared = expectation(description: "Stale metadata cleared after publication")
        DispatchQueue.main.async {
            XCTAssertEqual(manager.modelSuggestions.values, [])
            staleMetadataCleared.fulfill()
        }
        wait(for: [staleMetadataCleared], timeout: 1.0)
    }
}

private func sourceTestResponse(for request: URLRequest, json: String) -> (HTTPURLResponse, Data?) {
    guard let url = request.url,
          let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
        return (HTTPURLResponse(), Data())
    }
    return (response, Data(json.utf8))
}
