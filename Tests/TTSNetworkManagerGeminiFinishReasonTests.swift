import XCTest
@testable import ClipboardTTSApp

/// Covers how the `finishReason` a Gemini candidate declares decides whether a completed stream
/// counts as a successful read, and what it publishes when the provider stopped before finishing.
final class TTSNetworkManagerGeminiFinishReasonTests: MockURLProtocolTestCase {
    private static let earlyStopFailure =
        "The TTS service stopped early. The speech that arrived is incomplete. Please try again."
    private static let noPlayableAudioFailure =
        "The TTS service returned no playable audio. Please try again."

    func testNonSTOPFinishReasonFailsWhileKeepingTheAudioItAlreadyDelivered() {
        // WHY: Google's streaming TTS endpoint has an open defect that truncates audio past roughly
        // 60-70 seconds with finishReason OTHER under HTTP 200. Reporting that as a success leaves
        // the user hearing speech stop mid-sentence with no indication anything was lost, while the
        // PCM the player already accepted must survive the failure because the user can hear it.
        // One candidate carrying both the audio and the reason is the shape the defect actually
        // sends, and the only one in which routing an early stop through the stream-failure
        // revocation would drop the PCM in the very same event.
        let audio = Data([0, 1])
        let delivered = assertGeminiCompletion(
            events: [geminiAudioEvent(audio, finishReason: "OTHER")],
            expectedError: Self.earlyStopFailure
        )
        XCTAssertEqual(delivered, [audio], "An early stop must not withdraw audio already handed to the player.")
    }

    func testSTOPFinishReasonCompletesWithoutFailure() {
        // WHY: STOP is how a healthy Gemini stream announces that it finished. Failing it would turn
        // every complete read into an error the moment the app started reading finish reasons.
        assertGeminiCompletion(
            events: [geminiAudioEvent(Data([0, 1])), geminiFinishReasonEvent("STOP")],
            expectedError: nil
        )
    }

    func testStreamDeclaringNoFinishReasonStillCompletesSuccessfully() {
        // WHY: A stream may end without any final metadata, so a missing reason is not evidence that
        // it stopped early. Failing it would reject ordinary successful reads, which is the
        // over-restriction this check exists to avoid.
        assertGeminiCompletion(events: [geminiAudioEvent(Data([0, 1]))], expectedError: nil)
    }

    func testTrailingMetadataEventDoesNotEraseADeclaredEarlyStop() {
        // WHY: Gemini sends candidate-free metadata after its final candidate. Clearing the recorded
        // reason on every event would let that trailing event bury the truncation the user suffered.
        assertGeminiCompletion(
            events: [
                geminiAudioEvent(Data([0, 1])),
                geminiFinishReasonEvent("OTHER"),
                Data("data: {\"usageMetadata\":{}}\r\n\r\n".utf8)
            ],
            expectedError: Self.earlyStopFailure
        )
    }

    func testAudioEventOmittingAFinishReasonDoesNotEraseADeclaredEarlyStop() {
        // WHY: A candidate that carries audio but omits finishReason declares nothing about how the
        // stream ends. Letting it overwrite an earlier OTHER would hide truncation behind more audio.
        let delivered = assertGeminiCompletion(
            events: [
                geminiAudioEvent(Data([0, 1])),
                geminiFinishReasonEvent("OTHER"),
                geminiAudioEvent(Data([2, 3]))
            ],
            expectedAudioDeliveries: 2,
            expectedError: Self.earlyStopFailure
        )
        XCTAssertEqual(delivered, [Data([0, 1]), Data([2, 3])])
    }

    func testLaterDeclaredFinishReasonReplacesAnEarlierOne() {
        // WHY: Only the most recent declared reason describes how the stream actually ended. Keeping
        // the first one would fail a stream that recovered and went on to report STOP.
        assertGeminiCompletion(
            events: [
                geminiAudioEvent(Data([0, 1])),
                geminiFinishReasonEvent("OTHER"),
                geminiFinishReasonEvent("STOP")
            ],
            expectedError: nil
        )
    }

    func testNonStringFinishReasonCountsAsUndeclared() {
        // WHY: A finishReason of another JSON type is a provider schema surprise, not evidence of
        // truncation. Treating it as a corrupt stream would revoke audible speech whenever Google
        // changed the field's shape, so it leaves the remaining completion checks in charge.
        assertGeminiCompletion(
            events: [
                geminiAudioEvent(Data([0, 1])),
                Data("data: {\"candidates\":[{\"finishReason\":{}}]}\r\n\r\n".utf8)
            ],
            expectedError: nil
        )
    }

    func testEarlyStopWithoutAudioReportsTheEarlyStopRatherThanNoAudio() {
        // WHY: The finish-reason check sits before the PCM-frame check, so a truncation that cut the
        // stream before any audio arrived still explains itself instead of claiming none was sent.
        assertGeminiCompletion(
            events: [geminiFinishReasonEvent("OTHER")],
            expectedAudioDeliveries: 0,
            expectedError: Self.earlyStopFailure
        )
    }

    func testIncompleteTrailingEventOutranksADeclaredEarlyStop() {
        // WHY: An unterminated event means the app cannot trust what it parsed at all, which is a
        // stronger statement than the provider's own finish reason and must keep its precedence.
        assertGeminiCompletion(
            events: [
                geminiAudioEvent(Data([0, 1])),
                geminiFinishReasonEvent("OTHER"),
                Data("data: {\"candidates\":".utf8)
            ],
            expectedError: Self.noPlayableAudioFailure
        )
    }

    /// Drives one Gemini stream through `events` and asserts what its completion publishes.
    ///
    /// Returns the PCM the handler accepted, so a caller can prove that audio the user can already
    /// hear survives the outcome. A stream expected to deliver nothing fails on any delivery rather
    /// than waiting out a timeout, which would make elapsed time the synchronization boundary.
    @discardableResult
    private func assertGeminiCompletion(events: [Data],
                                        expectedAudioDeliveries: Int = 1,
                                        expectedError: String?) -> [Data] {
        let manager = TestNetworkFactory.makeManager()
        configureGeminiProvider(manager)
        let requestStarted = expectation(description: "Gemini request starts")
        let releaseResponse = DispatchSemaphore(value: 0)
        MockURLProtocol.installRequestHandler { request in
            requestStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 1.0)
            return (mockHTTPResponse(for: request, statusCode: 200), nil)
        }

        let delivered = DeliveredAudioLog()
        // Bound before the handler captures it, so the escaping closure references no mutable var.
        let audioDelivered: XCTestExpectation? = expectedAudioDeliveries > 0
            ? expectation(description: "Every expected audio event delivers")
            : nil
        audioDelivered?.expectedFulfillmentCount = expectedAudioDeliveries
        audioDelivered?.assertForOverFulfill = true
        manager.streamTTS(text: "Gemini finish-reason test") { chunk in
            delivered.record(chunk)
            guard let audioDelivered else {
                XCTFail("This Gemini stream must not deliver audio.")
                return
            }
            audioDelivered.fulfill()
        }
        wait(for: [requestStarted], timeout: 1.0)
        defer { releaseResponse.signal() }
        guard let task = manager.activeTaskForTesting else {
            XCTFail("Expected streamTTS to retain its Gemini task.")
            return []
        }

        manager.urlSession(
            manager.session,
            dataTask: task,
            didReceive: mockHTTPResponse(for: task, statusCode: 200)
        ) { disposition in
            XCTAssertEqual(disposition, .allow)
        }
        for event in events {
            manager.urlSession(manager.session, dataTask: task, didReceive: event)
        }
        // Settle delivery before completion, so the returned PCM records what the player accepted
        // while the stream was open rather than whatever landed during the terminal assertion.
        if let audioDelivered {
            wait(for: [audioDelivered], timeout: 1.0)
        }

        assertTerminalState(of: manager, expectedError: expectedError) {
            manager.urlSession(manager.session, task: task, didCompleteWithError: nil)
        }
        return delivered.recorded
    }
}
