import XCTest
@testable import ClipboardTTSApp

final class TTSNetworkManagerConcurrencyTests: MockURLProtocolTestCase {
    func testConcurrentDataCallbacksDeliverPCMInAcceptedOrder() {
        // WHY: URLSession callbacks may overlap. A callback that stateQueue accepts first must
        // stay first at the audio handler, even when its handler is blocked, or distinct PCM
        // chunks would play out of order and corrupt speech.
        let manager = TestNetworkFactory.makeManager()
        manager.updateSettings(baseURL: "https://mock.api/v1/audio/speech", apiKey: "test", model: "test", voice: "test", selectedProvider: "OpenAI")

        // The mock holds its response back so the request stays active while the test drives
        // synthetic concurrent callbacks; the mock itself delivers no data of its own.
        let requestStarted = expectation(description: "Request started")
        let releaseResponse = DispatchSemaphore(value: 0)
        MockURLProtocol.installRequestHandler { request in
            requestStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 5.0)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, nil)
        }

        let firstDeliveryStarted = expectation(description: "First PCM delivery started")
        let completedDeliveries = expectation(description: "Both PCM deliveries completed")
        completedDeliveries.expectedFulfillmentCount = 2
        let releaseFirstDelivery = DispatchSemaphore(value: 0)
        let secondDeliveryFinished = DispatchSemaphore(value: 0)
        let deliveredChunks = LockedValue<[Data]>([])
        manager.streamTTS(text: "concurrent entry") { data in
            deliveredChunks.withValue { $0.append(data) }
            if data == Data([1]) {
                firstDeliveryStarted.fulfill()
                _ = releaseFirstDelivery.wait(timeout: .now() + 2.0)
            } else {
                secondDeliveryFinished.signal()
            }
            completedDeliveries.fulfill()
        }
        wait(for: [requestStarted], timeout: 1.0)
        guard let task = manager.activeTaskForTesting else {
            XCTFail("Expected streamTTS to retain its task for delegate-callback testing.")
            releaseResponse.signal()
            return
        }

        DispatchQueue.global().async {
            manager.urlSession(manager.session, dataTask: task, didReceive: Data([1]))
        }
        wait(for: [firstDeliveryStarted], timeout: 1.0)
        manager.urlSession(manager.session, dataTask: task, didReceive: Data([2]))

        XCTAssertEqual(secondDeliveryFinished.wait(timeout: .now()), .timedOut)
        releaseFirstDelivery.signal()
        wait(for: [completedDeliveries], timeout: 1.0)

        assertTerminalState(of: manager, expectedError: nil) {
            releaseResponse.signal()
        }

        XCTAssertEqual(deliveredChunks.value, [Data([1]), Data([2])])
    }

    func testGeminiCompletionKeepsAnAcceptedFinalEventWhenAudioDeliveryIsBlocked() {
        // WHY: Completion can arrive immediately after the final delegate callback. Gemini must
        // decode and account for that accepted event before completion clears its request state,
        // even when the user audio handler is still queued, or valid audio is reported as absent.
        let audioDeliveryQueue = DispatchQueue(label: "com.clipboardtts.tests.blocked-gemini-delivery")
        let deliveryBlocked = expectation(description: "Audio delivery queue is blocked")
        let releaseDelivery = DispatchSemaphore(value: 0)
        audioDeliveryQueue.async {
            deliveryBlocked.fulfill()
            _ = releaseDelivery.wait(timeout: .now() + 2.0)
        }
        wait(for: [deliveryBlocked], timeout: 1.0)

        let manager = TestNetworkFactory.makeManager(audioDeliveryQueue: audioDeliveryQueue)
        manager.updateSettings(
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            apiKey: "test",
            model: "test",
            voice: "test",
            selectedProvider: "Gemini"
        )
        let requestStarted = expectation(description: "Gemini request started")
        let releaseResponse = DispatchSemaphore(value: 0)
        MockURLProtocol.installRequestHandler { request in
            requestStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 2.0)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        let expectedAudio = Data([0, 1])
        let audioDelivered = expectation(description: "Accepted final Gemini audio is delivered")
        manager.streamTTS(text: "final Gemini event") { data in
            XCTAssertEqual(data, expectedAudio)
            audioDelivered.fulfill()
        }
        wait(for: [requestStarted], timeout: 1.0)
        defer {
            releaseDelivery.signal()
            releaseResponse.signal()
        }
        guard let task = manager.activeTaskForTesting else {
            XCTFail("Expected an active Gemini request for completion-order testing.")
            return
        }

        let finalEvent = Data("""
        data: {"candidates":[{"content":{"parts":[{"inlineData":{"data":"\(expectedAudio.base64EncodedString())"}}]}}]}


        """.utf8)
        manager.urlSession(manager.session, dataTask: task, didReceive: finalEvent)
        assertTerminalState(of: manager, expectedError: nil) {
            manager.urlSession(manager.session, task: task, didCompleteWithError: nil)
        }

        releaseDelivery.signal()
        wait(for: [audioDelivered], timeout: 1.0)
    }
}

extension TTSNetworkManagerConcurrencyTests {
    func testQueuedPCMHandoffsAfterAReentrantStopAreRevokedBeforeDelivery() {
        // WHY: A Clear Buffer action from the first queued callback must also revoke later
        // callbacks already accepted from URLSession, otherwise speech resumes after stopping.
        let audioDeliveryQueue = DispatchQueue(label: "com.clipboardtts.tests.stop-revocation")
        let deliveryBlocked = expectation(description: "Audio delivery queue is blocked")
        let releaseDelivery = DispatchSemaphore(value: 0)
        audioDeliveryQueue.async {
            deliveryBlocked.fulfill()
            _ = releaseDelivery.wait(timeout: .now() + 2.0)
        }
        wait(for: [deliveryBlocked], timeout: 1.0)

        let manager = TestNetworkFactory.makeManager(audioDeliveryQueue: audioDeliveryQueue)
        manager.updateSettings(baseURL: "https://mock.api/v1/audio/speech", apiKey: "test", model: "test", voice: "test", selectedProvider: "OpenAI")
        let requestStarted = expectation(description: "Request started")
        let releaseResponse = DispatchSemaphore(value: 0)
        MockURLProtocol.installRequestHandler { request in
            requestStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 2.0)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { releaseResponse.signal() }

        let firstDelivery = expectation(description: "First handoff stops the stream")
        let deliveryQueueDrained = expectation(description: "Queued handoffs have been considered")
        let delivered = LockedValue<[Data]>([])
        let firstChunk = Data([0, 1])
        let secondChunk = Data([2, 3])
        manager.streamTTS(text: "stop queued handoffs") { data in
            delivered.withValue { $0.append(data) }
            if data == firstChunk {
                manager.stopStreaming()
                firstDelivery.fulfill()
            }
        }
        wait(for: [requestStarted], timeout: 1.0)
        guard let task = manager.activeTaskForTesting else {
            XCTFail("Expected an active request for queued-delivery cancellation testing.")
            return
        }

        manager.urlSession(manager.session, dataTask: task, didReceive: firstChunk)
        manager.urlSession(manager.session, dataTask: task, didReceive: secondChunk)
        releaseDelivery.signal()
        audioDeliveryQueue.async { deliveryQueueDrained.fulfill() }
        wait(for: [firstDelivery, deliveryQueueDrained], timeout: 1.0)

        XCTAssertEqual(delivered.value, [firstChunk])
    }

    func testQueuedPCMHandoffsAfterAReentrantReplacementAreRevokedBeforeDelivery() {
        // WHY: Starting a replacement from a callback gives the old request no authority over
        // later handoffs it queued before that callback ran.
        let audioDeliveryQueue = DispatchQueue(label: "com.clipboardtts.tests.replacement-revocation")
        let deliveryBlocked = expectation(description: "Audio delivery queue is blocked")
        let releaseDelivery = DispatchSemaphore(value: 0)
        audioDeliveryQueue.async {
            deliveryBlocked.fulfill()
            _ = releaseDelivery.wait(timeout: .now() + 2.0)
        }
        wait(for: [deliveryBlocked], timeout: 1.0)

        let manager = TestNetworkFactory.makeManager(audioDeliveryQueue: audioDeliveryQueue)
        manager.updateSettings(baseURL: "https://mock.api/v1/audio/speech", apiKey: "test", model: "test", voice: "test", selectedProvider: "OpenAI")
        let firstRequestStarted = expectation(description: "Initial request started")
        let replacementRequestStarted = expectation(description: "Replacement request started")
        let releaseFirstResponse = DispatchSemaphore(value: 0)
        let requestCount = LockedValue(0)
        MockURLProtocol.installRequestHandler { request in
            let isInitialRequest = requestCount.withValue { count -> Bool in
                count += 1
                return count == 1
            }
            if isInitialRequest {
                firstRequestStarted.fulfill()
                _ = releaseFirstResponse.wait(timeout: .now() + 2.0)
            } else {
                replacementRequestStarted.fulfill()
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { releaseFirstResponse.signal() }

        let firstDelivery = expectation(description: "First handoff starts replacement")
        let deliveryQueueDrained = expectation(description: "Queued handoffs have been considered")
        let delivered = LockedValue<[Data]>([])
        let firstChunk = Data([4, 5])
        let secondChunk = Data([6, 7])
        manager.streamTTS(text: "initial stream") { data in
            delivered.withValue { $0.append(data) }
            if data == firstChunk {
                manager.streamTTS(text: "replacement stream") { _ in
                    XCTFail("The replacement response supplies no PCM and must not invoke its handler.")
                }
                firstDelivery.fulfill()
            }
        }
        wait(for: [firstRequestStarted], timeout: 1.0)
        guard let task = manager.activeTaskForTesting else {
            XCTFail("Expected the initial request to own queued handoffs.")
            return
        }

        manager.urlSession(manager.session, dataTask: task, didReceive: firstChunk)
        manager.urlSession(manager.session, dataTask: task, didReceive: secondChunk)
        releaseDelivery.signal()
        audioDeliveryQueue.async { deliveryQueueDrained.fulfill() }
        wait(for: [firstDelivery, deliveryQueueDrained], timeout: 1.0)
        releaseFirstResponse.signal()
        wait(for: [replacementRequestStarted], timeout: 1.0)

        XCTAssertEqual(delivered.value, [firstChunk])
    }

    func testQueuedGeminiEventsAfterAReentrantStopAreRevokedBeforeDelivery() {
        // WHY: Gemini events use a separate parser path, but a stopped stream must revoke their
        // already queued PCM just like OpenAI-compatible PCM.
        let audioDeliveryQueue = DispatchQueue(label: "com.clipboardtts.tests.gemini-stop-revocation")
        let deliveryBlocked = expectation(description: "Audio delivery queue is blocked")
        let releaseDelivery = DispatchSemaphore(value: 0)
        audioDeliveryQueue.async {
            deliveryBlocked.fulfill()
            _ = releaseDelivery.wait(timeout: .now() + 2.0)
        }
        wait(for: [deliveryBlocked], timeout: 1.0)

        let manager = TestNetworkFactory.makeManager(audioDeliveryQueue: audioDeliveryQueue)
        manager.updateSettings(
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            apiKey: "test",
            model: "test",
            voice: "test",
            selectedProvider: "Gemini"
        )
        let requestStarted = expectation(description: "Gemini request started")
        let releaseResponse = DispatchSemaphore(value: 0)
        MockURLProtocol.installRequestHandler { request in
            requestStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 2.0)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { releaseResponse.signal() }

        let firstDelivery = expectation(description: "First Gemini event stops the stream")
        let deliveryQueueDrained = expectation(description: "Queued Gemini events have been considered")
        let delivered = LockedValue<[Data]>([])
        let firstChunk = Data([8, 9])
        let secondChunk = Data([10, 11])
        manager.streamTTS(text: "stop queued Gemini events") { data in
            delivered.withValue { $0.append(data) }
            if data == firstChunk {
                manager.stopStreaming()
                firstDelivery.fulfill()
            }
        }
        wait(for: [requestStarted], timeout: 1.0)
        guard let task = manager.activeTaskForTesting else {
            XCTFail("Expected an active Gemini request for queued-delivery testing.")
            return
        }

        let firstEvent = geminiEvent(containing: firstChunk)
        let secondEvent = geminiEvent(containing: secondChunk)
        manager.urlSession(manager.session, dataTask: task, didReceive: firstEvent + secondEvent)
        releaseDelivery.signal()
        audioDeliveryQueue.async { deliveryQueueDrained.fulfill() }
        wait(for: [firstDelivery, deliveryQueueDrained], timeout: 1.0)

        XCTAssertEqual(delivered.value, [firstChunk])
    }

    func testFatalGeminiCancellationRevokesQueuedAudioBeforeDelivery() {
        // WHY: A malformed Gemini event explicitly cancels the stream. PCM queued before that
        // failure cannot start playback after the application has reported it as unusable.
        let audioDeliveryQueue = DispatchQueue(label: "com.clipboardtts.tests.gemini-failure-revocation")
        let deliveryBlocked = expectation(description: "Audio delivery queue is blocked")
        let releaseDelivery = DispatchSemaphore(value: 0)
        audioDeliveryQueue.async {
            deliveryBlocked.fulfill()
            _ = releaseDelivery.wait(timeout: .now() + 2.0)
        }
        wait(for: [deliveryBlocked], timeout: 1.0)

        let manager = TestNetworkFactory.makeManager(audioDeliveryQueue: audioDeliveryQueue)
        manager.updateSettings(
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            apiKey: "test",
            model: "test",
            voice: "test",
            selectedProvider: "Gemini"
        )
        let requestStarted = expectation(description: "Gemini request started")
        let releaseResponse = DispatchSemaphore(value: 0)
        MockURLProtocol.installRequestHandler { request in
            requestStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 2.0)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { releaseResponse.signal() }

        let deliveryQueueDrained = expectation(description: "Queued Gemini audio has been considered")
        let audioDelivered = expectation(description: "Queued audio is not delivered")
        audioDelivered.isInverted = true
        let chunk = Data([12, 13])
        manager.streamTTS(text: "cancel queued Gemini audio") { _ in
            audioDelivered.fulfill()
        }
        wait(for: [requestStarted], timeout: 1.0)
        guard let task = manager.activeTaskForTesting else {
            XCTFail("Expected an active Gemini request for fatal-cancellation testing.")
            return
        }

        manager.urlSession(manager.session, dataTask: task, didReceive: geminiEvent(containing: chunk))
        assertTerminalState(of: manager, expectedError: "The TTS service returned no playable audio. Please try again.") {
            manager.urlSession(manager.session, dataTask: task, didReceive: Data("data: not-json\n\n".utf8))
        }
        releaseDelivery.signal()
        audioDeliveryQueue.async { deliveryQueueDrained.fulfill() }
        wait(for: [audioDelivered, deliveryQueueDrained], timeout: 1.0)
    }

    private func geminiEvent(containing audio: Data) -> Data {
        Data("""
        data: {"candidates":[{"content":{"parts":[{"inlineData":{"data":"\(audio.base64EncodedString())"}}]}}]}


        """.utf8)
    }
}
