import Foundation
import XCTest
@testable import ClipboardTTSApp

/// Proves `sendOneRoutedRequestLeavingNoCompletion` sends only through a routed configuration and,
/// once it returns, leaves no completion able to act on the test.
///
/// Every request targets a loopback literal and is routed through `RefusingURLProtocol`, which
/// fails it locally without I/O and holds no state, so no protocol here needs per-test ownership;
/// the test-owned protocol below is never loaded. Each test owns whatever it shares with the
/// helper's delivery queue and joins that queue before reading it, including when the helper is
/// broken and returns early.
final class QuiescentRequestTests: XCTestCase {
    private static let loopbackRequest = URLRequest(url: URL(string: "http://127.0.0.1:9/quiescent-request")!)
    /// The bound under test: the wait the helper must establish quiescence after.
    private static let helperTimeout: TimeInterval = 0.2
    /// Bounds a wait for an event that must happen, so a broken helper fails the test, not the run.
    private static let safetyBound: DispatchTimeInterval = .seconds(10)
    /// How long a completion held in flight gives the helper to return, which it must not do.
    /// A correct helper passes however short this is; only a broken one's failure depends on it.
    private static let wrongReturnWindow: DispatchTimeInterval = .seconds(1)

    /// Signalled when this test's helper wait records that it expired. XCTest makes a fresh test
    /// case for every test method, so no test sees another's signal.
    private let expiredWaits = DispatchSemaphore(value: 0)

    override func record(_ issue: XCTIssue) {
        if issue.compactDescription.contains("Exceeded timeout") { expiredWaits.signal() }
        super.record(issue)
    }

    func testACompletionRunningAtTheBarrierFinishesBeforeTheHelperReturns() {
        // WHY: an expired wait can find the completion already past the gate but not yet done.
        // Without the barrier the helper would return and the completion would fulfil afterwards.
        // The completion is held between its decision and its fulfilment until the wait has
        // expired, then for as long as the window gives the helper to return wrongly; a correct
        // helper is blocked in its barrier throughout, so it returns only after the release. The
        // wait starts only once the completion is held, so its delivery has no deadline but the
        // safety bound.
        let probe = DeliveryProbe()
        let expiredWaits = expiredWaits
        var deliveryQueue: OperationQueue?
        let observer = RoutedRequest.Observer(
            sessionCreated: { deliveryQueue = $0.delegateQueue },
            completionDecided: { recorded in
                probe.enter(recorded: recorded)
                if expiredWaits.wait(timeout: .now() + Self.safetyBound) == .timedOut {
                    probe.note("The helper's wait never expired.")
                }
                _ = probe.helperReturned.wait(timeout: .now() + Self.wrongReturnWindow)
                probe.leave()
            },
            beforeWait: {
                if probe.entered.wait(timeout: .now() + Self.safetyBound) == .timedOut {
                    probe.note("The completion was never delivered before the helper's wait.")
                }
            }
        )

        let outcome = sendExpectingTimeout(observer: observer, description: "A held completion") as NSError?
        let heldAtReturn = probe.isHeld
        probe.helperReturned.signal()
        // Joins the delivery queue even when a broken helper returned early, so the held
        // completion has finished before anything below reads what it wrote.
        deliveryQueue?.underlyingQueue?.sync {}

        XCTAssertFalse(heldAtReturn, "The helper must not return while a completion is still running.")
        XCTAssertEqual(probe.decisions, [true], "The completion must have recorded its outcome once.")
        XCTAssertEqual(probe.notes, [])
        XCTAssertEqual(outcome?.localizedDescription, RefusingURLProtocol.refusalDescription,
                       "The helper must return the outcome its completion recorded before the barrier.")
    }

    func testACompletionDeliveredAfterTheBarrierRecordsNothing() {
        // WHY: cancelling the task can deliver its completion after the helper's barrier. Without
        // the gate that completion would write the outcome and fulfil the expectation after the
        // helper returned. Suspending the delegate queue holds every delivery until the helper has
        // returned; the barrier runs on the underlying queue, which a suspended queue leaves free.
        let probe = DeliveryProbe()
        var deliveryQueue: OperationQueue?
        let observer = RoutedRequest.Observer(
            sessionCreated: { session in
                session.delegateQueue.isSuspended = true
                deliveryQueue = session.delegateQueue
            },
            completionDecided: { recorded in
                probe.enter(recorded: recorded)
                probe.leave()
            }
        )

        let outcome = sendExpectingTimeout(observer: observer, description: "A late completion")
        let decisionsAtReturn = probe.decisions
        deliveryQueue?.isSuspended = false
        let delivered = probe.delivered.wait(timeout: .now() + Self.safetyBound) == .success
        // An undelivered completion stays held on the suspended queue, so it can never act at all.
        if !delivered { deliveryQueue?.isSuspended = true }
        deliveryQueue?.underlyingQueue?.sync {}

        XCTAssertNotNil(deliveryQueue, "The helper must have sent the request.")
        XCTAssertEqual(decisionsAtReturn, [], "Nothing may be delivered while the delegate queue is suspended.")
        XCTAssertTrue(delivered, "The request's completion must be delivered once its queue resumes.")
        XCTAssertEqual(probe.decisions, [false], "A completion arriving after the barrier must record nothing.")
        XCTAssertNil(outcome, "No outcome was recorded before the barrier.")
    }

    func testAnUnroutedConfigurationIsRefusedBeforeAnySessionExists() {
        // WHY: with no routing the session would load the request through the system's own HTTP
        // loader. The production policy without routing is what a test is most likely to pass.
        assertRefusedWithoutASession(TTSNetworkManager.sessionConfiguration(routing: nil))
    }

    func testASystemProtocolFirstIsRefusedEvenThoughItClaimsTheRequest() throws {
        // WHY: claiming the request is not enough when the claimant is the system's own loader.
        // The system's first default protocol declines this request, so this places the one that
        // claims it first, ahead of a protocol that would refuse it locally.
        let systemProtocols = (URLSessionConfiguration.ephemeral.protocolClasses ?? []).compactMap { $0 as? URLProtocol.Type }
        let claimant = try XCTUnwrap(systemProtocols.first { $0.canInit(with: Self.loopbackRequest) },
                                     "A system protocol must claim an http loopback request for this test to mean anything.")
        assertRefusedWithoutASession(TTSNetworkManager.sessionConfiguration(
            routing: TTSNetworkManager.SessionRouting(protocolClasses: [claimant, RefusingURLProtocol.self])
        ))
    }

    func testATestProtocolThatDeclinesTheRequestIsRefused() {
        // WHY: a first protocol that declines passes the request down the list, and from there to
        // the system's loaders; the refusing protocol behind it here keeps even that on the machine.
        assertRefusedWithoutASession(TTSNetworkManager.sessionConfiguration(
            routing: TTSNetworkManager.SessionRouting(protocolClasses: [DecliningURLProtocol.self, RefusingURLProtocol.self])
        ))
    }

    func testRefusingAndMockRoutingAreRouted() {
        // WHY: the check must not refuse the routings tests actually send through: the hosted
        // graph's refusal and the factory's mock. This asks the check alone, so nothing is sent.
        let routings = [
            TTSNetworkManager.SessionRouting.refusingEveryRequest,
            TTSNetworkManager.SessionRouting(protocolClasses: [MockURLProtocol.self],
                                             additionalHeaders: [MockURLProtocol.testIdentifierHeader: name])
        ]
        for routing in routings {
            XCTAssertTrue(RoutedRequest.isRouted(Self.loopbackRequest,
                                                 through: TTSNetworkManager.sessionConfiguration(routing: routing)),
                          "\(routing.protocolClasses) must count as routed.")
        }
    }

    /// Sends the loopback request through the refusing routing and expects only the helper's own
    /// timeout, which every test above that calls this provokes on purpose.
    private func sendExpectingTimeout(observer: RoutedRequest.Observer, description: String) -> Error? {
        let timeoutOnly = XCTExpectedFailure.Options()
        timeoutOnly.issueMatcher = { issue in
            issue.compactDescription.contains("Exceeded timeout") && issue.compactDescription.contains(description)
        }
        var outcome: Error?
        XCTExpectFailure("The test holds the completion past the helper's wait.", options: timeoutOnly) {
            outcome = sendOneRoutedRequestLeavingNoCompletion(
                Self.loopbackRequest,
                configuration: TTSNetworkManager.sessionConfiguration(routing: .refusingEveryRequest),
                description: description,
                timeout: Self.helperTimeout,
                observer: observer
            )
        }
        return outcome
    }

    /// Asserts the helper records its own refusal for `configuration` and creates no session, so
    /// no task exists to send anything.
    private func assertRefusedWithoutASession(_ configuration: URLSessionConfiguration,
                                              file: StaticString = #filePath,
                                              line: UInt = #line) {
        let refusalOnly = XCTExpectedFailure.Options()
        refusalOnly.issueMatcher = { $0.compactDescription.contains(RoutedRequest.unroutedConfigurationFailure) }
        var sessionsCreated = 0
        var outcome: Error?
        XCTExpectFailure("The helper must refuse a configuration that is not routed.", options: refusalOnly) {
            outcome = sendOneRoutedRequestLeavingNoCompletion(
                Self.loopbackRequest,
                configuration: configuration,
                description: "An unrouted request",
                timeout: 2.0,
                observer: RoutedRequest.Observer(sessionCreated: { _ in sessionsCreated += 1 })
            )
        }
        XCTAssertEqual(sessionsCreated, 0, "A refused configuration must not get a session.", file: file, line: line)
        XCTAssertNil(outcome, file: file, line: line)
    }
}

/// One test's record of the helper's completion, written on the helper's delivery queue and read
/// by the test body after joining that queue.
private final class DeliveryProbe: Sendable {
    /// Signalled by the test once the helper has returned.
    let helperReturned = DispatchSemaphore(value: 0)
    /// Signalled when a completion has entered, holding the helper's delivery queue.
    let entered = DispatchSemaphore(value: 0)
    /// Signalled when a completion has finished deciding.
    let delivered = DispatchSemaphore(value: 0)
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
        delivered.signal()
    }

    func note(_ note: String) {
        state.withValue { $0.notes.append(note) }
    }
}

/// Declines every request, so a configuration listing it first is not routed. Never loaded.
private final class DecliningURLProtocol: URLProtocol {
    override static func canInit(with request: URLRequest) -> Bool {
        false
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {}

    override func stopLoading() {}
}
