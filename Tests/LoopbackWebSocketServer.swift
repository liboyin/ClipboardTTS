import Network
import XCTest

/// A WebSocket server on the loopback literal that records the frames it receives, and whose
/// shutdown is complete only when every piece of work it started has stopped.
///
/// Every Network.framework callback runs on the server's own serial queue, updates `ledger` there,
/// and otherwise only records into locked state or signals a semaphore. `requestStop()` marks the
/// server stopping, then cancels the listener and every accepted connection. `awaitStopped(timeout:)`
/// reports success only once the ledger, read on that queue, shows the listener and every accepted
/// connection reported `.cancelled` and no receive is outstanding, and no callback is held.
///
/// WHY each part of that is needed, as observed with a loopback probe on macOS 26.7.1 (25G241) on
/// 2026-11-03:
/// - Cancelling a ready connection completes its pending `receiveMessage` before the connection
///   reports `.cancelled`, with no content, `isComplete` true and no error, so it looks like a
///   successful receive; a receive armed after that, even after `.cancelled`, still completes later,
///   with `ECANCELED`. A connection's `.cancelled` therefore does not imply its receives are done.
/// - `newConnectionHandler` ran for a connection that arrived while the queue was busy even though
///   `listener.cancel()` had already been called, before the listener reported `.cancelled`. So a
///   connection can be accepted after stopping begins; it is started, so that it reports
///   `.cancelled`, then cancelled without ever being armed.
/// - A connection that is cancelled without being started reports no state at all, which is why a
///   late connection is still started.
/// The ledger relies on the listener delivering nothing after its own `.cancelled`, which the probe
/// is consistent with but Network.framework does not document.
final class LoopbackWebSocketServer: @unchecked Sendable {
    enum Frame: Equatable, Sendable {
        case text(String)
        case binary(Data)
        case other(String)
    }

    /// The callbacks whose effect on the ledger a test can hold back.
    enum Callback: Hashable, Sendable {
        case listenerCancelled
        case newConnection
        case connectionCancelled
        case receiveCompleted
    }

    /// Test seam, called on the server's queue as each callback arrives, including after
    /// `releaseHeldCallbacks()`, so a test can observe every arrival: returning true holds that
    /// callback, unrun, until `releaseHeldCallbacks()`, and is ignored once that has run. It must
    /// only record into locked state or signal; it runs on Network.framework's delivery path.
    typealias Interceptor = @Sendable (Callback) -> Bool

    private let queue = DispatchQueue(label: "com.clipboardtts.tests.loopback-websocket", qos: .userInteractive)
    private let interceptor: Interceptor?
    private let frames = LockedValue([Frame]())
    private let frameArrived = DispatchSemaphore(value: 0)
    private let ready = DispatchSemaphore(value: 0)
    /// Signalled after every callback has updated the ledger, so `awaitStopped` re-reads it then.
    private let ledgerChanged = DispatchSemaphore(value: 0)
    /// Read and written only on `queue`.
    private var listener: NWListener?
    /// Read and written only on `queue`.
    private var ledger = LoopbackServerLedger()
    /// Every accepted connection that has not reported `.cancelled`. Read and written only on `queue`.
    private var connections: [Int: NWConnection] = [:]
    /// Callbacks `interceptor` held, in arrival order. Read and written only on `queue`.
    private var heldCallbacks: [() -> Void] = []
    /// False once `releaseHeldCallbacks()` has run. Read and written only on `queue`.
    private var holdsCallbacks = true

    init(interceptor: Interceptor? = nil) {
        self.interceptor = interceptor
    }

    /// Starts listening on an ephemeral `127.0.0.1` port and returns it once the listener is ready.
    func start(timeout: TimeInterval) throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self, ready] state in
            switch state {
            case .ready:
                ready.signal()
            case .cancelled:
                self?.deliver(.listenerCancelled) { $0.ledger.listenerCancelled() }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.deliver(.newConnection) { $0.accept(connection) }
        }
        queue.sync {
            self.listener = listener
            ledger.listenerStarted()
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + timeout) == .success,
              let port = queue.sync(execute: { self.listener?.port?.rawValue }) else {
            throw URLError(.cannotConnectToHost)
        }
        return port
    }

    /// Runs `body` on `queue` now, or holds it if `interceptor` asks, then wakes `awaitStopped`.
    private func deliver(_ callback: Callback, _ body: @escaping (LoopbackWebSocketServer) -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        let holds = interceptor?(callback) == true
        if holdsCallbacks, holds {
            heldCallbacks.append { body(self) }
            return
        }
        body(self)
        ledgerChanged.signal()
    }

    /// Records the connection and starts it; arms its first receive unless stopping has begun, in
    /// which case it is cancelled instead.
    private func accept(_ connection: NWConnection) {
        let (id, armsReceive) = ledger.accept()
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard case .cancelled = state else { return }
            self?.deliver(.connectionCancelled) { server in
                server.connections[id] = nil
                server.ledger.connectionCancelled(id)
            }
        }
        connection.start(queue: queue)
        if armsReceive {
            receive(on: connection, id: id)
        } else {
            connection.cancel()
        }
    }

    /// Calls `receiveMessage`; the ledger has already counted this receive as outstanding.
    private func receive(on connection: NWConnection, id: Int) {
        connection.receiveMessage { [weak self] content, context, _, error in
            self?.deliver(.receiveCompleted) { server in
                guard server.ledger.receiveCompleted(on: id, succeeded: error == nil) else { return }
                server.record(content: content, context: context)
                server.receive(on: connection, id: id)
            }
        }
    }

    private func record(content: Data?, context: NWConnection.ContentContext?) {
        let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
            as? NWProtocolWebSocket.Metadata
        let data = content ?? Data()
        let frame: Frame
        switch metadata?.opcode {
        case .text?:
            frame = .text(String(bytes: data, encoding: .utf8) ?? "")
        case .binary?:
            frame = .binary(data)
        default:
            frame = .other(String(describing: metadata?.opcode))
        }
        frames.withValue { $0.append(frame) }
        frameArrived.signal()
    }

    /// The first frame received, or nil when none arrives in time.
    func waitForFirstFrame(timeout: TimeInterval) -> Frame? {
        guard frameArrived.wait(timeout: .now() + timeout) == .success else { return nil }
        return frames.value.first
    }

    /// Every frame recorded so far.
    var receivedFrames: [Frame] {
        frames.value
    }

    /// The ledger as it stands once every callback already running on the server's queue has returned.
    var ledgerSnapshot: LoopbackServerLedger {
        queue.sync { ledger }
    }

    /// Runs every held callback in arrival order, and holds none from now on.
    func releaseHeldCallbacks() {
        queue.sync {
            holdsCallbacks = false
            let held = heldCallbacks
            heldCallbacks = []
            for callback in held {
                callback()
                ledgerChanged.signal()
            }
        }
    }

    /// Stops accepting work, then cancels the listener and every connection. Safe to repeat.
    func requestStop() {
        queue.sync {
            ledger.stop()
            connections.values.forEach { $0.cancel() }
            listener?.cancel()
        }
    }

    /// Reports whether the listener, every accepted connection, and every receive have stopped,
    /// waiting up to `timeout` for them to. The ledger is read on the server's queue, so a true
    /// result also means no callback is still running there. A server never started has nothing
    /// to stop and reports success. Once it has returned true, later calls do too.
    func awaitStopped(timeout: TimeInterval) -> Bool {
        let deadline = DispatchTime.now() + timeout
        while !queue.sync(execute: { isStopped }) {
            guard ledgerChanged.wait(timeout: deadline) == .success else {
                return queue.sync { isStopped }
            }
        }
        return true
    }

    /// Whether nothing the server started can still act. Read only on `queue`.
    ///
    /// WHY a held callback counts: it is a delivery the ledger has not seen yet. A held new
    /// connection, in particular, is not in the ledger until it runs, so the ledger alone would
    /// report quiescence while that connection is still to be started and cancelled.
    private var isStopped: Bool {
        ledger.isQuiescent && heldCallbacks.isEmpty
    }
}

/// What a `LoopbackWebSocketServer` has started and not yet seen stop, and whether it is stopping.
///
/// A pure value, so its rules are tested directly; the server mutates it only on its own queue.
struct LoopbackServerLedger: Equatable, Sendable {
    private(set) var isStopping = false
    /// Every receive ever armed, including re-arms, so a test can prove one was never armed.
    private(set) var receivesArmed = 0
    private var listenerLive = false
    private var nextConnectionID = 0
    private var liveConnections: Set<Int> = []
    private var outstandingReceives: Set<Int> = []

    /// True once nothing the server started can still call back: the listener (if any) and every
    /// accepted connection reported `.cancelled`, and no receive is outstanding.
    var isQuiescent: Bool {
        !listenerLive && liveConnections.isEmpty && outstandingReceives.isEmpty
    }

    mutating func listenerStarted() {
        listenerLive = true
    }

    mutating func listenerCancelled() {
        listenerLive = false
    }

    mutating func stop() {
        isStopping = true
    }

    /// Records a newly accepted connection and returns its identifier and whether to arm its first
    /// receive, which is false once stopping has begun.
    mutating func accept() -> (id: Int, armsReceive: Bool) {
        let id = nextConnectionID
        nextConnectionID += 1
        liveConnections.insert(id)
        let armsReceive = !isStopping
        if armsReceive {
            arm(id)
        }
        return (id, armsReceive)
    }

    mutating func connectionCancelled(_ id: Int) {
        liveConnections.remove(id)
    }

    /// Settles the connection's outstanding receive and returns whether to record its message and
    /// arm the next: only a successful receive before stopping begins is either.
    mutating func receiveCompleted(on id: Int, succeeded: Bool) -> Bool {
        outstandingReceives.remove(id)
        let accepts = succeeded && !isStopping
        if accepts {
            arm(id)
        }
        return accepts
    }

    private mutating func arm(_ id: Int) {
        outstandingReceives.insert(id)
        receivesArmed += 1
    }
}

/// Waits for an owner to stop, failing the test past the teardown deadline and ending the run
/// past the recovery bound, as `MockURLProtocolTestCase.finishClosingScopeOrEndRun` does.
func finishStoppingOrEndRun(_ owner: String, awaitStopped: (TimeInterval) -> Bool) {
    guard !awaitStopped(2.0) else { return }
    XCTFail("\(owner) did not stop before the test ended.")
    guard awaitStopped(5.0) else {
        fatalError(
            "\(owner) did not stop within the recovery bound; ending the run rather than hand "
                + "a live callback owner to the next test."
        )
    }
}
