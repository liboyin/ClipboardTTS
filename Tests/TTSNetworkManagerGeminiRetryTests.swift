import Combine
import XCTest
@testable import ClipboardTTSApp

/// Covers the one provider failure the app recovers from automatically.
final class TTSNetworkManagerGeminiRetryTests: MockURLProtocolTestCase {
    func testTransientGeminiServerErrorIsRetriedInsideOneStreamingLifecycle() {
        // WHY: Google documents that its TTS model occasionally emits text tokens instead of audio,
        // that the server then fails the request with HTTP 500, and that clients should retry those
        // automatically. A user waiting on the menu bar must get their speech, not an error they can
        // do nothing about; and because the retry continues the request they started, the menu must
        // never flicker through an idle or failed state it would then contradict.
        let manager = TestNetworkFactory.makeManager()
        configureGeminiProvider(manager)
        let attempts = RequestAttemptLog()
        let expectedAudio = Data([0, 1, 2, 3])
        MockURLProtocol.installRequestHandler { request in
            guard attempts.record(request) > 1 else {
                return (mockHTTPResponse(for: request, statusCode: 500), Data("{\"error\":{}}".utf8))
            }
            return (mockHTTPResponse(for: request, statusCode: 200), geminiAudioEvent(expectedAudio))
        }

        var streamingStates: [Bool] = []
        var publishedErrors: [String?] = []
        let streamingObservation = manager.$isStreaming.sink { streamingStates.append($0) }
        let errorObservation = manager.$lastError.sink { publishedErrors.append($0) }
        defer {
            streamingObservation.cancel()
            errorObservation.cancel()
        }

        let audioDelivered = expectation(description: "The retried attempt delivers its audio")
        let delivered = DeliveredAudioLog()
        let generationBeforeRequest = manager.currentRequestGeneration()
        assertTerminalState(of: manager, expectedError: nil) {
            manager.streamTTS(text: "Transient Gemini failure") { data in
                delivered.record(data)
                audioDelivered.fulfill()
            }
        }
        wait(for: [audioDelivered], timeout: 2.0)

        XCTAssertEqual(attempts.count, 2, "A transient Gemini 500 must be followed by exactly one more attempt.")
        XCTAssertEqual(
            delivered.recorded,
            [expectedAudio],
            "The recovered attempt must deliver its audio once and unchanged."
        )
        XCTAssertEqual(
            streamingStates,
            [false, true, false],
            "The retry continues one logical request, so the menu must not observe an idle state between attempts."
        )
        XCTAssertEqual(
            publishedErrors.compactMap { $0 },
            [],
            "No failure may be published before the retry's outcome is known."
        )
        XCTAssertEqual(
            manager.currentRequestGeneration(),
            generationBeforeRequest &+ 1,
            """
            Recovery must continue the request's own cancellation generation. Advancing it would tell \
            a menu action that captured it the pipeline changed hands, dropping a clipboard read the \
            user is still owed.
            """
        )
    }

    func testGeminiRetryIsBoundedToOneExtraAttemptAndPublishesItsFailureOnce() {
        // WHY: Google's guidance is automated retry, not indefinite retry. A model that keeps
        // failing must reach the user's established HTTP message once, instead of looping requests
        // that each spend the user's quota while the menu bar claims speech is still coming.
        let manager = TestNetworkFactory.makeManager()
        configureGeminiProvider(manager)
        let attempts = RequestAttemptLog()
        MockURLProtocol.installRequestHandler { request in
            attempts.record(request)
            return (mockHTTPResponse(for: request, statusCode: 500), nil)
        }

        var publishedErrors: [String?] = []
        let errorObservation = manager.$lastError.sink { publishedErrors.append($0) }
        defer { errorObservation.cancel() }

        assertTerminalState(of: manager, expectedError: "Speech request failed (HTTP 500).") {
            manager.streamTTS(text: "Persistent Gemini failure") { _ in
                XCTFail("A Gemini stream that never returns audio must not deliver data.")
            }
        }

        XCTAssertEqual(attempts.count, 2, "A persistent Gemini 500 must stop after the single permitted retry.")
        XCTAssertEqual(
            publishedErrors.compactMap { $0 },
            ["Speech request failed (HTTP 500)."],
            "Both attempts belong to one request, so its sanitized failure must be published exactly once."
        )
        assertAfterMockQuiescence {
            XCTAssertEqual(attempts.count, 2, "No further attempt may escape the request's terminal state.")
            XCTAssertEqual(manager.lastError, "Speech request failed (HTTP 500).")
            XCTAssertFalse(manager.isStreaming)
        }
    }

    func testGeminiRetryReplaysTheFirstAttemptRatherThanCurrentSettings() {
        // WHY: The retry belongs to the request the user started. Rebuilding it from live Settings
        // would let an edit made while the first attempt was in flight silently change the voice or
        // model the user is about to hear, or send their clipboard text and key somewhere else.
        let manager = TestNetworkFactory.makeManager()
        configureGeminiProvider(manager)
        let attempts = RequestAttemptLog()
        let expectedAudio = Data([4, 5])
        MockURLProtocol.installRequestHandler { request in
            guard attempts.record(request) > 1 else {
                manager.updateSettings(
                    baseURL: "https://generativelanguage.googleapis.com/v1beta",
                    apiKey: "replacement-gemini-key",
                    model: "gemini-replacement-model",
                    voice: "Kore",
                    selectedProvider: "Gemini"
                )
                return (mockHTTPResponse(for: request, statusCode: 500), nil)
            }
            return (mockHTTPResponse(for: request, statusCode: 200), geminiAudioEvent(expectedAudio))
        }

        let audioDelivered = expectation(description: "The retried attempt delivers its audio")
        assertTerminalState(of: manager, expectedError: nil) {
            manager.streamTTS(text: "Gemini retry after a settings change") { _ in audioDelivered.fulfill() }
        }
        wait(for: [audioDelivered], timeout: 2.0)

        let recorded = attempts.recorded
        guard recorded.count == 2 else {
            // Fail rather than index: a crashed host restarts the run and hides which assertion broke.
            XCTFail("The settings change must not prevent the retry, but \(recorded.count) attempt(s) were made.")
            return
        }
        let firstBody = requestBodyData(from: recorded[0]).flatMap { String(bytes: $0, encoding: .utf8) }
        let retryBody = requestBodyData(from: recorded[1]).flatMap { String(bytes: $0, encoding: .utf8) }
        XCTAssertEqual(recorded[1].url, recorded[0].url, "The retry must reuse the endpoint and model of its first attempt.")
        XCTAssertEqual(retryBody, firstBody, "The retry must resend the text and voice its first attempt captured.")
        XCTAssertEqual(
            recorded[1].allHTTPHeaderFields,
            recorded[0].allHTTPHeaderFields,
            "The retry must present the credentials its first attempt captured."
        )
        XCTAssertEqual(recorded[1].value(forHTTPHeaderField: "x-goog-api-key"), "fake-gemini-key")
        XCTAssertTrue(
            recorded[1].url?.absoluteString.contains("gemini-3.1-flash-tts-preview") ?? false,
            "The retry must not adopt the model saved after it started."
        )
        XCTAssertTrue(retryBody?.contains("\"voiceName\":\"Aoede\"") ?? false)
        XCTAssertFalse(retryBody?.contains("Kore") ?? true, "The retry must not adopt the voice saved after it started.")
    }
}
