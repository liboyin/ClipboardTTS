import Foundation

/// One Realtime speech connection: the three operations a request needs from a WebSocket.
///
/// `URLSessionWebSocketTask` is the production conformance, built from the manager's own session
/// so the ephemeral session policy and any caller routing apply to it as they do to an HTTP request.
/// The protocol exists because URL-loading protocols can refuse a WebSocket task but cannot answer
/// it with frames, so a test drives the request's event handling through a scripted connection.
protocol RealtimeSpeechConnection: AnyObject, Sendable {
    /// Opens the connection.
    func resume()
    /// Queues one text frame. Frames are sent in the order they are queued.
    func send(_ text: String, completionHandler: @escaping @Sendable (Error?) -> Void)
    /// Delivers the next frame, or the error that ended the connection.
    func receive(completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void)
    /// Closes the connection. A receive still pending completes with an error afterwards.
    func cancel()
}

extension URLSessionWebSocketTask: RealtimeSpeechConnection {
    func send(_ text: String, completionHandler: @escaping @Sendable (Error?) -> Void) {
        send(.string(text), completionHandler: completionHandler)
    }
}
