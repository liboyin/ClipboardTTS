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
        manager.availableModels = ["current-model"]
        manager.availableVoices = ["current-voice"]

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

        XCTAssertEqual(manager.availableModels, ["current-model"])
        XCTAssertEqual(manager.availableVoices, ["current-voice"])
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
        let subscription = manager.$availableModels.dropFirst().sink { models in
            guard models == ["stale-tts-model"] else { return }
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
            XCTAssertEqual(manager.availableModels, [])
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
