import Foundation

class MockURLProtocol: URLProtocol {
    typealias RequestHandler = (URLRequest) throws -> (HTTPURLResponse, Data?)

    static let testIdentifierHeader = "X-ClipboardTTS-Mock-Test-Identifier"

    struct TestEndResult {
        let expectedUnhandledRequestCount: Int
        let observedUnhandledRequestCount: Int
        let didQuiesce: Bool
    }

    private struct TestState {
        var requestHandler: RequestHandler?
        var expectedUnhandledRequestCount = 0
        var unhandledRequestCount = 0
        var activeLoadCount = 0
        var activeManagerConstructionCount = 0
        var audioDeliveryScopes: [AudioDeliveryScope] = []
        var hasRevokedAudioDelivery = false
        var pendingAudioDeliveryDrainCount = 0
        var hasScheduledAudioDeliveryDrains = false
        var isClosing = false
        var sessionRegistrations: [SessionRegistration] = []
    }

    private struct SessionRegistration {
        let session: URLSession
        let delegate: AnyObject?
    }

    private struct AudioDeliveryScope {
        let queue: DispatchQueue
        let cancelPendingDelivery: () -> Void
    }

    private static let stateCondition = NSCondition()
    private static var testStates: [String: TestState] = [:]
    private static var activeTestIdentifier: String?

    /// Starts an isolated test scope and returns the identifier embedded in its mock sessions.
    static func beginTest() -> String {
        stateCondition.lock()
        defer { stateCondition.unlock() }

        let testIdentifier = UUID().uuidString
        activeTestIdentifier = testIdentifier
        testStates[testIdentifier] = TestState()
        return testIdentifier
    }

    /// Returns the identifier that must be embedded in each mock-routed session created by this test.
    static func currentTestIdentifier() -> String {
        stateCondition.lock()
        defer { stateCondition.unlock() }

        guard let activeTestIdentifier else {
            preconditionFailure("MockURLProtocol test scope has not been started.")
        }
        return activeTestIdentifier
    }

    /// Installs the response handler used by mock-routed requests in the current test.
    static func installRequestHandler(_ handler: @escaping RequestHandler) {
        stateCondition.lock()
        defer { stateCondition.unlock() }

        guard let activeTestIdentifier, var state = testStates[activeTestIdentifier] else {
            preconditionFailure("MockURLProtocol test scope has not been started.")
        }
        state.requestHandler = handler
        testStates[activeTestIdentifier] = state
    }

    /// Removes the response handler so a request without an explicit mock fails locally.
    static func reset() {
        stateCondition.lock()
        defer { stateCondition.unlock() }

        guard let activeTestIdentifier, var state = testStates[activeTestIdentifier] else { return }
        state.requestHandler = nil
        testStates[activeTestIdentifier] = state
    }

    /// Declares the number of deliberately unhandled requests expected by the current test.
    static func expectUnhandledRequests(_ count: Int = 1) {
        stateCondition.lock()
        defer { stateCondition.unlock() }

        guard let activeTestIdentifier, var state = testStates[activeTestIdentifier] else {
            preconditionFailure("MockURLProtocol test scope has not been started.")
        }
        state.expectedUnhandledRequestCount += count
        testStates[activeTestIdentifier] = state
    }

    /// Registers a session so teardown can invalidate it before releasing the test scope.
    static func register(session: URLSession, delegate: AnyObject? = nil, forTestIdentifier testIdentifier: String) {
        stateCondition.lock()
        defer { stateCondition.unlock() }

        guard var state = testStates[testIdentifier] else { return }
        guard !state.isClosing else {
            state.unhandledRequestCount += 1
            testStates[testIdentifier] = state
            session.invalidateAndCancel()
            return
        }
        state.sessionRegistrations.append(SessionRegistration(session: session, delegate: delegate))
        testStates[testIdentifier] = state
    }

    /// Records that a registered session can no longer begin new protocol loads.
    static func sessionDidInvalidate(_ session: URLSession, forTestIdentifier testIdentifier: String) {
        stateCondition.lock()
        defer { stateCondition.unlock() }

        guard var state = testStates[testIdentifier] else { return }
        state.sessionRegistrations.removeAll { $0.session === session }
        testStates[testIdentifier] = state
        stateCondition.broadcast()
    }

    /// Atomically claims the active scope for a manager initializer before it can read settings.
    static func beginManagerConstructionForCurrentTest() -> String {
        stateCondition.lock()
        defer { stateCondition.unlock() }

        guard let testIdentifier = activeTestIdentifier,
              var state = testStates[testIdentifier],
              !state.isClosing else {
            preconditionFailure("MockURLProtocol test scope has not been started.")
        }
        state.activeManagerConstructionCount += 1
        testStates[testIdentifier] = state
        return testIdentifier
    }

    /// Marks a factory-created manager initializer as complete after it has registered its session.
    static func managerConstructionDidFinish(forTestIdentifier testIdentifier: String) {
        stateCondition.lock()
        defer { stateCondition.unlock() }

        guard var state = testStates[testIdentifier] else { return }
        state.activeManagerConstructionCount -= 1
        testStates[testIdentifier] = state
        stateCondition.broadcast()
    }

    /// Registers a factory-created manager's delivery queue and cancellation boundary with its test scope.
    static func register(audioDeliveryQueue: DispatchQueue,
                         cancelPendingDelivery: @escaping () -> Void,
                         forTestIdentifier testIdentifier: String) {
        stateCondition.lock()
        defer { stateCondition.unlock() }

        guard var state = testStates[testIdentifier] else { return }
        state.audioDeliveryScopes.append(
            AudioDeliveryScope(queue: audioDeliveryQueue, cancelPendingDelivery: cancelPendingDelivery)
        )
        testStates[testIdentifier] = state
    }

    /// Invalidates a test's sessions, revokes pending delivery, drains owned queues, and closes the scope.
    static func endTest(identifier: String, timeout: TimeInterval = 2.0) -> TestEndResult {
        stateCondition.lock()
        guard var state = testStates[identifier] else {
            stateCondition.unlock()
            return TestEndResult(expectedUnhandledRequestCount: 0, observedUnhandledRequestCount: 0, didQuiesce: true)
        }
        state.requestHandler = nil
        state.isClosing = true
        let sessions = state.sessionRegistrations.map(\.session)
        testStates[identifier] = state
        stateCondition.unlock()

        sessions.forEach { $0.invalidateAndCancel() }

        stateCondition.lock()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, let currentState = testStates[identifier] {
            if hasUndrainedSessionWork(currentState) {
                stateCondition.wait(until: deadline)
            } else if !currentState.hasRevokedAudioDelivery {
                revokeAudioDelivery(for: identifier, state: currentState)
            } else if !currentState.hasScheduledAudioDeliveryDrains {
                scheduleAudioDeliveryDrains(for: identifier, state: currentState)
            } else if currentState.pendingAudioDeliveryDrainCount > 0 {
                stateCondition.wait(until: deadline)
            } else {
                break
            }
        }

        guard let completedState = testStates[identifier] else {
            stateCondition.unlock()
            return TestEndResult(expectedUnhandledRequestCount: 0, observedUnhandledRequestCount: 0, didQuiesce: true)
        }
        let didQuiesce = !hasUndrainedSessionWork(completedState) &&
            completedState.hasRevokedAudioDelivery &&
            completedState.hasScheduledAudioDeliveryDrains &&
            completedState.pendingAudioDeliveryDrainCount == 0
        if didQuiesce {
            testStates.removeValue(forKey: identifier)
        }
        if activeTestIdentifier == identifier {
            activeTestIdentifier = nil
        }
        stateCondition.unlock()
        return TestEndResult(
            expectedUnhandledRequestCount: completedState.expectedUnhandledRequestCount,
            observedUnhandledRequestCount: completedState.unhandledRequestCount,
            didQuiesce: didQuiesce
        )
    }

    /// Waits for a closing test scope to drain before removing its shared mock state.
    static func finishClosingTestWhenQuiescent(identifier: String) {
        stateCondition.lock()
        while let state = testStates[identifier] {
            if hasUndrainedSessionWork(state) {
                stateCondition.wait()
                continue
            }
            if !state.hasRevokedAudioDelivery {
                revokeAudioDelivery(for: identifier, state: state)
                continue
            }
            if !state.hasScheduledAudioDeliveryDrains {
                scheduleAudioDeliveryDrains(for: identifier, state: state)
                continue
            }
            guard state.pendingAudioDeliveryDrainCount > 0 else { break }
            stateCondition.wait()
        }
        testStates.removeValue(forKey: identifier)
        if activeTestIdentifier == identifier {
            activeTestIdentifier = nil
        }
        stateCondition.unlock()
    }

    /// Returns whether session, protocol-load, or manager-initialization work can still enqueue delivery.
    private static func hasUndrainedSessionWork(_ state: TestState) -> Bool {
        state.activeLoadCount > 0 ||
            state.activeManagerConstructionCount > 0 ||
            !state.sessionRegistrations.isEmpty
    }

    /// Revokes all manager-owned delivery generations after construction can no longer add an owner.
    private static func revokeAudioDelivery(for testIdentifier: String, state: TestState) {
        precondition(!state.hasRevokedAudioDelivery)
        var updatedState = state
        updatedState.hasRevokedAudioDelivery = true
        let audioDeliveryScopes = state.audioDeliveryScopes
        testStates[testIdentifier] = updatedState
        stateCondition.unlock()
        audioDeliveryScopes.forEach { $0.cancelPendingDelivery() }
        stateCondition.lock()
    }

    /// Adds one ordered drain marker per owned delivery queue after cancellation has revoked its callbacks.
    private static func scheduleAudioDeliveryDrains(for testIdentifier: String, state: TestState) {
        precondition(!state.hasScheduledAudioDeliveryDrains)
        var updatedState = state
        updatedState.hasScheduledAudioDeliveryDrains = true
        updatedState.pendingAudioDeliveryDrainCount = state.audioDeliveryScopes.count
        let queues = state.audioDeliveryScopes.map(\.queue)
        testStates[testIdentifier] = updatedState
        stateCondition.unlock()
        queues.forEach { queue in
            queue.async {
                audioDeliveryQueueDidDrain(forTestIdentifier: testIdentifier)
            }
        }
        stateCondition.lock()
    }

    /// Accounts for one scope-owned delivery queue reaching its teardown drain marker.
    private static func audioDeliveryQueueDidDrain(forTestIdentifier testIdentifier: String) {
        stateCondition.lock()
        defer { stateCondition.unlock() }

        guard var state = testStates[testIdentifier] else { return }
        state.pendingAudioDeliveryDrainCount -= 1
        testStates[testIdentifier] = state
        stateCondition.broadcast()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        MockURLProtocol.stateCondition.lock()
        let testIdentifier = request.value(forHTTPHeaderField: MockURLProtocol.testIdentifierHeader)
            ?? MockURLProtocol.activeTestIdentifier
        guard let testIdentifier, var state = MockURLProtocol.testStates[testIdentifier] else {
            MockURLProtocol.stateCondition.unlock()
            failLoading()
            return
        }

        state.activeLoadCount += 1
        let handler = state.isClosing ? nil : state.requestHandler
        if handler == nil {
            state.unhandledRequestCount += 1
        }
        MockURLProtocol.testStates[testIdentifier] = state
        MockURLProtocol.stateCondition.unlock()

        defer { MockURLProtocol.finishLoading(forTestIdentifier: testIdentifier) }

        guard let handler else {
            failLoading()
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let data = data {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    private static func finishLoading(forTestIdentifier testIdentifier: String) {
        stateCondition.lock()
        defer { stateCondition.unlock() }

        guard var state = testStates[testIdentifier] else { return }
        state.activeLoadCount -= 1
        testStates[testIdentifier] = state
        stateCondition.broadcast()
    }

    private func failLoading() {
        client?.urlProtocol(
            self,
            didFailWithError: URLError(
                .cannotLoadFromNetwork,
                userInfo: [NSLocalizedDescriptionKey: "No MockURLProtocol handler is installed."]
            )
        )
    }

    override func stopLoading() {}
}
