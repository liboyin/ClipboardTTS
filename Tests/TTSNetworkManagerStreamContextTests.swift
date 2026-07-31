import XCTest
@testable import ClipboardTTSApp

final class TTSNetworkManagerStreamContextTests: MockURLProtocolTestCase {
    func testOpenAIHandlerCanStopStreamingWithoutReceivingLaterData() {
        // WHY: Audio handlers may stop playback synchronously. They must run after stateQueue is
        // released, otherwise stopStreaming recursively enters the same serial queue and hangs.
        let manager = TestNetworkFactory.makeManager()
        manager.updateSettings(baseURL: "https://mock.api/v1/audio/speech", apiKey: "test", model: "test", voice: "test")

        let handlerStoppedStream = expectation(description: "Re-entrant handler stopped the stream")
        let requestStarted = expectation(description: "Request context is active")
        let allowRequestCompletion = DispatchSemaphore(value: 0)
        let deliveryLock = NSLock()
        let taskLock = NSLock()
        let mockSession = TestNetworkFactory.makeSession()
        var deliveryCount = 0
        var taskForHandler: URLSessionDataTask?
        MockURLProtocol.installRequestHandler { request in
            requestStarted.fulfill()
            _ = allowRequestCompletion.wait(timeout: .now() + 1.0)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        manager.streamTTS(text: "Stop from handler") { _ in
            deliveryLock.lock()
            deliveryCount += 1
            let isFirstDelivery = deliveryCount == 1
            deliveryLock.unlock()

            guard isFirstDelivery else { return }
            manager.stopStreaming()
            taskLock.lock()
            let task = taskForHandler
            taskLock.unlock()
            guard let task else {
                XCTFail("Expected the first callback to retain its task for stale-delivery testing.")
                return
            }
            manager.urlSession(mockSession, dataTask: task, didReceive: Data("late audio chunk".utf8))
            handlerStoppedStream.fulfill()
        }
        wait(for: [requestStarted], timeout: 1.0)
        guard let activeTask = manager.activeTaskForTesting else {
            XCTFail("Expected a task after streamTTS creates its request context.")
            allowRequestCompletion.signal()
            return
        }

        taskLock.lock()
        taskForHandler = activeTask
        taskLock.unlock()
        let delegateCallbackReturned = expectation(description: "Delegate callback returned")
        DispatchQueue.global(qos: .userInitiated).async {
            manager.urlSession(mockSession, dataTask: activeTask, didReceive: Data("first audio chunk".utf8))
            delegateCallbackReturned.fulfill()
        }
        let callbackResult = XCTWaiter().wait(
            for: [handlerStoppedStream, delegateCallbackReturned],
            timeout: 1.0
        )
        guard callbackResult == .completed else {
            XCTFail("The handler must synchronously stop the stream without blocking the delegate callback.")
            allowRequestCompletion.signal()
            return
        }
        allowRequestCompletion.signal()

        deliveryLock.lock()
        XCTAssertEqual(deliveryCount, 1)
        deliveryLock.unlock()
        assertAfterMockQuiescence {
            deliveryLock.lock()
            XCTAssertEqual(deliveryCount, 1)
            deliveryLock.unlock()
        }
    }

    func testNetworkManagerIgnoresStaleCallbacksAfterStreamReplacement() {
        // WHY: A late callback from a replaced request must not stop the new stream or send its
        // data to the replacement handler. URLSession cancellation cannot guarantee that a queued
        // callback never arrives, so the task identifier remains the final ownership check.
        let manager = TestNetworkFactory.makeManager()
        manager.updateSettings(baseURL: "https://mock.api/v1/audio/speech", apiKey: "test", model: "test", voice: "test")

        let firstRequestStarted = expectation(description: "First request started")
        let replacementRequestStarted = expectation(description: "Replacement request started")
        let replacementDataDelivered = expectation(description: "Replacement data delivered")
        let releaseReplacementResponse = DispatchSemaphore(value: 0)
        var requestCount = 0
        MockURLProtocol.installRequestHandler { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            if requestCount == 0 {
                requestCount += 1
                firstRequestStarted.fulfill()
                return (response, Data())
            }

            replacementRequestStarted.fulfill()
            _ = releaseReplacementResponse.wait(timeout: .now() + 1.0)
            return (response, Data("replacement audio".utf8))
        }

        manager.streamTTS(text: "first") { _ in
            XCTFail("A replaced stream must not deliver data")
        }
        wait(for: [firstRequestStarted], timeout: 1.0)

        manager.streamTTS(text: "replacement") { data in
            XCTAssertEqual(data, Data("replacement audio".utf8))
            replacementDataDelivered.fulfill()
        }
        wait(for: [replacementRequestStarted], timeout: 1.0)

        let mockSession = TestNetworkFactory.makeSession()
        let staleTask = mockSession.dataTask(with: URL(string: "https://mock.api/v1/audio/speech")!)
        manager.urlSession(mockSession, dataTask: staleTask, didReceive: Data("stale audio".utf8))
        manager.urlSession(mockSession, task: staleTask, didCompleteWithError: nil)

        let replacementIsStillStreaming = expectation(description: "Replacement stream remains active")
        DispatchQueue.main.async {
            XCTAssertTrue(manager.isStreaming)
            replacementIsStillStreaming.fulfill()
        }
        wait(for: [replacementIsStillStreaming], timeout: 1.0)

        releaseReplacementResponse.signal()
        wait(for: [replacementDataDelivered], timeout: 1.0)
    }

    func testGeminiStreamKeepsItsCapturedDecoderAfterSettingsSwitch() {
        // WHY: A provider switch updates the next request only. If delegate parsing re-reads the
        // mutable settings, Gemini's JSON response would be forwarded as PCM after this switch.
        let manager = TestNetworkFactory.makeManager()
        manager.updateSettings(
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            apiKey: "original-gemini-key",
            model: "original-gemini-model",
            voice: "Aoede"
        )

        let requestStarted = expectation(description: "Gemini request started")
        let audioDelivered = expectation(description: "Decoded Gemini audio delivered")
        let releaseResponse = DispatchSemaphore(value: 0)
        let expectedAudio = Data([0, 1, 2, 3])
        MockURLProtocol.installRequestHandler { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://generativelanguage.googleapis.com/v1beta/models/original-gemini-model:streamGenerateContent?alt=sse"
            )
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "original-gemini-key")
            requestStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 1.0)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let responseData = Data("""
            data: {"candidates":[{"content":{"parts":[{"inlineData":{"data":"\(expectedAudio.base64EncodedString())"}}]}}]}


            """.utf8)
            return (response, responseData)
        }

        manager.streamTTS(text: "Gemini request") { data in
            XCTAssertEqual(data, expectedAudio)
            audioDelivered.fulfill()
        }
        wait(for: [requestStarted], timeout: 1.0)

        manager.updateSettings(
            baseURL: "https://mock.api/v1/audio/speech",
            apiKey: "next-openai-key",
            model: "next-openai-model",
            voice: "next-openai-voice"
        )
        releaseResponse.signal()

        wait(for: [audioDelivered], timeout: 1.0)
    }

    func testOpenAIStreamKeepsItsCapturedDecoderAfterSettingsSwitch() {
        // WHY: A provider switch must not make an in-flight PCM stream use Gemini's buffered JSON
        // decoder, or the raw audio is discarded when completion tries to parse it as JSON.
        let manager = TestNetworkFactory.makeManager()
        manager.updateSettings(
            baseURL: "https://mock.api/v1/audio/speech",
            apiKey: "original-openai-key",
            model: "original-openai-model",
            voice: "original-openai-voice"
        )

        let requestStarted = expectation(description: "OpenAI request started")
        let audioDelivered = expectation(description: "Unchanged PCM delivered")
        let releaseResponse = DispatchSemaphore(value: 0)
        let expectedAudio = Data([8, 7, 6, 5])
        MockURLProtocol.installRequestHandler { request in
            XCTAssertEqual(request.url?.absoluteString, "https://mock.api/v1/audio/speech")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer original-openai-key")
            requestStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 1.0)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, expectedAudio)
        }

        manager.streamTTS(text: "OpenAI request") { data in
            XCTAssertEqual(data, expectedAudio)
            audioDelivered.fulfill()
        }
        wait(for: [requestStarted], timeout: 1.0)

        manager.updateSettings(
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            apiKey: "next-gemini-key",
            model: "next-gemini-model",
            voice: "Puck"
        )
        releaseResponse.signal()

        wait(for: [audioDelivered], timeout: 1.0)
    }
}
