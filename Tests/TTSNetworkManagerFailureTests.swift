import XCTest
import Combine
@testable import ClipboardTTSApp

final class TTSNetworkManagerFailureTests: MockURLProtocolTestCase {
    func testInvalidEndpointPublishesConfigurationFailureWithoutStartingARequest() {
        // WHY: A malformed endpoint used to print a URL (which can include credentials) and leave
        // the menu-bar user with no explanation. It must instead finish with a safe configuration
        // message before URLSession can start a request.
        let manager = TestNetworkFactory.makeManager()
        manager.updateSettings(baseURL: "not a valid endpoint", apiKey: "fake-key", model: "test", voice: "test")

        manager.streamTTS(text: "Test invalid endpoint") { _ in
            XCTFail("An invalid endpoint must not produce audio.")
        }

        XCTAssertEqual(manager.lastError, "TTS configuration is invalid. Check the API endpoint and try again.")
        XCTAssertFalse(manager.isStreaming)
    }

    func testRequestEncodingFailurePublishesPreparationError() {
        // WHY: Request-body encoding can fail before URLSession owns a task. Reporting it proves
        // that this early failure follows the same user-visible terminal state as network errors.
        let manager = TestNetworkFactory.makeManager { _ in
            throw TestRequestEncodingError.failed
        }
        manager.updateSettings(baseURL: "https://mock.api/v1/audio/speech", apiKey: "fake-key", model: "test", voice: "test")

        manager.streamTTS(text: "Test encoding failure") { _ in
            XCTFail("An unencoded request must not produce audio.")
        }

        XCTAssertEqual(manager.lastError, "Couldn't prepare the speech request. Check the settings and try again.")
        XCTAssertFalse(manager.isStreaming)
    }

    func testHTTPFailurePublishesApplicationOwnedErrorWithoutASecret() {
        // WHY: Provider error pages can echo credentials. The menu bar must use its own status
        // copy, never server-provided text that could contain the configured key.
        let manager = TestNetworkFactory.makeManager()
        let serverSecret = "customcredential123456"
        manager.updateSettings(baseURL: "https://mock.api/v1/audio/speech", apiKey: serverSecret, model: "test", voice: "test")

        MockURLProtocol.installRequestHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
            return (response, Data("Request rejected: \(serverSecret)".utf8))
        }

        assertTerminalState(of: manager, expectedError: "Speech request failed (HTTP 400).") {
            manager.streamTTS(text: "Test HTTP failure") { _ in
                XCTFail("An HTTP error response must not produce audio.")
            }
        }

            XCTAssertEqual(manager.lastError, "Speech request failed (HTTP 400).")
            XCTAssertFalse(manager.lastError?.contains(serverSecret) ?? true)
            XCTAssertFalse(manager.isStreaming)
    }

    func testAuthenticationFailurePublishesActionableAPIKeyGuidance() {
        // WHY: Authentication failure is actionable differently from a generic API rejection;
        // the user must know to check the configured key rather than their network connection.
        let manager = TestNetworkFactory.makeManager()
        manager.updateSettings(baseURL: "https://mock.api/v1/audio/speech", apiKey: "fake-key", model: "test", voice: "test")

        MockURLProtocol.installRequestHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data("Unauthorized".utf8))
        }
        assertTerminalState(
            of: manager,
            expectedError: "Authentication failed (HTTP 401). Check your API key and try again."
        ) {
            manager.streamTTS(text: "Test authentication failure") { _ in }
        }

            XCTAssertEqual(
                manager.lastError,
                "Authentication failed (HTTP 401). Check your API key and try again."
            )
            XCTAssertFalse(manager.isStreaming)
    }

    func testHTTPFailureNeverDisplaysProviderURLOrEmbeddedCredential() {
        // WHY: Heuristic redaction cannot safely recognize every credential-bearing URL. HTTP
        // errors therefore use application-owned copy regardless of a provider response body.
        let manager = TestNetworkFactory.makeManager()
        manager.updateSettings(baseURL: "https://mock.api/v1/audio/speech", apiKey: "fake-key", model: "test", voice: "test")
        let body = "https://user:opaquecredential@example.test/v1/audio/speech"

        MockURLProtocol.installRequestHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data(body.utf8))
        }

        assertTerminalState(of: manager, expectedError: "Speech request failed (HTTP 500).") {
            manager.streamTTS(text: "Test long HTTP failure") { _ in }
        }

            XCTAssertEqual(manager.lastError, "Speech request failed (HTTP 500).")
            XCTAssertFalse(manager.lastError?.contains(body) ?? true)
            XCTAssertFalse(manager.lastError?.contains("opaquecredential") ?? true)
            XCTAssertFalse(manager.isStreaming)
    }

    func testTransportFailurePublishesConnectionError() {
        // WHY: A transport failure has no provider HTTP status, so it needs distinct guidance
        // instead of being mistaken for a rejected API request.
        let manager = TestNetworkFactory.makeManager()
        manager.updateSettings(baseURL: "https://mock.api/v1/audio/speech", apiKey: "fake-key", model: "test", voice: "test")

        MockURLProtocol.installRequestHandler { _ in
            throw URLError(.notConnectedToInternet)
        }

        assertTerminalState(
            of: manager,
            expectedError: "Couldn't reach the TTS service. Check your connection and try again."
        ) {
            manager.streamTTS(text: "Test transport failure") { _ in }
        }

            XCTAssertEqual(manager.lastError, "Couldn't reach the TTS service. Check your connection and try again.")
            XCTAssertFalse(manager.isStreaming)
    }

    func testMalformedGeminiAudioPublishesProviderDecodingError() {
        // WHY: A complete Gemini event without audio must not silently look like a successful read.
        let manager = TestNetworkFactory.makeManager()
        manager.updateSettings(
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            apiKey: "fake-key",
            model: "gemini-test",
            voice: "Aoede"
        )

        MockURLProtocol.installRequestHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("data: {\"candidates\":[]}\r\n\r\n".utf8))
        }

        assertTerminalState(of: manager, expectedError: "The TTS service returned no playable audio. Please try again.") {
            manager.streamTTS(text: "Test malformed Gemini audio") { _ in
                XCTFail("Malformed Gemini audio must not be delivered.")
            }
        }

            XCTAssertEqual(manager.lastError, "The TTS service returned no playable audio. Please try again.")
            XCTAssertFalse(manager.isStreaming)
    }

    func testGeminiResponseWithOddLengthPCMDoesNotDeliverUnplayableAudio() {
        // WHY: A decodable Gemini payload can still be unusable when it contains only one byte.
        // The provider-specific decoder must enforce the same 16-bit PCM boundary as streamed audio.
        let manager = TestNetworkFactory.makeManager()
        manager.updateSettings(
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            apiKey: "fake-key",
            model: "gemini-test",
            voice: "Aoede"
        )

        MockURLProtocol.installRequestHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let payload = Data("data: {\"candidates\":[{\"content\":{\"parts\":[{\"inlineData\":{\"data\":\"AA==\"}}]}}]}\r\n\r\n".utf8)
            return (response, payload)
        }

        assertTerminalState(of: manager, expectedError: "The TTS service returned no playable audio. Please try again.") {
            manager.streamTTS(text: "Test odd-length Gemini audio") { _ in
                XCTFail("Odd-length PCM must not be delivered.")
            }
        }

            XCTAssertEqual(manager.lastError, "The TTS service returned no playable audio. Please try again.")
            XCTAssertFalse(manager.isStreaming)
    }

    func testOpenAICompatibleResponsesWithoutACompletePCMFramePublishProviderAudioError() {
        // WHY: OpenAI and Custom both request 16-bit PCM, so an empty response or one byte must
        // report the same failure instead of silently completing without playback or guidance.
        isolateAppSettingsDefaults()
        let providers = [
            (baseURL: "https://mock.api/v1/audio/speech", selectedProvider: "OpenAI"),
            (baseURL: "https://custom.api/v1/audio/speech", selectedProvider: "Custom")
        ]
        for provider in providers {
            for payload in [Data(), Data([0])] {
                let manager = TestNetworkFactory.makeManager()
                manager.updateSettings(
                    baseURL: provider.baseURL,
                    apiKey: "fake-key",
                    model: "test",
                    voice: "test",
                    selectedProvider: provider.selectedProvider
                )
                MockURLProtocol.installRequestHandler { request in
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    return (response, payload)
                }

                assertTerminalState(of: manager, expectedError: "The TTS service returned no playable audio. Please try again.") {
                    manager.streamTTS(text: "Test incomplete PCM") { _ in }
                }

                XCTAssertEqual(manager.lastError, "The TTS service returned no playable audio. Please try again.")
                XCTAssertFalse(manager.isStreaming)
            }
        }
    }

    func testNextRequestClearsPreviousFailureAndSuccessfulAudioLeavesItCleared() {
        // WHY: An old failure must not remain visible after the user retries successfully, or the
        // menu bar would claim the current request failed while its audio is actually playing.
        let manager = TestNetworkFactory.makeManager()
        manager.updateSettings(baseURL: "not a valid endpoint", apiKey: "fake-key", model: "test", voice: "test")
        manager.streamTTS(text: "Create failure") { _ in }
        XCTAssertNotNil(manager.lastError)

        manager.updateSettings(baseURL: "https://mock.api/v1/audio/speech", apiKey: "fake-key", model: "test", voice: "test")
        let audioDelivered = expectation(description: "Successful retry delivers audio")
        MockURLProtocol.installRequestHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data([0, 1]))
        }

        manager.streamTTS(text: "Retry successfully") { data in
            XCTAssertEqual(data, Data([0, 1]))
            audioDelivered.fulfill()
        }
        XCTAssertNil(manager.lastError)

        wait(for: [audioDelivered], timeout: 2.0)
        assertTerminalState(of: manager, expectedError: nil) {
            // The URL protocol has delivered audio; its completion publishes the terminal state.
        }

            XCTAssertNil(manager.lastError)
            XCTAssertFalse(manager.isStreaming)
    }

    func testStaleFailureClearCannotEraseTheLatestRequestError() {
        // WHY: Clear requests can be enqueued from background callers. Once another request has
        // started, an older queued clear must not erase the newer request's failure message.
        let manager = TestNetworkFactory.makeManager()
        manager.updateSettings(baseURL: "not a valid endpoint", apiKey: "fake-key", model: "test", voice: "test")
        manager.streamTTS(text: "First invalid attempt") { _ in }
        manager.streamTTS(text: "Second invalid attempt") { _ in }

        manager.publishFailure("Newest request failure", requestGeneration: 2)
        manager.clearLastError(requestGeneration: 1)

        XCTAssertEqual(manager.lastError, "Newest request failure")
        XCTAssertFalse(manager.isStreaming)
    }

    func testFailurePublicationDefersAReentrantReplacementRequestUntilItsStateIsComplete() {
        // WHY: @Published emits before storing a value. An observer that starts a replacement
        // request during a stale failure must run after that failure's state mutation completes.
        let manager = TestNetworkFactory.makeManager()
        manager.updateSettings(baseURL: "not a valid endpoint", apiKey: "fake-key", model: "test", voice: "test")
        manager.streamTTS(text: "Create generation one") { _ in }

        let replacementStarted = expectation(description: "Reentrant replacement starts")
        let releaseResponse = DispatchSemaphore(value: 0)
        MockURLProtocol.installRequestHandler { request in
            replacementStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 1.0)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data([0, 1]))
        }

        var didRequestReplacement = false
        let observation = manager.objectWillChange.sink {
            guard !didRequestReplacement else { return }
            didRequestReplacement = true
            manager.updateSettings(baseURL: "https://mock.api/v1/audio/speech", apiKey: "fake-key", model: "test", voice: "test")
            manager.streamTTS(text: "Generation two") { _ in }
        }
        defer { observation.cancel() }

        manager.publishFailure("Generation one failure", requestGeneration: 1)
        wait(for: [replacementStarted], timeout: 2.0)
        XCTAssertNil(manager.lastError)
        XCTAssertTrue(manager.isStreaming)

        assertTerminalState(of: manager, expectedError: nil) {
            releaseResponse.signal()
        }
    }

    func testOffMainInvalidAttemptCannotOverwriteANewerRequestState() {
        // WHY: The manager accepts calls from the Services/network lifecycle as well as the main
        // queue. An early invalid-endpoint error queued to main must not replace a newer stream's
        // truthfully active state after that newer request has started.
        let manager = TestNetworkFactory.makeManager()
        let validRequestStarted = expectation(description: "Valid replacement request started")
        let responseFinished = expectation(description: "Valid replacement response finished")
        let attemptsSubmitted = expectation(description: "Both request attempts submitted")
        let releaseResponse = DispatchSemaphore(value: 0)
        MockURLProtocol.installRequestHandler { request in
            validRequestStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 1.0)
            responseFinished.fulfill()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data([0, 1]))
        }

        DispatchQueue.global(qos: .userInitiated).async {
            manager.updateSettings(baseURL: "not a valid endpoint", apiKey: "fake-key", model: "test", voice: "test")
            manager.streamTTS(text: "Invalid attempt") { _ in }
            manager.updateSettings(baseURL: "https://mock.api/v1/audio/speech", apiKey: "fake-key", model: "test", voice: "test")
            manager.streamTTS(text: "Valid replacement") { _ in }
            attemptsSubmitted.fulfill()
        }

        wait(for: [attemptsSubmitted, validRequestStarted], timeout: 2.0)
        XCTAssertNil(manager.lastError)
        XCTAssertTrue(manager.isStreaming)

        assertTerminalState(of: manager, expectedError: nil) {
            releaseResponse.signal()
        }
        wait(for: [responseFinished], timeout: 2.0)
    }

    func testOlderEncodingCannotReplaceOrCancelANewerStreamingTask() {
        // WHY: Encoding happens before a task owns active-request state. If an older encoder
        // finishes after a newer stream starts, it must not install its task and cancel the newer one.
        let firstEncodingBegan = expectation(description: "First request begins encoding")
        let firstRequestReturned = expectation(description: "First request returns without installing")
        let secondRequestStarted = expectation(description: "Second request starts")
        let secondResponseFinished = expectation(description: "Second response finishes")
        let releaseFirstEncoding = DispatchSemaphore(value: 0)
        let releaseSecondResponse = DispatchSemaphore(value: 0)
        let invocationLock = NSLock()
        var invocationCount = 0
        let manager = TestNetworkFactory.makeManager { body in
            invocationLock.lock()
            invocationCount += 1
            let isFirstInvocation = invocationCount == 1
            invocationLock.unlock()
            if isFirstInvocation {
                firstEncodingBegan.fulfill()
                _ = releaseFirstEncoding.wait(timeout: .now() + 1.0)
            }
            return body
        }
        manager.updateSettings(baseURL: "https://mock.api/v1/audio/speech", apiKey: "fake-key", model: "test", voice: "test")

        MockURLProtocol.installRequestHandler { request in
            secondRequestStarted.fulfill()
            _ = releaseSecondResponse.wait(timeout: .now() + 1.0)
            secondResponseFinished.fulfill()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data([0, 1]))
        }

        DispatchQueue.global(qos: .userInitiated).async {
            manager.streamTTS(text: "Older request") { _ in }
            firstRequestReturned.fulfill()
        }
        wait(for: [firstEncodingBegan], timeout: 1.0)

        manager.streamTTS(text: "Newer request") { _ in }
        wait(for: [secondRequestStarted], timeout: 2.0)
        guard let newerTask = manager.activeTaskForTesting else {
            XCTFail("The newer request must own the active task before the older encoder resumes.")
            releaseFirstEncoding.signal()
            releaseSecondResponse.signal()
            return
        }

        releaseFirstEncoding.signal()
        wait(for: [firstRequestReturned], timeout: 1.0)
        XCTAssertTrue(manager.activeTaskForTesting === newerTask)
        XCTAssertTrue(manager.isStreaming)

        assertTerminalState(of: manager, expectedError: nil) {
            releaseSecondResponse.signal()
        }
        wait(for: [secondResponseFinished], timeout: 2.0)
    }
}

private enum TestRequestEncodingError: Error {
    case failed
}
