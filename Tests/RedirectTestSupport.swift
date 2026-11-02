import XCTest
@testable import ClipboardTTSApp

// The fixtures the two redirect suites share. They live here rather than beside one suite because
// both halves of the redirect contract — where a started request may go, and what it carries when
// it goes — are exercised against the same tasks: a speech request whose response is withheld, so
// its task stays alive for the delegate call under test, and a Realtime handshake task that is not
// the active data task.
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

    /// Builds an OpenAI Realtime handshake task on the manager's own session without starting it.
    ///
    /// URLSession consults the redirect delegate for every task the session owns, and a Realtime
    /// handshake is never the active data task, because its request context carries no data-task
    /// identifier. The task is never resumed, so the delegate call under test is the only thing that
    /// happens to it and nothing can leave the machine.
    func makeUnstartedRealtimeHandshake(on manager: TTSNetworkManager) -> URLSessionWebSocketTask {
        var request = URLRequest(url: OpenAIRealtimeSpeech.url(model: "gpt-realtime-2.1-mini")!)
        request.setValue("Bearer test-openai-api-key", forHTTPHeaderField: "Authorization")
        return manager.session.webSocketTask(with: request)
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
