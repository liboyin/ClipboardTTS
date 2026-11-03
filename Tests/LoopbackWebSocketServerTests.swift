import Network
import XCTest
@testable import ClipboardTTSApp

/// The shutdown rules `LoopbackWebSocketServer` keeps, checked on the ledger value directly.
final class LoopbackServerLedgerTests: XCTestCase {
    func testALedgerThatNeverStartedAListenerIsQuiescent() {
        XCTAssertTrue(LoopbackServerLedger().isQuiescent)
    }

    func testTheLedgerIsBusyUntilTheListenerAndEveryAcceptedConnectionReportCancellation() {
        var ledger = LoopbackServerLedger()
        ledger.listenerStarted()
        XCTAssertFalse(ledger.isQuiescent, "A live listener can still accept a connection.")
        let first = ledger.accept()
        let second = ledger.accept()
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertFalse(ledger.receiveCompleted(on: first.id, succeeded: false))
        XCTAssertFalse(ledger.receiveCompleted(on: second.id, succeeded: false))
        ledger.stop()
        ledger.listenerCancelled()
        XCTAssertFalse(ledger.isQuiescent, "Stopping the listener does not stop its connections.")
        ledger.connectionCancelled(first.id)
        XCTAssertFalse(ledger.isQuiescent, "One connection has not reported cancellation.")
        ledger.connectionCancelled(second.id)
        XCTAssertTrue(ledger.isQuiescent)
    }

    func testAnOutstandingReceiveKeepsTheLedgerBusyAfterEveryCancellation() {
        var ledger = LoopbackServerLedger()
        ledger.listenerStarted()
        let connection = ledger.accept()
        XCTAssertTrue(connection.armsReceive)
        ledger.stop()
        ledger.listenerCancelled()
        ledger.connectionCancelled(connection.id)
        XCTAssertFalse(ledger.isQuiescent, "A cancelled connection's armed receive can still complete.")
        XCTAssertFalse(
            ledger.receiveCompleted(on: connection.id, succeeded: true),
            "A receive completing after stopping began is neither recorded nor re-armed."
        )
        XCTAssertTrue(ledger.isQuiescent)
        XCTAssertEqual(ledger.receivesArmed, 1)
    }

    func testOnlyASuccessfulReceiveBeforeStoppingIsRecordedAndRearmed() {
        var ledger = LoopbackServerLedger()
        let connection = ledger.accept()
        XCTAssertTrue(connection.armsReceive)
        XCTAssertTrue(ledger.receiveCompleted(on: connection.id, succeeded: true))
        XCTAssertEqual(ledger.receivesArmed, 2)
        XCTAssertFalse(ledger.receiveCompleted(on: connection.id, succeeded: false))
        XCTAssertEqual(ledger.receivesArmed, 2, "A failed receive is not re-armed.")
        ledger.connectionCancelled(connection.id)
        XCTAssertTrue(ledger.isQuiescent)
    }

    func testAConnectionAcceptedAfterStoppingIsNotArmedAndStopsOnItsCancellation() {
        var ledger = LoopbackServerLedger()
        ledger.listenerStarted()
        ledger.stop()
        let connection = ledger.accept()
        XCTAssertFalse(connection.armsReceive)
        XCTAssertEqual(ledger.receivesArmed, 0)
        ledger.listenerCancelled()
        XCTAssertFalse(ledger.isQuiescent, "The late connection has not reported cancellation.")
        ledger.connectionCancelled(connection.id)
        XCTAssertTrue(ledger.isQuiescent, "A late connection leaves no receive to wait for.")
    }
}

/// `LoopbackWebSocketServer`'s shutdown, observed with a real loopback client.
///
/// WHY: the ledger's rules matter only if the server feeds it every Network.framework callback.
/// These tests hold chosen callbacks back through the server's interceptor, so the order in which
/// cancellations and receive completions reach the ledger is the test's rather than the network's.
/// Every connection targets the `127.0.0.1` literal. No callback touches XCTest: the interceptor and
/// the client only record into locked state or signal. Teardown releases held callbacks, then waits
/// for the server and the client to stop, under the same bounds as `RealtimeSpeechConnectionTests`.
final class LoopbackWebSocketServerTests: XCTestCase {
    func testAServerNeverStartedReportsStopped() {
        let server = LoopbackWebSocketServer()
        XCTAssertTrue(server.awaitStopped(timeout: 0))
        server.requestStop()
        XCTAssertTrue(server.awaitStopped(timeout: 0))
    }

    func testAFullyStoppedServerReportsStoppedAndStaysStopped() throws {
        let (server, port) = try makeServer()
        let client = try connectClient(to: port)
        XCTAssertTrue(client.sendText("hello", timeout: 2.0))
        XCTAssertEqual(server.waitForFirstFrame(timeout: 2.0), .text("hello"))
        XCTAssertFalse(server.awaitStopped(timeout: 0), "A server still listening has not stopped.")

        server.requestStop()
        XCTAssertTrue(server.awaitStopped(timeout: 2.0))
        server.requestStop()
        XCTAssertTrue(server.awaitStopped(timeout: 0), "Repeating a stop keeps the server stopped.")
        XCTAssertTrue(server.awaitStopped(timeout: 0))
        XCTAssertEqual(
            server.receivedFrames,
            [.text("hello")],
            "The receive that cancellation completes is not a frame."
        )
        XCTAssertEqual(server.ledgerSnapshot.receivesArmed, 2, "No receive is armed once stopping begins.")
    }

    func testAHeldConnectionCancellationKeepsShutdownIncompleteUntilReleased() throws {
        let callbacks = CallbackObserver(holding: [.connectionCancelled])
        let (server, port) = try makeServer(interceptor: callbacks.interceptor)
        _ = try connectClient(to: port)
        XCTAssertTrue(callbacks.waitForArrival(of: [.newConnection], timeout: 2.0))

        server.requestStop()
        XCTAssertTrue(callbacks.waitForArrival(of: [.listenerCancelled, .connectionCancelled], timeout: 2.0))
        XCTAssertFalse(
            server.awaitStopped(timeout: 0.1),
            "A stopped listener does not mean its connection has stopped."
        )
        XCTAssertFalse(server.ledgerSnapshot.isQuiescent, "The ledger counts the connection until its cancellation runs.")

        server.releaseHeldCallbacks()
        XCTAssertTrue(server.awaitStopped(timeout: 2.0))
    }

    func testAHeldReceiveCompletionKeepsShutdownIncompleteAndIsNotRecorded() throws {
        let callbacks = CallbackObserver(holding: [.receiveCompleted])
        let (server, port) = try makeServer(interceptor: callbacks.interceptor)
        let client = try connectClient(to: port)
        XCTAssertTrue(client.sendText("late", timeout: 2.0))
        XCTAssertTrue(callbacks.waitForArrival(of: [.receiveCompleted], timeout: 2.0))

        server.requestStop()
        XCTAssertTrue(callbacks.waitForArrival(of: [.listenerCancelled, .connectionCancelled], timeout: 2.0))
        XCTAssertFalse(
            server.awaitStopped(timeout: 0.1),
            "Every cancellation is in, but a receive completion is still outstanding."
        )
        XCTAssertFalse(server.ledgerSnapshot.isQuiescent, "The ledger counts the receive until its completion runs.")

        server.releaseHeldCallbacks()
        XCTAssertTrue(server.awaitStopped(timeout: 2.0))
        XCTAssertEqual(server.receivedFrames, [], "A receive completing after stopping began records nothing.")
        XCTAssertEqual(server.ledgerSnapshot.receivesArmed, 1, "A receive completing after stopping is not re-armed.")
    }

    func testAHeldNewConnectionKeepsShutdownIncompleteAfterTheListenerStops() throws {
        // WHY: a connection the listener has handed over but the server has not yet accepted is
        // not in the ledger, so only counting the held delivery keeps shutdown from reporting
        // success while that connection is still to be started and cancelled.
        let callbacks = CallbackObserver(holding: [.newConnection])
        let (server, port) = try makeServer(interceptor: callbacks.interceptor)
        _ = try connectClient(to: port)
        XCTAssertTrue(callbacks.waitForArrival(of: [.newConnection], timeout: 2.0))

        server.requestStop()
        XCTAssertTrue(callbacks.waitForArrival(of: [.listenerCancelled], timeout: 2.0))
        XCTAssertFalse(
            server.awaitStopped(timeout: 0.1),
            "A held accepted connection keeps shutdown incomplete after the listener stops."
        )

        server.releaseHeldCallbacks()
        XCTAssertTrue(server.awaitStopped(timeout: 2.0), "The released connection is cancelled and reports it.")
        XCTAssertEqual(server.ledgerSnapshot.receivesArmed, 0, "A connection accepted after stopping is never armed.")
    }

    func testAConnectionAcceptedAfterStopIsCancelledWithoutBeingArmed() throws {
        // WHY: holding the listener's cancellation too delivers both in the order the probe in
        // `LoopbackWebSocketServer`'s documentation observed: the late connection first.
        let callbacks = CallbackObserver(holding: [.newConnection, .listenerCancelled])
        let (server, port) = try makeServer(interceptor: callbacks.interceptor)
        _ = try connectClient(to: port)
        XCTAssertTrue(callbacks.waitForArrival(of: [.newConnection], timeout: 2.0))

        server.requestStop()
        XCTAssertTrue(callbacks.waitForArrival(of: [.listenerCancelled], timeout: 2.0))
        XCTAssertFalse(server.awaitStopped(timeout: 0.1), "The listener's cancellation is held.")

        server.releaseHeldCallbacks()
        XCTAssertTrue(server.awaitStopped(timeout: 2.0), "The late connection is cancelled and reports it.")
        XCTAssertEqual(server.ledgerSnapshot.receivesArmed, 0, "A connection accepted after stopping is never armed.")
        XCTAssertFalse(
            callbacks.arrivals.contains(.receiveCompleted),
            "No receive completes, because the server armed none, counted or not."
        )
        XCTAssertEqual(server.receivedFrames, [])
    }

    /// Starts a server whose teardown, registered first, releases its held callbacks and waits for
    /// it to stop.
    private func makeServer(
        interceptor: LoopbackWebSocketServer.Interceptor? = nil
    ) throws -> (server: LoopbackWebSocketServer, port: UInt16) {
        let server = LoopbackWebSocketServer(interceptor: interceptor)
        addTeardownBlock {
            server.releaseHeldCallbacks()
            server.requestStop()
            finishStoppingOrEndRun("The loopback server", awaitStopped: server.awaitStopped(timeout:))
        }
        return (server, try server.start(timeout: 2.0))
    }

    private func connectClient(to port: UInt16) throws -> LoopbackWebSocketClient {
        let client = LoopbackWebSocketClient(url: try XCTUnwrap(URL(string: "ws://127.0.0.1:\(port)/")))
        addTeardownBlock {
            client.cancel()
            finishStoppingOrEndRun("The loopback client", awaitStopped: client.awaitCancelled(timeout:))
        }
        return client
    }
}

/// An interceptor that records each callback's arrival and holds every callback of the kinds given.
private final class CallbackObserver: Sendable {
    private let holding: Set<LoopbackWebSocketServer.Callback>
    private let arrived = LockedValue(Set<LoopbackWebSocketServer.Callback>())
    private let arrival = DispatchSemaphore(value: 0)

    init(holding: Set<LoopbackWebSocketServer.Callback>) {
        self.holding = holding
    }

    var interceptor: LoopbackWebSocketServer.Interceptor {
        { [self] callback in
            arrived.withValue { _ = $0.insert(callback) }
            arrival.signal()
            return holding.contains(callback)
        }
    }

    /// Every kind of callback that has arrived so far, held or not.
    var arrivals: Set<LoopbackWebSocketServer.Callback> {
        arrived.value
    }

    /// Waits until a callback of each kind given has arrived, held or not.
    func waitForArrival(of callbacks: Set<LoopbackWebSocketServer.Callback>, timeout: TimeInterval) -> Bool {
        let deadline = DispatchTime.now() + timeout
        while !callbacks.isSubset(of: arrived.value) {
            guard arrival.wait(timeout: deadline) == .success else { return false }
        }
        return true
    }
}

/// A WebSocket client connection whose callbacks run on a serial queue it owns, so its shutdown can
/// be waited for. It arms no receive; its only callbacks are state updates and send completions,
/// which only signal.
private final class LoopbackWebSocketClient: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.clipboardtts.tests.loopback-websocket-client", qos: .userInteractive)
    private let connection: NWConnection
    private let cancelled = DispatchSemaphore(value: 0)

    init(url: URL) {
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
        connection = NWConnection(to: .url(url), using: parameters)
        connection.stateUpdateHandler = { [cancelled] state in
            if case .cancelled = state {
                cancelled.signal()
            }
        }
        connection.start(queue: queue)
    }

    /// Sends one text frame and reports whether the transport took it within `timeout`.
    func sendText(_ text: String, timeout: TimeInterval) -> Bool {
        let sent = DispatchSemaphore(value: 0)
        let context = NWConnection.ContentContext(
            identifier: "text",
            metadata: [NWProtocolWebSocket.Metadata(opcode: .text)]
        )
        connection.send(
            content: Data(text.utf8),
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { _ in sent.signal() }
        )
        return sent.wait(timeout: .now() + timeout) == .success
    }

    func cancel() {
        connection.cancel()
    }

    /// Reports whether the connection confirmed cancellation, then drains its queue. Once it has
    /// returned true, later calls do too.
    func awaitCancelled(timeout: TimeInterval) -> Bool {
        guard cancelled.wait(timeout: .now() + timeout) == .success else { return false }
        cancelled.signal()
        queue.sync {}
        return true
    }
}
