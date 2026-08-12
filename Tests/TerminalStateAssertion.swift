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

    /// Reports whether the action publishes the expected terminal state, without failing the test.
    ///
    /// State published before the action — the value Combine replays when this helper subscribes,
    /// and any publication an earlier request had already queued — never settles the wait, so an
    /// assertion cannot inherit another request's outcome. A negative regression inspects the
    /// returned flag; `assertTerminalState` asserts it.
    func awaitTerminalState(of manager: TTSNetworkManager,
                            expectedError: String?,
                            timeout: TimeInterval = 2.0,
                            after action: () -> Void) -> Bool {
        guard drainPublicationsQueuedBeforeThisAssertion(timeout: timeout) else { return false }
        let stateSettled = XCTestExpectation(description: "Request reaches its expected terminal state")
        var observedActiveRequest = manager.isStreaming
        var actionDidStart = false
        var didSettle = false
        // Every `lastError`/`isStreaming` mutation publishes on the main queue, so this thread's
        // `actionDidStart` write is ordered before any publication the action can cause.
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
    /// That failure path is fail-closed rather than exercised: every call site runs on the main
    /// thread, where the waiter cannot expire while the main queue is busy and the sentinel runs as
    /// soon as it is free. Keep the check, because an off-main caller could reach it.
    private func drainPublicationsQueuedBeforeThisAssertion(timeout: TimeInterval) -> Bool {
        let drained = XCTestExpectation(description: "Publications queued before the assertion have run")
        DispatchQueue.main.async {
            // The FIFO barrier only holds while this runs on the queue publications land on. A
            // sentinel on any other queue can fulfill with a publication still pending, and that
            // race resolves differently per test runner, so assert the queue instead of the timing.
            XCTAssertTrue(Thread.isMainThread, "The publication drain must complete on the main queue.")
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
