import Network
import XCTest
@testable import ClipboardTTSApp

/// The production `URLSessionWebSocketTask` conformance, observed on the wire.
///
/// WHY: every other Realtime test scripts the connection, so the one line that turns a client event
/// into a WebSocket frame runs only against a real server. The Realtime API documents its client
/// events as JSON text frames; a binary frame carrying the same bytes compiles, passes every scripted
/// test, and leaves OpenAI speech broken. This suite is the documented exception to building sessions
/// through `TestNetworkFactory` (README, Build & Test): a URL-loading protocol can refuse a WebSocket
/// but cannot answer one, so the task has to reach a server. That server listens on the `127.0.0.1`
/// literal inside the test process, and the task names that literal, so nothing can leave the machine
/// even if the session's configuration were wrong.
///
/// The test waits on the main thread for work these queues signal, so they run at its QoS rather than
/// inverting priority.
///
/// No callback touches XCTest. Each one only records into test-owned locked state and signals a
/// semaphore, so one that runs late, after a timed-out wait, reaches nothing of the test's. Teardown,
/// registered as each resource is created, waits for the session and the server to report that they
/// have stopped. One that misses its deadline fails the test and is given the recovery bound
/// `MockURLProtocolTestCase` gives a mock scope, and one that misses that too ends the run, because
/// a live callback owner must not be handed to the next test.
final class RealtimeSpeechConnectionTests: XCTestCase {
    func testTheWebSocketAdapterSendsEachClientEventAsATextFrame() throws {
        let server = LoopbackWebSocketServer()
        addTeardownBlock {
            server.requestStop()
            Self.finishOrEndRun("The loopback server", awaitStopped: server.awaitStopped(timeout:))
        }
        let port = try server.start(timeout: 2.0)
        let session = OwnedWebSocketSession.make()
        addTeardownBlock {
            session.requestInvalidation()
            Self.finishOrEndRun("The WebSocket session", awaitStopped: session.awaitInvalidated(timeout:))
        }
        let connection: RealtimeSpeechConnection = session.webSocketTask(
            with: try XCTUnwrap(URL(string: "ws://127.0.0.1:\(port)/v1/realtime"))
        )
        let event = #"{"type":"response.create"}"#
        let sendError = LockedValue<Error?>(nil)
        let sent = DispatchSemaphore(value: 0)

        connection.resume()
        connection.send(event) { error in
            sendError.withValue { $0 = error }
            sent.signal()
        }

        XCTAssertEqual(sent.wait(timeout: .now() + 2.0), .success, "The send must complete.")
        XCTAssertNil(sendError.value)
        XCTAssertEqual(server.waitForFirstFrame(timeout: 2.0), .text(event))
        connection.cancel()
    }

    /// Waits for an owner to stop, failing the test past the teardown deadline and ending the run
    /// past the recovery bound, as `MockURLProtocolTestCase.finishClosingScopeOrEndRun` does.
    private static func finishOrEndRun(_ owner: String, awaitStopped: (TimeInterval) -> Bool) {
        guard !awaitStopped(2.0) else { return }
        XCTFail("\(owner) did not stop before the test ended.")
        guard awaitStopped(5.0) else {
            fatalError(
                "\(owner) did not stop within the recovery bound; ending the run rather than hand "
                    + "a live callback owner to the next test."
            )
        }
    }
}

/// An unrouted session on the production policy whose callbacks run on a serial queue this test
/// owns, so its shutdown can be waited for rather than assumed.
private final class OwnedWebSocketSession: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let callbackQueue = DispatchQueue(label: "com.clipboardtts.tests.owned-websocket-session", qos: .userInteractive)
    private let invalidated = DispatchSemaphore(value: 0)
    /// Assigned once by `make()`, before the owner is shared.
    private var session: URLSession!

    /// Builds the session with this owner as its delegate. A factory rather than an initializer,
    /// because the session needs the finished owner it reports invalidation to.
    static func make() -> OwnedWebSocketSession {
        let owner = OwnedWebSocketSession()
        let operationQueue = OperationQueue()
        operationQueue.maxConcurrentOperationCount = 1
        operationQueue.underlyingQueue = owner.callbackQueue
        owner.session = URLSession(
            configuration: TTSNetworkManager.productionSessionConfiguration(),
            delegate: owner,
            delegateQueue: operationQueue
        )
        return owner
    }

    func webSocketTask(with url: URL) -> URLSessionWebSocketTask {
        session.webSocketTask(with: url)
    }

    /// Cancels every task and invalidates the session.
    func requestInvalidation() {
        session.invalidateAndCancel()
    }

    /// Reports whether the session confirmed its invalidation, which URLSession delivers only after
    /// its tasks' callbacks, then drains the queue those ran on. Once it has returned true, later
    /// calls do too.
    func awaitInvalidated(timeout: TimeInterval) -> Bool {
        guard invalidated.wait(timeout: .now() + timeout) == .success else { return false }
        invalidated.signal()
        callbackQueue.sync {}
        return true
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        invalidated.signal()
    }
}

/// A WebSocket server on the loopback literal that records the frames it receives.
///
/// Every handler runs on the server's own serial queue and only records into locked state or signals
/// a semaphore. `requestStop()` cancels the listener and each connection; `awaitStopped(timeout:)`
/// waits for the listener to report `.cancelled`, then drains that queue.
private final class LoopbackWebSocketServer: @unchecked Sendable {
    enum Frame: Equatable, Sendable {
        case text(String)
        case binary(Data)
        case other(String)
    }

    private let queue = DispatchQueue(label: "com.clipboardtts.tests.loopback-websocket", qos: .userInteractive)
    private let frames = LockedValue([Frame]())
    private let frameArrived = DispatchSemaphore(value: 0)
    private let ready = DispatchSemaphore(value: 0)
    private let cancelled = DispatchSemaphore(value: 0)
    /// Read and written only on `queue`.
    private var listener: NWListener?
    /// Read and written only on `queue`.
    private var connections: [NWConnection] = []

    /// Starts listening on an ephemeral `127.0.0.1` port and returns it once the listener is ready.
    func start(timeout: TimeInterval) throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [ready, cancelled] state in
            switch state {
            case .ready:
                ready.signal()
            case .cancelled:
                cancelled.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.receive(on: connection)
        }
        queue.sync { self.listener = listener }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + timeout) == .success,
              let port = queue.sync(execute: { self.listener?.port?.rawValue }) else {
            throw URLError(.cannotConnectToHost)
        }
        return port
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, context, _, error in
            guard let self, error == nil else { return }
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
            self.frames.withValue { $0.append(frame) }
            self.frameArrived.signal()
            self.receive(on: connection)
        }
    }

    /// The first frame received, or nil when none arrives in time.
    func waitForFirstFrame(timeout: TimeInterval) -> Frame? {
        guard frameArrived.wait(timeout: .now() + timeout) == .success else { return nil }
        return frames.value.first
    }

    /// Cancels the listener and every connection.
    func requestStop() {
        queue.sync {
            connections.forEach { $0.cancel() }
            listener?.cancel()
        }
    }

    /// Reports whether the listener confirmed cancellation, then drains the server's queue. A server
    /// that never created a listener has nothing to cancel and reports success. Once it has returned
    /// true, later calls do too.
    func awaitStopped(timeout: TimeInterval) -> Bool {
        let hadListener = queue.sync { listener != nil }
        if hadListener {
            guard cancelled.wait(timeout: .now() + timeout) == .success else { return false }
            cancelled.signal()
        }
        queue.sync {}
        return true
    }
}
