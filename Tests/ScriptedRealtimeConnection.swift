import Foundation
@testable import ClipboardTTSApp

/// A Realtime connection whose frames the test supplies, standing in for a WebSocket task.
///
/// WHY: URL-loading protocols can refuse a WebSocket task but cannot answer one with frames, so
/// `MockURLProtocol` cannot script a Realtime response. This double behaves as the parts of
/// `URLSessionWebSocketTask` the manager relies on: frames are handed out one per `receive`, in the
/// order the test queued them, each on the connection's own serial queue rather than the caller's;
/// and `cancel()` fails a receive that is still waiting, as URLSession does. A connection built with
/// `failsPendingReceiveOnCancel: false` instead keeps that receive waiting, so the test can hand it a
/// frame that was already in flight when the connection was cancelled — the race the manager's
/// ownership check exists for, which an immediate failure would never let a frame reach.
///
/// Every connection belongs to the one test that made its recorder, so nothing it delivers can
/// reach another test, and `drain()` is its quiescence barrier: once it returns, every handler the
/// connection had already started has returned too.
final class ScriptedRealtimeConnection: RealtimeSpeechConnection, @unchecked Sendable {
    typealias Receive = @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void

    /// The handshake request the manager opened this connection with.
    let request: URLRequest
    private let failsPendingReceiveOnCancel: Bool
    private let deliveryQueue = DispatchQueue(label: "com.clipboardtts.tests.realtime-connection")
    private let state = LockedValue(State())

    private struct State {
        var isResumed = false
        var isCancelled = false
        var sentFrames: [String] = []
        var queuedResults: [Result<URLSessionWebSocketTask.Message, Error>] = []
        var pendingReceive: Receive?
    }

    init(request: URLRequest, failsPendingReceiveOnCancel: Bool = true) {
        self.request = request
        self.failsPendingReceiveOnCancel = failsPendingReceiveOnCancel
    }

    var isResumed: Bool { state.withValue { $0.isResumed } }
    var isCancelled: Bool { state.withValue { $0.isCancelled } }
    /// Every text frame the manager sent, in send order.
    var sentFrames: [String] { state.withValue { $0.sentFrames } }
    /// The sent frames decoded as JSON objects.
    var sentEvents: [[String: Any]] {
        sentFrames.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    func resume() {
        state.withValue { $0.isResumed = true }
    }

    func send(_ text: String, completionHandler: @escaping @Sendable (Error?) -> Void) {
        state.withValue { $0.sentFrames.append(text) }
        deliveryQueue.async { completionHandler(nil) }
    }

    func receive(completionHandler: @escaping Receive) {
        let next = state.withValue { state -> Result<URLSessionWebSocketTask.Message, Error>? in
            if state.isCancelled {
                return .failure(URLError(.cancelled))
            }
            guard !state.queuedResults.isEmpty else {
                state.pendingReceive = completionHandler
                return nil
            }
            return state.queuedResults.removeFirst()
        }
        if let next {
            deliveryQueue.async { completionHandler(next) }
        }
    }

    func cancel() {
        let failsPendingReceive = failsPendingReceiveOnCancel
        let pending = state.withValue { state -> Receive? in
            state.isCancelled = true
            guard failsPendingReceive else { return nil }
            defer { state.pendingReceive = nil }
            return state.pendingReceive
        }
        if let pending {
            deliveryQueue.async { pending(.failure(URLError(.cancelled))) }
        }
    }

    /// Queues one frame or connection error for the next `receive`, or delivers it to the one waiting,
    /// including one a cancelled connection kept waiting.
    func deliver(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
        let pending = state.withValue { state -> Receive? in
            guard let pending = state.pendingReceive else {
                state.queuedResults.append(result)
                return nil
            }
            state.pendingReceive = nil
            return pending
        }
        if let pending {
            deliveryQueue.async { pending(result) }
        }
    }

    /// Queues one server event, encoded as the JSON text frame the API sends.
    func deliverEvent(_ event: [String: Any]) {
        // swiftlint:disable:next force_try
        let data = try! JSONSerialization.data(withJSONObject: event)
        deliver(.success(.string(String(bytes: data, encoding: .utf8)!)))
    }

    /// Queues one audio delta carrying `pcm`.
    func deliverAudio(_ pcm: Data) {
        deliverEvent(["type": "response.output_audio.delta", "delta": pcm.base64EncodedString()])
    }

    /// Queues the `response.done` that ends a response with `status`.
    func deliverResponseDone(status: String = "completed") {
        deliverEvent(["type": "response.done", "response": ["status": status]])
    }

    /// Waits until every handler this connection has already started has returned.
    func drain() {
        deliveryQueue.sync {}
    }
}

/// Opens one `ScriptedRealtimeConnection` per Realtime request a manager starts, and keeps them in
/// order, so a test can script the connection its action opened.
final class ScriptedRealtimeConnections: @unchecked Sendable {
    private let connections = LockedValue([ScriptedRealtimeConnection]())
    private let failsPendingReceiveOnCancel: Bool
    /// Called with each connection as it is opened, before the manager uses it.
    private let opened: @Sendable (ScriptedRealtimeConnection) -> Void

    init(failsPendingReceiveOnCancel: Bool = true,
         opened: @escaping @Sendable (ScriptedRealtimeConnection) -> Void = { _ in }) {
        self.failsPendingReceiveOnCancel = failsPendingReceiveOnCancel
        self.opened = opened
    }

    /// The factory to hand `TestNetworkFactory.makeManager`.
    var factory: @Sendable (URLSession, URLRequest) -> RealtimeSpeechConnection {
        { [self] _, request in
            let connection = ScriptedRealtimeConnection(request: request,
                                                        failsPendingReceiveOnCancel: failsPendingReceiveOnCancel)
            connections.withValue { $0.append(connection) }
            opened(connection)
            return connection
        }
    }

    var all: [ScriptedRealtimeConnection] { connections.withValue { $0 } }

    /// Drains every connection opened so far.
    func drain() {
        all.forEach { $0.drain() }
    }
}
