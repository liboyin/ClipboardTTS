import XCTest
@testable import ClipboardTTSApp

final class TTSNetworkManagerConcurrencyTests: MockURLProtocolTestCase {
    func testConcurrentDataCallbacksDeliverPCMInAcceptedOrder() {
        // WHY: URLSession callbacks may overlap. A callback that stateQueue accepts first must
        // stay first at the audio handler, even when its handler is blocked, or distinct PCM
        // chunks would play out of order and corrupt speech.
        let manager = TestNetworkFactory.makeManager()
        manager.updateSettings(baseURL: "https://mock.api/v1/audio/speech", apiKey: "test", model: "test", voice: "test")

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
        let deliveryLock = NSLock()
        var deliveredChunks: [Data] = []
        manager.streamTTS(text: "concurrent entry") { data in
            deliveryLock.lock()
            deliveredChunks.append(data)
            deliveryLock.unlock()
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

        deliveryLock.lock()
        XCTAssertEqual(deliveredChunks, [Data([1]), Data([2])])
        deliveryLock.unlock()
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
            voice: "test"
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
