import Foundation

/// Everything one test scope owns while it is open, plus the accounting its shutdown reads.
private struct TestState {
    var requestHandler: MockURLProtocol.RequestHandler?
    var expectedUnhandledRequestCount = 0
    var unhandledRequestCount = 0
    var activeLoadCount = 0
    var activeManagerConstructionCount = 0
    var audioDeliveryScopes: [AudioDeliveryScope] = []
    var hasStartedAudioDeliveryRelease = false
    var hasReleasedAudioDelivery = false
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
    let releasePendingDelivery: () -> Void
    let finishRevocation: () -> Void
}

/// The shared scope registry, private to this file so the URL-protocol half can reach it only
/// through the claim and finish seam and can never mutate scope accounting directly.
private enum ScopeStorage {
    static let condition = NSCondition()
    /// Runs the half of revocation that can block, so the tearing-down thread only waits on a deadline.
    ///
    /// Concurrent because one scope whose handler never returns must not delay another scope's
    /// recovery, which can run while the next test is already executing.
    static let revocationQueue = DispatchQueue(
        label: "com.clipboardtts.tests.mockurlprotocol.revocation",
        attributes: .concurrent
    )
    static var testStates: [String: TestState] = [:]
    static var activeTestIdentifier: String?
}

extension MockURLProtocol {
    struct TestEndResult {
        let expectedUnhandledRequestCount: Int
        let observedUnhandledRequestCount: Int
        let didQuiesce: Bool
    }

    /// One protocol load a scope has accepted responsibility for draining before it can quiesce.
    struct ClaimedLoad {
        let testIdentifier: String
        let requestHandler: RequestHandler?
    }

    /// Starts an isolated test scope and returns the identifier embedded in its mock sessions.
    static func beginTest() -> String {
        ScopeStorage.condition.lock()
        defer { ScopeStorage.condition.unlock() }

        let testIdentifier = UUID().uuidString
        ScopeStorage.activeTestIdentifier = testIdentifier
        ScopeStorage.testStates[testIdentifier] = TestState()
        return testIdentifier
    }

    /// Returns the identifier that must be embedded in each mock-routed session created by this test.
    static func currentTestIdentifier() -> String {
        ScopeStorage.condition.lock()
        defer { ScopeStorage.condition.unlock() }

        guard let activeTestIdentifier = ScopeStorage.activeTestIdentifier else {
            preconditionFailure("MockURLProtocol test scope has not been started.")
        }
        return activeTestIdentifier
    }

    /// Installs the response handler used by mock-routed requests in the current test.
    static func installRequestHandler(_ handler: @escaping RequestHandler) {
        ScopeStorage.condition.lock()
        defer { ScopeStorage.condition.unlock() }

        guard let activeTestIdentifier = ScopeStorage.activeTestIdentifier,
              var state = ScopeStorage.testStates[activeTestIdentifier] else {
            preconditionFailure("MockURLProtocol test scope has not been started.")
        }
        state.requestHandler = handler
        ScopeStorage.testStates[activeTestIdentifier] = state
    }

    /// Removes the response handler so a request without an explicit mock fails locally.
    static func reset() {
        ScopeStorage.condition.lock()
        defer { ScopeStorage.condition.unlock() }

        guard let activeTestIdentifier = ScopeStorage.activeTestIdentifier,
              var state = ScopeStorage.testStates[activeTestIdentifier] else { return }
        state.requestHandler = nil
        ScopeStorage.testStates[activeTestIdentifier] = state
    }

    /// Declares the number of deliberately unhandled requests expected by the current test.
    static func expectUnhandledRequests(_ count: Int = 1) {
        ScopeStorage.condition.lock()
        defer { ScopeStorage.condition.unlock() }

        guard let activeTestIdentifier = ScopeStorage.activeTestIdentifier,
              var state = ScopeStorage.testStates[activeTestIdentifier] else {
            preconditionFailure("MockURLProtocol test scope has not been started.")
        }
        state.expectedUnhandledRequestCount += count
        ScopeStorage.testStates[activeTestIdentifier] = state
    }

    /// Registers a session so teardown can invalidate it before releasing the test scope.
    static func register(session: URLSession, delegate: AnyObject? = nil, forTestIdentifier testIdentifier: String) {
        ScopeStorage.condition.lock()
        defer { ScopeStorage.condition.unlock() }

        guard var state = ScopeStorage.testStates[testIdentifier] else { return }
        guard !state.isClosing else {
            state.unhandledRequestCount += 1
            ScopeStorage.testStates[testIdentifier] = state
            session.invalidateAndCancel()
            return
        }
        state.sessionRegistrations.append(SessionRegistration(session: session, delegate: delegate))
        ScopeStorage.testStates[testIdentifier] = state
    }

    /// Records that a registered session can no longer begin new protocol loads.
    static func sessionDidInvalidate(_ session: URLSession, forTestIdentifier testIdentifier: String) {
        ScopeStorage.condition.lock()
        defer { ScopeStorage.condition.unlock() }

        guard var state = ScopeStorage.testStates[testIdentifier] else { return }
        state.sessionRegistrations.removeAll { $0.session === session }
        ScopeStorage.testStates[testIdentifier] = state
        ScopeStorage.condition.broadcast()
    }

    /// Atomically claims the active scope for a manager initializer before it can read settings.
    static func beginManagerConstructionForCurrentTest() -> String {
        ScopeStorage.condition.lock()
        defer { ScopeStorage.condition.unlock() }

        guard let testIdentifier = ScopeStorage.activeTestIdentifier,
              var state = ScopeStorage.testStates[testIdentifier],
              !state.isClosing else {
            preconditionFailure("MockURLProtocol test scope has not been started.")
        }
        state.activeManagerConstructionCount += 1
        ScopeStorage.testStates[testIdentifier] = state
        return testIdentifier
    }

    /// Marks a factory-created manager initializer as complete after it has registered its session.
    static func managerConstructionDidFinish(forTestIdentifier testIdentifier: String) {
        ScopeStorage.condition.lock()
        defer { ScopeStorage.condition.unlock() }

        guard var state = ScopeStorage.testStates[testIdentifier] else { return }
        state.activeManagerConstructionCount -= 1
        ScopeStorage.testStates[testIdentifier] = state
        ScopeStorage.condition.broadcast()
    }

    /// Registers a factory-created manager's delivery queue and cancellation boundary with its test scope.
    ///
    /// `releasePendingDelivery` runs off the tearing-down thread under the scope deadline because it
    /// waits for an in-flight client handler. `finishRevocation` runs on the tearing-down thread
    /// afterwards, where the owner's terminal state can be read and restored without a hop.
    static func register(audioDeliveryQueue: DispatchQueue,
                         releasePendingDelivery: @escaping () -> Void,
                         finishRevocation: @escaping () -> Void,
                         forTestIdentifier testIdentifier: String) {
        ScopeStorage.condition.lock()
        defer { ScopeStorage.condition.unlock() }

        guard var state = ScopeStorage.testStates[testIdentifier] else { return }
        state.audioDeliveryScopes.append(
            AudioDeliveryScope(
                queue: audioDeliveryQueue,
                releasePendingDelivery: releasePendingDelivery,
                finishRevocation: finishRevocation
            )
        )
        ScopeStorage.testStates[testIdentifier] = state
    }

    /// Claims one protocol load for the scope that owns it, returning the handler that load may use.
    ///
    /// Returns `nil` when no scope owns the request, which leaves the load unaccounted for and the
    /// caller responsible for failing it locally. A claimed load must be balanced by `finishLoad`.
    static func beginLoad(requestedTestIdentifier: String?) -> ClaimedLoad? {
        ScopeStorage.condition.lock()
        defer { ScopeStorage.condition.unlock() }

        let testIdentifier = requestedTestIdentifier ?? ScopeStorage.activeTestIdentifier
        guard let testIdentifier, var state = ScopeStorage.testStates[testIdentifier] else { return nil }

        state.activeLoadCount += 1
        let requestHandler = state.isClosing ? nil : state.requestHandler
        if requestHandler == nil {
            state.unhandledRequestCount += 1
        }
        ScopeStorage.testStates[testIdentifier] = state
        return ClaimedLoad(testIdentifier: testIdentifier, requestHandler: requestHandler)
    }

    /// Releases a claimed protocol load so its scope can reach quiescence.
    static func finishLoad(forTestIdentifier testIdentifier: String) {
        ScopeStorage.condition.lock()
        defer { ScopeStorage.condition.unlock() }

        guard var state = ScopeStorage.testStates[testIdentifier] else { return }
        state.activeLoadCount -= 1
        ScopeStorage.testStates[testIdentifier] = state
        ScopeStorage.condition.broadcast()
    }

    /// Invalidates a test's sessions, revokes pending delivery, drains owned queues, and closes the scope.
    static func endTest(identifier: String, timeout: TimeInterval = 2.0) -> TestEndResult {
        ScopeStorage.condition.lock()
        guard var state = ScopeStorage.testStates[identifier] else {
            ScopeStorage.condition.unlock()
            return TestEndResult(expectedUnhandledRequestCount: 0, observedUnhandledRequestCount: 0, didQuiesce: true)
        }
        state.requestHandler = nil
        state.isClosing = true
        let sessions = state.sessionRegistrations.map(\.session)
        ScopeStorage.testStates[identifier] = state
        ScopeStorage.condition.unlock()

        sessions.forEach { $0.invalidateAndCancel() }

        ScopeStorage.condition.lock()
        advanceClosingScope(identifier: identifier, deadline: Date().addingTimeInterval(timeout))

        guard let completedState = ScopeStorage.testStates[identifier] else {
            ScopeStorage.condition.unlock()
            return TestEndResult(expectedUnhandledRequestCount: 0, observedUnhandledRequestCount: 0, didQuiesce: true)
        }
        let didQuiesce = !hasUndrainedSessionWork(completedState) &&
            completedState.hasRevokedAudioDelivery &&
            completedState.hasScheduledAudioDeliveryDrains &&
            completedState.pendingAudioDeliveryDrainCount == 0
        if didQuiesce {
            ScopeStorage.testStates.removeValue(forKey: identifier)
        }
        if ScopeStorage.activeTestIdentifier == identifier {
            ScopeStorage.activeTestIdentifier = nil
        }
        ScopeStorage.condition.unlock()
        return TestEndResult(
            expectedUnhandledRequestCount: completedState.expectedUnhandledRequestCount,
            observedUnhandledRequestCount: completedState.unhandledRequestCount,
            didQuiesce: didQuiesce
        )
    }

    /// Waits for a closing test scope to drain before removing its shared mock state.
    static func finishClosingTestWhenQuiescent(identifier: String) {
        ScopeStorage.condition.lock()
        advanceClosingScope(identifier: identifier, deadline: nil)
        ScopeStorage.testStates.removeValue(forKey: identifier)
        if ScopeStorage.activeTestIdentifier == identifier {
            ScopeStorage.activeTestIdentifier = nil
        }
        ScopeStorage.condition.unlock()
    }
}

/// Runs the shutdown steps a closing scope still owes, in the order that keeps each one safe.
///
/// The caller must hold the scope condition. A `nil` deadline waits indefinitely, which only the
/// off-main recovery path may do; the tearing-down thread always supplies its scope deadline so no
/// step can hold it past that bound. Steps that call into an owner unlock around the call.
private func advanceClosingScope(identifier: String, deadline: Date?) {
    while deadline.map({ Date() < $0 }) ?? true, let state = ScopeStorage.testStates[identifier] {
        if hasUndrainedSessionWork(state) {
            waitForScopeChange(until: deadline)
        } else if !state.hasStartedAudioDeliveryRelease {
            startAudioDeliveryRelease(for: identifier, state: state)
        } else if !state.hasReleasedAudioDelivery {
            waitForScopeChange(until: deadline)
        } else if !state.hasRevokedAudioDelivery {
            finishAudioDeliveryRevocation(for: identifier, state: state)
        } else if !state.hasScheduledAudioDeliveryDrains {
            scheduleAudioDeliveryDrains(for: identifier, state: state)
        } else if state.pendingAudioDeliveryDrainCount > 0 {
            waitForScopeChange(until: deadline)
        } else {
            break
        }
    }
}

/// Waits for the next scope-state change, bounded by the caller's deadline when it has one.
private func waitForScopeChange(until deadline: Date?) {
    guard let deadline else {
        ScopeStorage.condition.wait()
        return
    }
    ScopeStorage.condition.wait(until: deadline)
}

/// Returns whether session, protocol-load, or manager-initialization work can still enqueue delivery.
private func hasUndrainedSessionWork(_ state: TestState) -> Bool {
    state.activeLoadCount > 0 ||
        state.activeManagerConstructionCount > 0 ||
        !state.sessionRegistrations.isEmpty
}

/// Starts revoking all manager-owned delivery generations, off the thread that is tearing down.
///
/// This half waits for any in-flight client handler to return, so the caller must be free to stop
/// waiting for it: a handler that never returns would otherwise convert one failing test into a
/// hung suite. Construction can no longer add an owner by the time this runs.
private func startAudioDeliveryRelease(for testIdentifier: String, state: TestState) {
    precondition(!state.hasStartedAudioDeliveryRelease)
    var updatedState = state
    updatedState.hasStartedAudioDeliveryRelease = true
    let releases = state.audioDeliveryScopes.map(\.releasePendingDelivery)
    ScopeStorage.testStates[testIdentifier] = updatedState
    ScopeStorage.revocationQueue.async {
        releases.forEach { $0() }
        ScopeStorage.condition.lock()
        defer { ScopeStorage.condition.unlock() }

        guard var releasedState = ScopeStorage.testStates[testIdentifier] else { return }
        releasedState.hasReleasedAudioDelivery = true
        ScopeStorage.testStates[testIdentifier] = releasedState
        ScopeStorage.condition.broadcast()
    }
}

/// Completes revocation on the tearing-down thread once no client handler can hold it up.
///
/// The released generation is already stale, so a delivery still queued behind it can only take
/// callback authority long enough to reject itself. That leaves this step free to run where the
/// owner's main-queue-confined terminal state can be read and restored without a hop, and it
/// advances the generation once more so the release's own queued publications are ignored.
private func finishAudioDeliveryRevocation(for testIdentifier: String, state: TestState) {
    precondition(state.hasReleasedAudioDelivery && !state.hasRevokedAudioDelivery)
    var updatedState = state
    updatedState.hasRevokedAudioDelivery = true
    let revocations = state.audioDeliveryScopes.map(\.finishRevocation)
    ScopeStorage.testStates[testIdentifier] = updatedState
    ScopeStorage.condition.unlock()
    revocations.forEach { $0() }
    ScopeStorage.condition.lock()
}

/// Adds one ordered drain marker per owned delivery queue after cancellation has revoked its callbacks.
private func scheduleAudioDeliveryDrains(for testIdentifier: String, state: TestState) {
    precondition(!state.hasScheduledAudioDeliveryDrains)
    var updatedState = state
    updatedState.hasScheduledAudioDeliveryDrains = true
    updatedState.pendingAudioDeliveryDrainCount = state.audioDeliveryScopes.count
    let queues = state.audioDeliveryScopes.map(\.queue)
    ScopeStorage.testStates[testIdentifier] = updatedState
    ScopeStorage.condition.unlock()
    queues.forEach { queue in
        queue.async {
            audioDeliveryQueueDidDrain(forTestIdentifier: testIdentifier)
        }
    }
    ScopeStorage.condition.lock()
}

/// Accounts for one scope-owned delivery queue reaching its teardown drain marker.
private func audioDeliveryQueueDidDrain(forTestIdentifier testIdentifier: String) {
    ScopeStorage.condition.lock()
    defer { ScopeStorage.condition.unlock() }

    guard var state = ScopeStorage.testStates[testIdentifier] else { return }
    state.pendingAudioDeliveryDrainCount -= 1
    ScopeStorage.testStates[testIdentifier] = state
    ScopeStorage.condition.broadcast()
}
