import Combine
import XCTest
@testable import ClipboardTTSApp

final class TTSNetworkManagerMetadataSourceTests: MockURLProtocolTestCase {
    func testMismatchedMetadataSourceCannotStartRequest() {
        // WHY: An old endpoint or provider identity must not mint a current token after a switch,
        // otherwise it can publish metadata that belongs to no selected source.
        let manager = TestNetworkFactory.makeManager()
        let currentEndpoint = "https://custom-current.example/v1/audio/speech"
        manager.updateSettings(
            baseURL: currentEndpoint,
            apiKey: "current-key",
            model: "model-current",
            voice: "voice-current",
            selectedProvider: "Custom"
        )
        manager.modelSuggestions = ProviderSuggestions(provider: "Custom", values: ["current-model"])
        manager.voiceSuggestions = ProviderSuggestions(provider: "Custom", values: ["current-voice"])

        let staleRequestStarted = expectation(description: "Mismatched metadata request must not start")
        staleRequestStarted.isInverted = true
        MockURLProtocol.installRequestHandler { request in
            staleRequestStarted.fulfill()
            return sourceTestResponse(for: request, json: "{ \"data\": [] }")
        }

        manager.fetchAvailableModels(
            baseURL: "https://custom-old.example/v1/audio/speech",
            apiKey: "old-key",
            selectedProvider: "Custom"
        )
        manager.fetchAvailableVoices(
            baseURL: "https://custom-old.example/v1/audio/speech",
            apiKey: "old-key",
            selectedProvider: "Custom"
        )
        manager.fetchAvailableModels(
            baseURL: currentEndpoint,
            apiKey: "current-key",
            selectedProvider: "OpenAI"
        )
        manager.fetchAvailableVoices(
            baseURL: currentEndpoint,
            apiKey: "current-key",
            selectedProvider: "OpenAI"
        )
        wait(for: [staleRequestStarted], timeout: 0.2)

        XCTAssertEqual(manager.modelSuggestions.values, ["current-model"])
        XCTAssertEqual(manager.voiceSuggestions.values, ["current-voice"])
    }

    func testCleartextMetadataSourceCannotStartARequestOrPublishLists() {
        // WHY: Discovery carries the same bearer key as speech, so an endpoint the speech path
        // refuses must not leak that key through Settings or the menu instead. No handler is
        // installed: this scope's unhandled-request accounting fails if a request is created.
        let manager = TestNetworkFactory.makeManager()
        let endpoint = "http://custom-metadata.example.com/v1/audio/speech"
        manager.updateSettings(
            baseURL: endpoint,
            apiKey: "cleartext-metadata-key",
            model: "custom-model",
            voice: "custom-voice",
            selectedProvider: "Custom"
        )

        manager.fetchAvailableModels(baseURL: endpoint, apiKey: "cleartext-metadata-key", selectedProvider: "Custom")
        manager.fetchAvailableVoices(baseURL: endpoint, apiKey: "cleartext-metadata-key", selectedProvider: "Custom")

        let publicationWindowClosed = expectation(description: "Any metadata publication has run")
        DispatchQueue.main.async { publicationWindowClosed.fulfill() }
        wait(for: [publicationWindowClosed], timeout: 1.0)
        XCTAssertEqual(manager.modelSuggestions.values, [])
        XCTAssertEqual(manager.voiceSuggestions.values, [])
    }

    func testLoopbackMetadataSourceStillDiscoversModelsAndVoices() {
        // WHY: The transport rule must not cost a local engine its discovery. If loopback HTTP were
        // over-restricted here, Settings would silently offer no models or voices for the one
        // endpoint kind that legitimately cannot serve HTTPS.
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
            guard request.url?.path == "/v1/models" else {
                return sourceTestResponse(for: request, json: "{ \"voices\": [\"local-voice\"] }")
            }
            return sourceTestResponse(for: request, json: "{ \"data\": [{\"id\": \"local-tts-model\"}] }")
        }

        let modelsPublished = expectation(description: "Loopback models published")
        let voicesPublished = expectation(description: "Loopback voices published")
        let observations = [
            manager.$modelSuggestions.dropFirst().sink { models in
                guard models.values == ["local-tts-model"] else { return }
                modelsPublished.fulfill()
            },
            manager.$voiceSuggestions.dropFirst().sink { voices in
                guard voices.values == ["local-voice"] else { return }
                voicesPublished.fulfill()
            }
        ]
        defer { observations.forEach { $0.cancel() } }

        manager.fetchAvailableModels(baseURL: endpoint, apiKey: "loopback-metadata-key", selectedProvider: "Custom")
        manager.fetchAvailableVoices(baseURL: endpoint, apiKey: "loopback-metadata-key", selectedProvider: "Custom")
        wait(for: [modelsPublished, voicesPublished], timeout: 2.0)
    }

    func testReentrantScopeChangeClearsMetadataAfterPublication() {
        // WHY: @Published sends synchronously before assigning its new value. A subscriber that
        // changes provider at that point must leave no stale metadata after the assignment returns.
        let manager = TestNetworkFactory.makeManager()
        let endpoint = "https://custom.example/v1/audio/speech"
        manager.updateSettings(
            baseURL: endpoint,
            apiKey: "custom-key",
            model: "custom-model",
            voice: "custom-voice",
            selectedProvider: "Custom"
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
        manager.fetchAvailableModels(baseURL: endpoint, apiKey: "custom-key", selectedProvider: "Custom")
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
