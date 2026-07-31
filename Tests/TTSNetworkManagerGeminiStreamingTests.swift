import XCTest
@testable import ClipboardTTSApp

final class TTSNetworkManagerGeminiStreamingTests: MockURLProtocolTestCase {
    func testGeminiDeliversASplitCRLFEventBeforeTaskCompletion() {
        // WHY: URLSession is free to split an SSE event at any byte. Waiting for completion would
        // erase the latency benefit that makes Gemini usable for the two-second playback target.
        let manager = TestNetworkFactory.makeManager()
        configureGemini(manager)
        let requestStarted = expectation(description: "Gemini request starts")
        let releaseResponse = DispatchSemaphore(value: 0)
        MockURLProtocol.installRequestHandler { request in
            requestStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 1.0)
            return (self.successResponse(for: request), nil)
        }

        let expectedAudio = Data([0, 1, 2, 3])
        let audioDelivered = expectation(description: "Complete split event delivers audio")
        let task = startGeminiRequest(manager, requestStarted: requestStarted) { data in
            XCTAssertEqual(data, expectedAudio)
            XCTAssertTrue(manager.isStreaming, "Gemini audio must arrive before task completion.")
            audioDelivered.fulfill()
        }
        defer { releaseResponse.signal() }

        receive(manager, response: successResponse(for: task), for: task)
        let event = sseEvent(audio: expectedAudio, lineEnding: "\r\n")
        manager.urlSession(manager.session, dataTask: task, didReceive: event.prefix(7))
        manager.urlSession(manager.session, dataTask: task, didReceive: event.dropFirst(7).prefix(19))
        manager.urlSession(manager.session, dataTask: task, didReceive: event.dropFirst(26))
        wait(for: [audioDelivered], timeout: 1.0)

        assertTerminalState(of: manager, expectedError: nil) {
            manager.urlSession(manager.session, task: task, didCompleteWithError: nil)
        }
    }

    func testGeminiDeliversMultipleEventsAcrossAwkwardBoundaries() {
        // WHY: Complete base64 payloads may share a callback or have their padding split from the
        // rest of an SSE event; decoding each callback independently would drop valid audio.
        let manager = TestNetworkFactory.makeManager()
        configureGemini(manager)
        let requestStarted = expectation(description: "Gemini request starts")
        let releaseResponse = DispatchSemaphore(value: 0)
        MockURLProtocol.installRequestHandler { request in
            requestStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 1.0)
            return (self.successResponse(for: request), nil)
        }

        let firstAudio = Data([0, 1])
        let secondAudio = Data([2, 3])
        let allAudioDelivered = expectation(description: "Both complete events deliver audio")
        var delivered: [Data] = []
        let task = startGeminiRequest(manager, requestStarted: requestStarted) { data in
            delivered.append(data)
            if delivered.count == 2 {
                allAudioDelivered.fulfill()
            }
        }
        defer { releaseResponse.signal() }

        receive(manager, response: successResponse(for: task), for: task)
        let events = sseEvent(audio: firstAudio, lineEnding: "\n") + sseEvent(audio: secondAudio, lineEnding: "\r\n")
        let paddingOffset = events.firstIndex(of: UInt8(ascii: "="))!
        manager.urlSession(manager.session, dataTask: task, didReceive: events.prefix(paddingOffset))
        manager.urlSession(manager.session, dataTask: task, didReceive: events.dropFirst(paddingOffset).prefix(2))
        manager.urlSession(manager.session, dataTask: task, didReceive: events.dropFirst(paddingOffset + 2))
        wait(for: [allAudioDelivered], timeout: 1.0)
        XCTAssertEqual(delivered, [firstAudio, secondAudio])

        assertTerminalState(of: manager, expectedError: nil) {
            manager.urlSession(manager.session, task: task, didCompleteWithError: nil)
        }
    }

    func testGeminiEOFWithTrailingIncompleteEventFailsAfterDeliveringPriorAudio() {
        // WHY: A graceful HTTP completion must not silently accept an unterminated event after
        // playback starts; parsing it would risk base64 corruption, while discarding it loses a
        // malformed provider response that should reach the established error model.
        let manager = TestNetworkFactory.makeManager()
        configureGemini(manager)
        let requestStarted = expectation(description: "Gemini request starts")
        let releaseResponse = DispatchSemaphore(value: 0)
        MockURLProtocol.installRequestHandler { request in
            requestStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 1.0)
            return (self.successResponse(for: request), nil)
        }

        let audioDelivered = expectation(description: "Complete leading event delivers audio")
        let task = startGeminiRequest(manager, requestStarted: requestStarted) { _ in
            audioDelivered.fulfill()
        }
        defer { releaseResponse.signal() }

        receive(manager, response: successResponse(for: task), for: task)
        manager.urlSession(manager.session, dataTask: task, didReceive: sseEvent(audio: Data([0, 1]), lineEnding: "\n"))
        wait(for: [audioDelivered], timeout: 1.0)
        manager.urlSession(manager.session, dataTask: task, didReceive: Data("data: {\"candidates\":".utf8))

        assertTerminalState(of: manager, expectedError: "The TTS service returned no playable audio. Please try again.") {
            manager.urlSession(manager.session, task: task, didCompleteWithError: nil)
        }
    }

    func testGeminiMalformedEventPublishesProviderAudioFailureWithoutDelivery() {
        // WHY: A complete but invalid event must fail the active request rather than passing bytes
        // to the PCM player or waiting indefinitely for a task that may keep its SSE connection open.
        assertGeminiEventFailure(event: Data("data: not-json\r\n\r\n".utf8))
    }

    func testGeminiMissingAudioAndProviderErrorEventsPublishProviderAudioFailure() {
        // WHY: A successful HTTP response still cannot start playback when its complete stream
        // never yields audio, and provider-controlled detail must not become a menu-bar error.
        assertGeminiEventFailure(event: Data("data: {\"error\":{\"message\":\"provider detail\"}}\r\n\r\n".utf8))
        assertGeminiNoAudioAtCompletion(event: Data("data: {\"candidates\":[]}\r\n\r\n".utf8))
    }

    func testGeminiIgnoresValidMetadataAfterAudio() {
        // WHY: Gemini may send complete non-audio metadata events after playable audio. Treating
        // those as malformed would cancel speech that has already started.
        let manager = TestNetworkFactory.makeManager()
        configureGemini(manager)
        let requestStarted = expectation(description: "Gemini request starts")
        let releaseResponse = DispatchSemaphore(value: 0)
        MockURLProtocol.installRequestHandler { request in
            requestStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 1.0)
            return (self.successResponse(for: request), nil)
        }

        let audioDelivered = expectation(description: "Audio event delivers before metadata")
        let task = startGeminiRequest(manager, requestStarted: requestStarted) { _ in
            audioDelivered.fulfill()
        }
        defer { releaseResponse.signal() }

        receive(manager, response: successResponse(for: task), for: task)
        manager.urlSession(manager.session, dataTask: task, didReceive: sseEvent(audio: Data([0, 1]), lineEnding: "\n"))
        wait(for: [audioDelivered], timeout: 1.0)
        manager.urlSession(manager.session, dataTask: task, didReceive: Data("data: {\"usageMetadata\":{}}\n\n".utf8))

        assertTerminalState(of: manager, expectedError: nil) {
            manager.urlSession(manager.session, task: task, didCompleteWithError: nil)
        }
    }

    func testGeminiMalformedCandidateAfterAudioPublishesProviderFailure() {
        // WHY: A present response field with the wrong type is not metadata. Ignoring it after
        // playback starts would report a corrupt provider stream as a successful read.
        let manager = TestNetworkFactory.makeManager()
        configureGemini(manager)
        let requestStarted = expectation(description: "Gemini request starts")
        let releaseResponse = DispatchSemaphore(value: 0)
        MockURLProtocol.installRequestHandler { request in
            requestStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 1.0)
            return (self.successResponse(for: request), nil)
        }

        let audioDelivered = expectation(description: "Leading audio event delivers")
        let task = startGeminiRequest(manager, requestStarted: requestStarted) { _ in
            audioDelivered.fulfill()
        }
        defer { releaseResponse.signal() }

        receive(manager, response: successResponse(for: task), for: task)
        manager.urlSession(manager.session, dataTask: task, didReceive: sseEvent(audio: Data([0, 1]), lineEnding: "\n"))
        wait(for: [audioDelivered], timeout: 1.0)
        manager.urlSession(manager.session, dataTask: task, didReceive: Data("data: {\"candidates\":{}}\n\n".utf8))

        assertTerminalState(of: manager, expectedError: "The TTS service returned no playable audio. Please try again.") {}
        assertAfterMockQuiescence {
            XCTAssertEqual(manager.lastError, "The TTS service returned no playable audio. Please try again.")
            XCTAssertFalse(manager.isStreaming)
        }
    }

    func testGeminiHTTPErrorStreamPublishesHTTPFailureWithoutParsingItsEvents() {
        // WHY: Error responses can still be SSE-shaped. Their body is untrusted diagnostic data,
        // not audio, so the established HTTP contract must win over event parsing.
        let manager = TestNetworkFactory.makeManager()
        configureGemini(manager)
        let requestStarted = expectation(description: "Gemini request starts")
        let releaseResponse = DispatchSemaphore(value: 0)
        MockURLProtocol.installRequestHandler { request in
            requestStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 1.0)
            return (self.successResponse(for: request), nil)
        }
        let task = startGeminiRequest(manager, requestStarted: requestStarted) { _ in
            XCTFail("An HTTP error stream must not deliver audio.")
        }
        defer { releaseResponse.signal() }

        let forbiddenResponse = HTTPURLResponse(
            url: task.currentRequest!.url!,
            statusCode: 403,
            httpVersion: nil,
            headerFields: nil
        )!
        receive(manager, response: forbiddenResponse, for: task)
        manager.urlSession(manager.session, dataTask: task, didReceive: Data("data: {\"error\":{}}\r\n\r\n".utf8))
        assertTerminalState(of: manager, expectedError: "Authentication failed (HTTP 403). Check your API key and try again.") {
            manager.urlSession(manager.session, task: task, didCompleteWithError: nil)
        }
    }

    func testGeminiCancellationDropsAnIncompleteEvent() {
        // WHY: Cancelling while an SSE line is incomplete must discard its parser state, so a late
        // suffix from the cancelled URL task cannot resume audio after the user cleared the buffer.
        let manager = TestNetworkFactory.makeManager()
        configureGemini(manager)
        let requestStarted = expectation(description: "Gemini request starts")
        let releaseResponse = DispatchSemaphore(value: 0)
        MockURLProtocol.installRequestHandler { request in
            requestStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 1.0)
            return (self.successResponse(for: request), nil)
        }
        let task = startGeminiRequest(manager, requestStarted: requestStarted) { _ in
            XCTFail("Cancelled Gemini events must not deliver audio.")
        }
        defer { releaseResponse.signal() }

        receive(manager, response: successResponse(for: task), for: task)
        let event = sseEvent(audio: Data([0, 1]), lineEnding: "\r\n")
        manager.urlSession(manager.session, dataTask: task, didReceive: event.prefix(event.count - 3))
        manager.stopStreaming()
        manager.urlSession(manager.session, dataTask: task, didReceive: event.suffix(3))
        XCTAssertFalse(manager.isStreaming)
    }

    private func assertGeminiEventFailure(event: Data) {
        let manager = TestNetworkFactory.makeManager()
        configureGemini(manager)
        let requestStarted = expectation(description: "Gemini request starts")
        let releaseResponse = DispatchSemaphore(value: 0)
        MockURLProtocol.installRequestHandler { request in
            requestStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 1.0)
            return (self.successResponse(for: request), nil)
        }
        let task = startGeminiRequest(manager, requestStarted: requestStarted) { _ in
            XCTFail("Invalid Gemini events must not deliver audio.")
        }
        defer { releaseResponse.signal() }

        receive(manager, response: successResponse(for: task), for: task)
        assertTerminalState(of: manager, expectedError: "The TTS service returned no playable audio. Please try again.") {
            manager.urlSession(manager.session, dataTask: task, didReceive: event)
        }
        assertAfterMockQuiescence {
            XCTAssertEqual(manager.lastError, "The TTS service returned no playable audio. Please try again.")
            XCTAssertFalse(manager.isStreaming)
        }
    }

    private func assertGeminiNoAudioAtCompletion(event: Data) {
        let manager = TestNetworkFactory.makeManager()
        configureGemini(manager)
        let requestStarted = expectation(description: "Gemini request starts")
        let releaseResponse = DispatchSemaphore(value: 0)
        MockURLProtocol.installRequestHandler { request in
            requestStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 1.0)
            return (self.successResponse(for: request), nil)
        }
        let task = startGeminiRequest(manager, requestStarted: requestStarted) { _ in
            XCTFail("A Gemini stream without audio must not deliver data.")
        }
        defer { releaseResponse.signal() }

        receive(manager, response: successResponse(for: task), for: task)
        manager.urlSession(manager.session, dataTask: task, didReceive: event)
        assertTerminalState(of: manager, expectedError: "The TTS service returned no playable audio. Please try again.") {
            manager.urlSession(manager.session, task: task, didCompleteWithError: nil)
        }
    }

    private func configureGemini(_ manager: TTSNetworkManager) {
        manager.updateSettings(
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            apiKey: "fake-gemini-key",
            model: "gemini-3.1-flash-tts-preview",
            voice: "Aoede",
            selectedProvider: "Gemini"
        )
    }

    private func startGeminiRequest(_ manager: TTSNetworkManager,
                                    requestStarted: XCTestExpectation,
                                    dataHandler: @escaping (Data) -> Void) -> URLSessionDataTask {
        manager.streamTTS(text: "Gemini streaming test", dataHandler: dataHandler)
        wait(for: [requestStarted], timeout: 1.0)
        guard let task = manager.activeTaskForTesting else {
            XCTFail("Expected streamTTS to retain its Gemini task.")
            fatalError("Test cannot drive a missing Gemini task.")
        }
        return task
    }

    private func receive(_ manager: TTSNetworkManager,
                         response: HTTPURLResponse,
                         for task: URLSessionDataTask) {
        manager.urlSession(manager.session, dataTask: task, didReceive: response) { disposition in
            XCTAssertEqual(disposition, .allow)
        }
    }

    private func successResponse(for request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }

    private func successResponse(for task: URLSessionDataTask) -> HTTPURLResponse {
        HTTPURLResponse(url: task.currentRequest!.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }

    private func sseEvent(audio: Data, lineEnding: String) -> Data {
        let prefix = "data: {\"candidates\":[{\"content\":{\"parts\":[{\"inlineData\":{\"data\":\""
        let suffix = "\"}}]}}]}"
        return Data("\(prefix)\(audio.base64EncodedString())\(suffix)\(lineEnding)\(lineEnding)".utf8)
    }
}
