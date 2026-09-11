import XCTest
@testable import ClipboardTTSApp

// The fixtures the two redirect suites share. They live here rather than beside one suite because
// both halves of the redirect contract — where a started request may go, and what it carries when
// it goes — are exercised against the same started requests: a speech request and a model-discovery
// request whose responses are withheld, so their tasks stay alive for the delegate call under test.
extension MockURLProtocolTestCase {
    /// Returns a manager whose future requests use one protected Custom endpoint.
    func makeCustomManager() -> TTSNetworkManager {
        let manager = TestNetworkFactory.makeManager()
        manager.updateSettings(
            baseURL: "https://custom.api/v1/audio/speech",
            apiKey: "test-custom-api-key",
            model: "test-model",
            voice: "test-voice",
            selectedProvider: "Custom"
        )
        return manager
    }

    /// Returns a manager whose future requests use Gemini's own endpoint and key header.
    func makeGeminiManager() -> TTSNetworkManager {
        let manager = TestNetworkFactory.makeManager()
        manager.updateSettings(
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            apiKey: "test-gemini-api-key",
            model: "test-model",
            voice: "test-voice",
            selectedProvider: "Gemini"
        )
        return manager
    }

    /// Starts a speech request whose response is withheld, so its task stays active for the test.
    func startBlockedRequest(on manager: TTSNetworkManager,
                             releasedBy releaseResponse: DispatchSemaphore,
                             dataHandler: @escaping @Sendable (Data) -> Void) -> URLSessionDataTask? {
        let requestStarted = expectation(description: "The speech request starts")
        MockURLProtocol.installRequestHandler { request in
            requestStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 1.0)
            let response = HTTPURLResponse(url: request.url!, statusCode: 307, httpVersion: nil, headerFields: nil)!
            return (response, nil)
        }
        manager.streamTTS(text: "Speak through a redirecting endpoint", dataHandler: dataHandler)
        wait(for: [requestStarted], timeout: 2.0)
        guard let task = manager.activeTaskForTesting else {
            XCTFail("The started request must own the active task.")
            releaseResponse.signal()
            return nil
        }
        return task
    }

    /// Starts a model-discovery request whose response is withheld, so its task stays alive.
    func startBlockedDiscoveryRequest(on manager: TTSNetworkManager,
                                      releasedBy releaseResponse: DispatchSemaphore) -> URLSessionDataTask? {
        let requestStarted = expectation(description: "The discovery request starts")
        MockURLProtocol.installRequestHandler { request in
            requestStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 1.0)
            let response = HTTPURLResponse(url: request.url!, statusCode: 307, httpVersion: nil, headerFields: nil)!
            return (response, nil)
        }
        manager.fetchAvailableModels(
            baseURL: "https://custom.api/v1/audio/speech",
            apiKey: "test-custom-api-key",
            selectedProvider: "Custom"
        )
        wait(for: [requestStarted], timeout: 2.0)
        guard let task = manager.modelMetadataTaskForTesting() else {
            XCTFail("The started discovery request must own a metadata task.")
            releaseResponse.signal()
            return nil
        }
        return task
    }

    /// Builds the redirect response a provider would send for a task's own endpoint.
    func redirectResponse(for task: URLSessionTask) -> HTTPURLResponse {
        let url = task.originalRequest?.url ?? URL(string: "https://custom.api/v1/audio/speech")!
        return HTTPURLResponse(url: url, statusCode: 307, httpVersion: nil, headerFields: nil)!
    }

    /// Builds the redirect request URLSession hands the delegate, in the shape it arrives in.
    ///
    /// A 307 replays the method and content headers, and CFNetwork has already removed
    /// `Authorization` by this point, so no test builds one carrying it. `carrying` adds a header
    /// the response put there rather than the app.
    func redirectRequest(to target: String, carrying extraHeaders: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: URL(string: target)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return request
    }
}
