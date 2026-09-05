import XCTest
@testable import ClipboardTTSApp

final class TTSNetworkManagerCallbackAuthorityTests: MockURLProtocolTestCase {
    func testOpenAIStopWaitsForAnAuthorizedCallbackBeforeReturning() {
        assertConcurrentStopCannotOutrunAuthorizedCallback(provider: .openAICompatible)
    }

    func testGeminiStopWaitsForAnAuthorizedCallbackBeforeReturning() {
        assertConcurrentStopCannotOutrunAuthorizedCallback(provider: .gemini)
    }

    func testGeminiFatalRevocationWaitsForAnAuthorizedCallbackBeforeReturning() {
        let callbackAuthority = ObservedCallbackAuthority()
        let manager = TestNetworkFactory.makeManager(callbackAuthority: callbackAuthority)
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

        let callbackEntered = expectation(description: "Authorized Gemini callback entered")
        let callbackFinished = expectation(description: "Authorized Gemini callback finished")
        let releaseCallback = DispatchSemaphore(value: 0)
        manager.streamTTS(text: "malformed Gemini callback authority") { _ in
            callbackEntered.fulfill()
            _ = releaseCallback.wait(timeout: .now() + 2.0)
            callbackFinished.fulfill()
        }
        wait(for: [requestStarted], timeout: 1.0)
        guard let task = manager.activeTaskForTesting else {
            XCTFail("Expected an active Gemini request before fatal-revocation testing.")
            return
        }

        callbackAuthority.observeNextRevocationAttempt()
        manager.urlSession(manager.session, dataTask: task, didReceive: geminiEvent(containing: Data([1, 2])))
        wait(for: [callbackEntered], timeout: 1.0)

        let revocationReturned = expectation(description: "Fatal revocation returned")
        let revocationReturnSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            manager.urlSession(manager.session, dataTask: task, didReceive: Data("data: not-json\n\n".utf8))
            revocationReturnSignal.signal()
            revocationReturned.fulfill()
        }
        XCTAssertEqual(callbackAuthority.revocationAttempt.wait(timeout: .now() + 1.0), .success)
        XCTAssertEqual(
            revocationReturnSignal.wait(timeout: .now()),
            .timedOut,
            "A malformed Gemini stream must not revoke delivery while an authorized callback can still run."
        )

        releaseCallback.signal()
        wait(for: [callbackFinished, revocationReturned], timeout: 1.0)
        let failurePublished = expectation(description: "Fatal Gemini failure published")
        DispatchQueue.main.async {
            XCTAssertEqual(manager.lastError, "The TTS service returned no playable audio. Please try again.")
            failurePublished.fulfill()
        }
        wait(for: [failurePublished], timeout: 1.0)
    }

    func testGeminiMalformedEventInvalidatesEarlierAudioFromTheSameDelegateCallback() {
        let audioDeliveryQueue = DispatchQueue(label: "com.clipboardtts.tests.gemini-fatal-batch")
        let manager = TestNetworkFactory.makeManager(audioDeliveryQueue: audioDeliveryQueue)
        manager.updateSettings(
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            apiKey: "test",
            model: "test",
            voice: "test",
            selectedProvider: "Gemini"
        )
        let requestStarted = expectation(description: "Gemini batch request started")
        let releaseResponse = DispatchSemaphore(value: 0)
        MockURLProtocol.installRequestHandler { request in
            requestStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 2.0)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { releaseResponse.signal() }

        let deliveredAudioCount = LockedValue(0)
        manager.streamTTS(text: "malformed Gemini batch") { _ in
            deliveredAudioCount.withValue { $0 += 1 }
        }
        wait(for: [requestStarted], timeout: 1.0)
        guard let task = manager.activeTaskForTesting else {
            XCTFail("Expected an active Gemini request before malformed-batch testing.")
            return
        }

        let malformedBatch = geminiEvent(containing: Data([1, 2])) + Data("data: not-json\n\n".utf8)
        manager.urlSession(manager.session, dataTask: task, didReceive: malformedBatch)
        audioDeliveryQueue.sync {}
        XCTAssertEqual(
            deliveredAudioCount.value,
            0,
            "A malformed Gemini event must invalidate earlier queued audio from the same delegate callback."
        )

        let failurePublished = expectation(description: "Malformed Gemini batch failure published")
        DispatchQueue.main.async {
            XCTAssertEqual(manager.lastError, "The TTS service returned no playable audio. Please try again.")
            failurePublished.fulfill()
        }
        wait(for: [failurePublished], timeout: 1.0)
    }

    /// Forces a stop to overlap a callback that has passed generation authorization. The callback
    /// barrier makes the required ordering observable without relying on a scheduler delay.
    private func assertConcurrentStopCannotOutrunAuthorizedCallback(provider: TTSNetworkManager.ProviderKind) {
        let audioDeliveryQueue = DispatchQueue(label: "com.clipboardtts.tests.callback-authority")
        let callbackAuthority = ObservedCallbackAuthority()
        let manager = TestNetworkFactory.makeManager(
            audioDeliveryQueue: audioDeliveryQueue,
            callbackAuthority: callbackAuthority
        )
        switch provider {
        case .gemini:
            manager.updateSettings(
                baseURL: "https://generativelanguage.googleapis.com/v1beta",
                apiKey: "test",
                model: "test",
                voice: "test",
                selectedProvider: "Gemini"
            )
        case .openAICompatible, .custom:
            manager.updateSettings(
                baseURL: "https://mock.api/v1/audio/speech",
                apiKey: "test",
                model: "test",
                voice: "test",
                selectedProvider: "OpenAI"
            )
        }

        let requestStarted = expectation(description: "Request started")
        let releaseResponse = DispatchSemaphore(value: 0)
        MockURLProtocol.installRequestHandler { request in
            requestStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 2.0)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { releaseResponse.signal() }

        let callbackEntered = expectation(description: "Authorized callback entered")
        let callbackFinished = expectation(description: "Authorized callback finished")
        let releaseCallback = DispatchSemaphore(value: 0)
        manager.streamTTS(text: "callback authority") { _ in
            callbackEntered.fulfill()
            _ = releaseCallback.wait(timeout: .now() + 2.0)
            callbackFinished.fulfill()
        }
        wait(for: [requestStarted], timeout: 1.0)
        guard let task = manager.activeTaskForTesting else {
            XCTFail("Expected an active request before testing callback authority.")
            return
        }

        callbackAuthority.observeNextRevocationAttempt()
        switch provider {
        case .gemini:
            manager.urlSession(manager.session, dataTask: task, didReceive: geminiEvent(containing: Data([1, 2])))
        case .openAICompatible, .custom:
            manager.urlSession(manager.session, dataTask: task, didReceive: Data([1, 2]))
        }
        wait(for: [callbackEntered], timeout: 1.0)

        let stopReturned = expectation(description: "Concurrent stop returned")
        let stopReturnSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            manager.stopStreaming()
            stopReturnSignal.signal()
            stopReturned.fulfill()
        }
        XCTAssertEqual(callbackAuthority.revocationAttempt.wait(timeout: .now() + 1.0), .success)
        let prematureStop = stopReturnSignal.wait(timeout: .now())
        XCTAssertEqual(
            prematureStop,
            .timedOut,
            "Clear Buffer must not return while an already authorized callback can still begin."
        )

        releaseCallback.signal()
        wait(for: [callbackFinished, stopReturned], timeout: 1.0)
        audioDeliveryQueue.sync {}
    }

    private func geminiEvent(containing audio: Data) -> Data {
        Data("""
        data: {"candidates":[{"content":{"parts":[{"inlineData":{"data":"\(audio.base64EncodedString())"}}]}}]}


        """.utf8)
    }
}

/// Reports when the second observed authority acquisition reaches the contested lock.
private final class ObservedCallbackAuthority: CallbackAuthorityLocking, @unchecked Sendable {
    let revocationAttempt = DispatchSemaphore(value: 0)
    private let recursiveLock = NSRecursiveLock()
    private let stateLock = NSLock()
    private var observedAcquisitionCount: Int?

    /// Starts observing one delivery acquisition followed by one revocation acquisition.
    func observeNextRevocationAttempt() {
        stateLock.lock()
        observedAcquisitionCount = 0
        stateLock.unlock()
    }

    func lock() {
        stateLock.lock()
        let signalsRevocationAttempt: Bool
        if let observedAcquisitionCount {
            signalsRevocationAttempt = observedAcquisitionCount == 1
            self.observedAcquisitionCount = observedAcquisitionCount + 1
        } else {
            signalsRevocationAttempt = false
        }
        stateLock.unlock()
        if signalsRevocationAttempt {
            revocationAttempt.signal()
        }
        recursiveLock.lock()
    }

    func unlock() {
        recursiveLock.unlock()
    }
}
