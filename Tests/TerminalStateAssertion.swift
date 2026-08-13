import Foundation
import XCTest
import Combine
@testable import ClipboardTTSApp

/// Returns whether a published state is the expected terminal state for an observed request.
///
/// `isPostActionPublication` is false while the subscription replays the manager's state from
/// before the action, so neither an idle manager nor an earlier request's matching failure can
/// satisfy an assertion that claims to observe the action's own request.
func matchesExpectedTerminalState(error: String?,
                                  isStreaming: Bool,
                                  expectedError: String?,
                                  observedActiveRequest: Bool,
                                  isPostActionPublication: Bool) -> Bool {
    guard isPostActionPublication else { return false }
    return error == expectedError && !isStreaming && (expectedError != nil || observedActiveRequest)
}

extension XCTestCase {
    /// Waits for a request to publish its expected terminal state instead of relying on a timing delay.
    func assertTerminalState(of manager: TTSNetworkManager,
                             expectedError: String?,
                             after action: () -> Void) {
        XCTAssertTrue(
            awaitTerminalState(of: manager, expectedError: expectedError, after: action),
            """
            The action never published the terminal state \
            \(expectedError.map { "\"\($0)\"" } ?? "success") for the request it starts.
            """
        )
    }

    /// Reports whether the action publishes the expected terminal state.
    ///
    /// A state that simply does not match returns `false` without failing the test, which is what
    /// lets a negative regression inspect the result. A violated precondition is different: an
    /// off-main call site, or a drain that cannot be established, fails closed.
    ///
    /// State published before the action — the value Combine replays when this helper subscribes,
    /// and any publication an earlier request had already queued — never settles the wait, so an
    /// assertion cannot inherit another request's outcome. A negative regression inspects the
    /// returned flag; `assertTerminalState` asserts it.
    ///
    /// Call this from the main thread. `observedActiveRequest`, `actionDidStart`, and `didSettle`
    /// are written here and read inside a sink that Combine delivers on the main queue, so only a
    /// main-thread caller orders those accesses. The guard below fails loudly instead of racing,
    /// because a racing helper would settle on an arbitrary result and report it as a verdict.
    func awaitTerminalState(of manager: TTSNetworkManager,
                            expectedError: String?,
                            timeout: TimeInterval = 2.0,
                            after action: () -> Void) -> Bool {
        guard Thread.isMainThread else {
            XCTFail("""
            awaitTerminalState must be called from the main thread. It shares mutable observation \
            state with a sink Combine delivers on the main queue, and an off-main caller races it.
            """)
            return false
        }
        guard drainPublicationsQueuedBeforeThisAssertion(timeout: timeout) else { return false }
        let stateSettled = XCTestExpectation(description: "Request reaches its expected terminal state")
        var observedActiveRequest = manager.isStreaming
        var actionDidStart = false
        var didSettle = false
        // Every `lastError`/`isStreaming` mutation publishes on the main queue, and the guard above
        // pins this thread to it, so the `actionDidStart` write below is ordered before any
        // publication the action can cause.
        let observation = Publishers.CombineLatest(manager.$lastError, manager.$isStreaming).sink { error, isStreaming in
            observedActiveRequest = observedActiveRequest || isStreaming
            guard matchesExpectedTerminalState(
                error: error,
                isStreaming: isStreaming,
                expectedError: expectedError,
                observedActiveRequest: observedActiveRequest,
                isPostActionPublication: actionDidStart
            ),
                  !didSettle
            else { return }
            didSettle = true
            stateSettled.fulfill()
        }

        actionDidStart = true
        action()
        let result = XCTWaiter().wait(for: [stateSettled], timeout: timeout)
        observation.cancel()
        return result == .completed
    }

    /// Runs every state publication an earlier request had already queued onto the main queue, and
    /// reports whether that boundary was actually established.
    ///
    /// The manager publishes off-main work through `DispatchQueue.main.async`, so without this the
    /// gate would only be temporal: a stale publication landing during the wait would look like the
    /// action's own terminal state. The main queue is FIFO, so once a block enqueued here has run,
    /// every earlier one has too, and their state belongs to the value the subscription replays.
    /// A caller that proceeds anyway would re-admit that stale publication, so this fails instead.
    ///
    /// The barrier holds only because the sentinel is submitted to the queue those publications
    /// land on, which `DispatchQueue.main.async` establishes on its own. Waiting on the main thread
    /// pumps the run loop, so the sentinel normally runs well inside the timeout; the failure path
    /// below stays as a fail-closed guard for a main queue backlogged past it.
    private func drainPublicationsQueuedBeforeThisAssertion(timeout: TimeInterval) -> Bool {
        let drained = XCTestExpectation(description: "Publications queued before the assertion have run")
        DispatchQueue.main.async {
            drained.fulfill()
        }
        guard XCTWaiter().wait(for: [drained], timeout: timeout) == .completed else {
            XCTFail("""
            Publications queued before this assertion did not run within \(timeout)s, so a stale \
            publication could still settle it. The assertion verified nothing.
            """)
            return false
        }
        return true
    }
}
