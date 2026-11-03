import Foundation
import XCTest
@testable import ClipboardTTSApp

/// Proves `receiveOnceLeavingNoCallback` returns a receive that completes in time and, once it
/// returns, leaves no receive callback able to act on the test.
///
/// Every connection here is a `ScriptedRealtimeConnection` the test owns, so nothing touches the
/// network; its callbacks run on its own serial queue, which the test joins with `drain()` before
/// reading anything they wrote, including when the helper is broken and returns early.
final class QuiescentWebSocketReceiveTests: XCTestCase {
    private static let request = URLRequest(url: URL(string: "ws://127.0.0.1:9/quiescent-receive")!)
    /// The bound under test: the wait the helper must establish quiescence after.
    private static let helperTimeout: TimeInterval = 0.2
    /// Bounds a wait for an event that must happen, so a broken helper fails the test, not the run.
    private static let safetyBound: DispatchTimeInterval = .seconds(10)
    /// How long a callback held in flight gives the helper to return, which it must not do.
    /// A correct helper passes however short this is; only a broken one's failure depends on it.
    private static let wrongReturnWindow: DispatchTimeInterval = .seconds(1)

    /// Signalled when this test's helper wait records that it expired. XCTest makes a fresh test
    /// case for every test method, so no test sees another's signal.
    private let expiredWaits = DispatchSemaphore(value: 0)

    override func record(_ issue: XCTIssue) {
        if issue.compactDescription.contains("Exceeded timeout") { expiredWaits.signal() }
        super.record(issue)
    }

    func testAReceiveCompletingBeforeTheDeadlineIsReturnedOnce() {
        // WHY: the gate must not refuse the receive it exists to return. The frame is queued before
        // the helper arms its receive, so the callback is delivered at once and the wait, bounded
        // only for safety, never expires.
        let connection = ScriptedRealtimeConnection(request: Self.request)
        connection.deliver(.success(.string("on time")))
        let probe = ReceiveProbe()

        let result = receiveOnceLeavingNoCallback(
            on: connection, description: "An on-time receive", timeout: TimeInterval(10),
            observer: GatedReceive.Observer(receiveDecided: { probe.enter(recorded: $0); probe.leave() })
        )
        connection.drain()

        XCTAssertTrue(connection.isResumed, "The helper must open the connection before receiving.")
        XCTAssertEqual(probe.decisions, [true], "The on-time receive must have recorded its result once.")
        XCTAssertEqual(Self.text(of: result), "on time", "The helper must return the receive's result.")
    }

    func testAReceiveDeliveredAfterAnExpiredWaitRecordsNothing() {
        // WHY: a connection can complete its receive after the helper has given up on it — a frame
        // already in flight when it was cancelled. Without the gate that callback would write the
        // result and fulfil the expectation after the helper returned. This connection keeps its
        // receive pending through `cancel()`, so the test delivers it once the helper has returned.
        let connection = ScriptedRealtimeConnection(request: Self.request, failsPendingReceiveOnCancel: false)
        let probe = ReceiveProbe()

        let result = receiveExpectingTimeout(on: connection, description: "A late receive",
                                             observer: GatedReceive.Observer(receiveDecided: { recorded in
                                                 probe.enter(recorded: recorded)
                                                 probe.leave()
                                             }))
        let decisionsAtReturn = probe.decisions
        connection.deliver(.success(.string("late")))
        connection.drain()

        XCTAssertEqual(decisionsAtReturn, [], "Nothing was delivered before the helper returned.")
        XCTAssertEqual(probe.decisions, [false], "A receive arriving after the gate closed must record nothing.")
        XCTAssertNil(result, "No result was recorded before the gate closed.")
    }

    func testAReceiveRunningAtTheDeadlineFinishesBeforeTheHelperReturns() {
        // WHY: an expired wait can find the callback already past the gate's decision but not yet
        // done. Without the callback holding the gate until it has fulfilled, the helper would
        // return and the callback would fulfil afterwards. The callback is held between its decision
        // and its fulfilment until the wait has expired, then for as long as the window gives the
        // helper to return wrongly; a correct helper is blocked closing the gate throughout, so it
        // returns only after the release. The wait starts only once the callback is held, so its
        // delivery has no deadline but the safety bound.
        let connection = ScriptedRealtimeConnection(request: Self.request)
        connection.deliver(.success(.string("in flight")))
        let probe = ReceiveProbe()
        let expiredWaits = expiredWaits
        let observer = GatedReceive.Observer(
            receiveDecided: { recorded in
                probe.enter(recorded: recorded)
                if expiredWaits.wait(timeout: .now() + Self.safetyBound) == .timedOut {
                    probe.note("The helper's wait never expired.")
                }
                _ = probe.helperReturned.wait(timeout: .now() + Self.wrongReturnWindow)
                probe.leave()
            },
            beforeWait: {
                if probe.entered.wait(timeout: .now() + Self.safetyBound) == .timedOut {
                    probe.note("The receive was never delivered before the helper's wait.")
                }
            }
        )

        let result = receiveExpectingTimeout(on: connection, description: "A held receive", observer: observer)
        let heldAtReturn = probe.isHeld
        probe.helperReturned.signal()
        // Joins the connection's queue even when a broken helper returned early, so the held
        // callback has finished before anything below reads what it wrote.
        connection.drain()

        XCTAssertFalse(heldAtReturn, "The helper must not return while a receive callback is still running.")
        XCTAssertEqual(probe.decisions, [true], "The receive must have recorded its result once.")
        XCTAssertEqual(probe.notes, [])
        XCTAssertEqual(Self.text(of: result), "in flight",
                       "The helper must return the result its callback recorded before the gate closed.")
    }

    func testTheHelperCancelsAfterItsWaitAndTheCancelledReceiveRecordsNothing() {
        // WHY: cancelling is what makes a still-pending receive complete, so it must come after the
        // wait — sooner, and the cancellation would settle the wait instead of letting it expire —
        // and after the gate closes, so that completion records nothing. This connection fails a
        // pending receive on `cancel()`, as URLSession does.
        let connection = ScriptedRealtimeConnection(request: Self.request)
        let probe = ReceiveProbe()
        let cancelledBeforeWait = LockedValue<Bool?>(nil)
        let observer = GatedReceive.Observer(
            receiveDecided: { recorded in
                probe.enter(recorded: recorded)
                probe.leave()
            },
            beforeWait: { cancelledBeforeWait.withValue { $0 = connection.isCancelled } }
        )

        let result = receiveExpectingTimeout(on: connection, description: "A cancelled receive", observer: observer)
        let cancelledAtReturn = connection.isCancelled
        connection.drain()

        XCTAssertEqual(cancelledBeforeWait.value, false, "The helper must not cancel before its wait.")
        XCTAssertTrue(cancelledAtReturn, "The helper must cancel the connection before it returns.")
        XCTAssertEqual(probe.decisions, [false], "The cancelled receive's completion must record nothing.")
        XCTAssertNil(result, "No result was recorded before the gate closed.")
    }

    /// Runs the helper on `connection` and expects only its own timeout, which every test above
    /// that calls this provokes on purpose.
    private func receiveExpectingTimeout(on connection: ScriptedRealtimeConnection,
                                         description: String,
                                         observer: GatedReceive.Observer)
        -> Result<URLSessionWebSocketTask.Message, Error>? {
        let timeoutOnly = XCTExpectedFailure.Options()
        timeoutOnly.issueMatcher = { issue in
            issue.compactDescription.contains("Exceeded timeout") && issue.compactDescription.contains(description)
        }
        var result: Result<URLSessionWebSocketTask.Message, Error>?
        XCTExpectFailure("The test keeps the receive from completing within the helper's wait.", options: timeoutOnly) {
            result = receiveOnceLeavingNoCallback(on: connection, description: description,
                                                  timeout: Self.helperTimeout, observer: observer)
        }
        return result
    }

    /// The text frame `result` carries, or nil for anything else.
    private static func text(of result: Result<URLSessionWebSocketTask.Message, Error>?) -> String? {
        guard case .success(.string(let text))? = result else { return nil }
        return text
    }
}

/// One test's record of the helper's receive callbacks, written on the connection's queue and read
/// by the test body after joining that queue.
private final class ReceiveProbe: Sendable {
    /// Signalled by the test once the helper has returned.
    let helperReturned = DispatchSemaphore(value: 0)
    /// Signalled when a callback has entered the gate and is being held there.
    let entered = DispatchSemaphore(value: 0)
    private struct State {
        var decisions: [Bool] = []
        var isHeld = false
        var notes: [String] = []
    }

    private let state = LockedValue(State())

    var decisions: [Bool] { state.value.decisions }
    var isHeld: Bool { state.value.isHeld }
    var notes: [String] { state.value.notes }

    func enter(recorded: Bool) {
        state.withValue { state in
            state.decisions.append(recorded)
            state.isHeld = true
        }
        entered.signal()
    }

    func leave() {
        state.withValue { $0.isHeld = false }
    }

    func note(_ note: String) {
        state.withValue { $0.notes.append(note) }
    }
}
