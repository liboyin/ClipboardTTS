import Foundation
import XCTest
@testable import ClipboardTTSApp

/// Records the mock-routed attempts of one logical request so a test can count and compare them.
///
/// Attempts are recorded on the URL-protocol thread and read on the test thread, so the log owns a
/// lock rather than relying on the test's own ordering.
final class RequestAttemptLog: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts: [URLRequest] = []

    /// Records one attempt and returns its 1-based position, which is how a handler answers each attempt differently.
    @discardableResult
    func record(_ request: URLRequest) -> Int {
        lock.lock()
        defer { lock.unlock() }
        attempts.append(request)
        return attempts.count
    }

    var recorded: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return attempts
    }

    var count: Int { recorded.count }
}

/// Records the PCM a request's handler delivered so a test can assert it once the audio queue drains.
///
/// Deliveries arrive on the manager's audio-delivery queue and are read on the test thread, so the
/// log owns the value rather than leaving a `var` for a `@Sendable` handler to mutate.
final class DeliveredAudioLog: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data] = []

    func record(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        chunks.append(chunk)
    }

    var recorded: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return chunks
    }
}

/// Points a manager at the native Gemini provider whose transient failure the retry tests exercise.
func configureGeminiProvider(_ manager: TTSNetworkManager) {
    manager.updateSettings(
        baseURL: "https://generativelanguage.googleapis.com/v1beta",
        apiKey: "fake-gemini-key",
        model: "gemini-3.1-flash-tts-preview",
        voice: "Aoede",
        selectedProvider: "Gemini"
    )
}

/// Builds one complete Server-Sent Event carrying base64 `inlineData` audio.
func geminiAudioEvent(_ audio: Data) -> Data {
    let prefix = "data: {\"candidates\":[{\"content\":{\"parts\":[{\"inlineData\":{\"data\":\""
    return Data("\(prefix)\(audio.base64EncodedString())\"}}]}}]}\r\n\r\n".utf8)
}

/// Builds the response a mock handler returns for one request.
func mockHTTPResponse(for request: URLRequest, statusCode: Int) -> HTTPURLResponse {
    guard let url = request.url,
          let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil) else {
        preconditionFailure("A mock-routed request must carry a URL that can answer with a response.")
    }
    return response
}

/// Builds the response a test hands directly to the session delegate for an in-flight task.
func mockHTTPResponse(for task: URLSessionDataTask, statusCode: Int) -> HTTPURLResponse {
    guard let request = task.currentRequest else {
        preconditionFailure("A started task must retain the request it sent.")
    }
    return mockHTTPResponse(for: request, statusCode: statusCode)
}
