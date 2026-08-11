import XCTest
@testable import ClipboardTTSApp

final class MockURLProtocolAudioScopeTests: XCTestCase {
    func testClosingScopeRevokesBlockedAudioDeliveryBeforeRestoringSettingsOrStartingNextScope() {
        // WHY: A URL-session drain alone cannot prove that a handler queued behind a blocked
        // delivery queue will not escape into restored developer settings or a later test scope.
        MockURLProtocolTestCase.testExecutionLock.lock()
        let acquiredTestExecutionGate = MockURLProtocolTestCase.enterTestExecutionGate()
        isolateAppSettingsDefaults()
        var scopeSettings: UserDefaultsSnapshot?
        var activeTestIdentifier: String?
        let audioDeliveryQueue = DispatchQueue(label: "com.clipboardtts.tests.scope-owned-delivery")
        let releaseDelivery = DispatchSemaphore(value: 0)
        let releaseResponse = DispatchSemaphore(value: 0)
        defer {
            releaseResponse.signal()
            releaseDelivery.signal()
            if let activeTestIdentifier {
                let endResult = MockURLProtocol.endTest(identifier: activeTestIdentifier, timeout: 1.0)
                if !endResult.didQuiesce {
                    MockURLProtocol.finishClosingTestWhenQuiescent(identifier: activeTestIdentifier)
                }
            }
            scopeSettings?.restore()
            if acquiredTestExecutionGate {
                MockURLProtocolTestCase.leaveTestExecutionGate()
            }
            MockURLProtocolTestCase.testExecutionLock.unlock()
        }

        UserDefaults.standard.set("developer-model", forKey: SettingsKeys.openAIModel)
        scopeSettings = UserDefaultsSnapshot(keys: [SettingsKeys.openAIModel])
        UserDefaults.standard.removeObject(forKey: SettingsKeys.openAIModel)
        activeTestIdentifier = MockURLProtocol.beginTest()

        let deliveryBlocked = expectation(description: "Owned audio delivery queue is blocked")
        audioDeliveryQueue.async {
            deliveryBlocked.fulfill()
            _ = releaseDelivery.wait(timeout: .now() + 2.0)
        }
        wait(for: [deliveryBlocked], timeout: 1.0)

        let manager = TestNetworkFactory.makeManager(audioDeliveryQueue: audioDeliveryQueue)
        manager.updateSettings(
            baseURL: "https://mock.api/v1/audio/speech",
            apiKey: "test",
            model: "test",
            voice: "test"
        )
        let requestStarted = expectation(description: "Request started before queuing audio")
        let responseReleased = expectation(description: "Mock response was released")
        MockURLProtocol.installRequestHandler { request in
            requestStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 2.0)
            responseReleased.fulfill()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, nil)
        }

        let callbackLock = NSLock()
        var callbackRan = false
        manager.streamTTS(text: "scope-owned queued audio") { _ in
            callbackLock.lock()
            callbackRan = true
            callbackLock.unlock()
        }
        wait(for: [requestStarted], timeout: 1.0)
        guard let task = manager.activeTaskForTesting else {
            XCTFail("Expected the manager to own a task before queuing test audio.")
            return
        }
        manager.urlSession(manager.session, dataTask: task, didReceive: Data([0, 1]))
        assertTerminalState(of: manager, expectedError: nil) {
            manager.urlSession(manager.session, task: task, didCompleteWithError: nil)
        }
        releaseResponse.signal()
        wait(for: [responseReleased], timeout: 1.0)

        guard let testIdentifier = activeTestIdentifier else {
            XCTFail("Expected the manual mock scope to remain active.")
            return
        }
        let endResult = MockURLProtocol.endTest(identifier: testIdentifier, timeout: 0.2)
        activeTestIdentifier = nil
        XCTAssertFalse(endResult.didQuiesce, "A blocked owned delivery queue must delay settings restoration.")
        XCTAssertNil(UserDefaults.standard.object(forKey: SettingsKeys.openAIModel))

        let settingsRestored = expectation(description: "Settings restore after owned delivery drains")
        DispatchQueue.global(qos: .userInitiated).async {
            MockURLProtocol.finishClosingTestWhenQuiescent(identifier: testIdentifier)
            scopeSettings?.restore()
            settingsRestored.fulfill()
        }
        releaseDelivery.signal()
        wait(for: [settingsRestored], timeout: 1.0)
        XCTAssertEqual(UserDefaults.standard.string(forKey: SettingsKeys.openAIModel), "developer-model")

        activeTestIdentifier = MockURLProtocol.beginTest()
        audioDeliveryQueue.sync {}
        callbackLock.lock()
        XCTAssertFalse(callbackRan, "A revoked handler must not run after settings restoration or in the next test scope.")
        callbackLock.unlock()
        let nextScopeEndResult = MockURLProtocol.endTest(identifier: activeTestIdentifier!, timeout: 1.0)
        XCTAssertTrue(nextScopeEndResult.didQuiesce)
        activeTestIdentifier = nil
    }

    func testBackgroundDeliveryRevocationDoesNotWaitForTheMainThread() {
        // WHY: Timeout recovery runs off-main while the settings-isolation wrapper can be
        // waiting on the main thread. Revocation must advance callback authority without a cycle.
        MockURLProtocolTestCase.testExecutionLock.lock()
        let acquiredTestExecutionGate = MockURLProtocolTestCase.enterTestExecutionGate()
        isolateAppSettingsDefaults()
        var activeTestIdentifier: String?
        let audioDeliveryQueue = DispatchQueue(label: "com.clipboardtts.tests.background-revocation")
        let releaseDelivery = DispatchSemaphore(value: 0)
        let releaseResponse = DispatchSemaphore(value: 0)
        defer {
            releaseResponse.signal()
            releaseDelivery.signal()
            if let activeTestIdentifier {
                let endResult = MockURLProtocol.endTest(identifier: activeTestIdentifier, timeout: 1.0)
                if !endResult.didQuiesce {
                    MockURLProtocol.finishClosingTestWhenQuiescent(identifier: activeTestIdentifier)
                }
            }
            if acquiredTestExecutionGate {
                MockURLProtocolTestCase.leaveTestExecutionGate()
            }
            MockURLProtocolTestCase.testExecutionLock.unlock()
        }

        activeTestIdentifier = MockURLProtocol.beginTest()
        let deliveryBlocked = expectation(description: "Background revocation delivery queue is blocked")
        audioDeliveryQueue.async {
            deliveryBlocked.fulfill()
            _ = releaseDelivery.wait(timeout: .now() + 2.0)
        }
        wait(for: [deliveryBlocked], timeout: 1.0)

        let manager = TestNetworkFactory.makeManager(audioDeliveryQueue: audioDeliveryQueue)
        manager.updateSettings(
            baseURL: "https://mock.api/v1/audio/speech",
            apiKey: "test",
            model: "test",
            voice: "test"
        )
        let requestStarted = expectation(description: "Request is active during background revocation")
        MockURLProtocol.installRequestHandler { request in
            requestStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 2.0)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, nil)
        }

        let callbackLock = NSLock()
        var callbackRan = false
        manager.streamTTS(text: "background teardown") { _ in
            callbackLock.lock()
            callbackRan = true
            callbackLock.unlock()
        }
        wait(for: [requestStarted], timeout: 1.0)
        guard let task = manager.activeTaskForTesting else {
            XCTFail("Expected an active task before testing background delivery revocation.")
            return
        }
        manager.urlSession(manager.session, dataTask: task, didReceive: Data([0, 1]))

        let backgroundRevocationFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            TestNetworkFactory.revokePendingDelivery(for: manager)
            backgroundRevocationFinished.signal()
        }
        XCTAssertEqual(
            backgroundRevocationFinished.wait(timeout: .now() + 1.0),
            .success,
            "Background teardown must revoke delivery without waiting for main-thread service."
        )

        releaseDelivery.signal()
        audioDeliveryQueue.sync {}
        callbackLock.lock()
        XCTAssertFalse(callbackRan, "Background revocation must invalidate queued delivery before it runs.")
        callbackLock.unlock()
        releaseResponse.signal()
    }
}
