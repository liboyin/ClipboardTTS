import XCTest
@testable import ClipboardTTSApp

/// The Realtime contract itself: where a session connects, what the client sends, and what each
/// server event means.
///
/// Both halves are pure, so this suite needs no connection or manager. How a classified event
/// changes request state belongs to `TTSNetworkManagerRealtimeTests`.
final class OpenAIRealtimeSpeechTests: XCTestCase {
    func testTheModelTravelsAsOneEncodedQueryItemOnTheFixedEndpoint() {
        // WHY: The Realtime API reads the model only from the query. A typed model containing a
        // query delimiter must stay one value rather than add parameters the user never chose.
        XCTAssertEqual(
            OpenAIRealtimeSpeech.url(model: "gpt-realtime-2.1-mini")?.absoluteString,
            "wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1-mini"
        )
        let url = OpenAIRealtimeSpeech.url(model: "odd model&voice=x")
        let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }
        XCTAssertEqual(items, [URLQueryItem(name: "model", value: "odd model&voice=x")])
        XCTAssertEqual(url?.host, "api.openai.com")
    }

    func testTheReadTextAndVoiceSurviveEncodingExactly() throws {
        // WHY: The text is the user's clipboard. Quotes, newlines, and non-Latin scripts must reach
        // the model exactly as copied, or it reads something else.
        let text = "She said \"hi\"\nthen left — 今天天气很好 😀 \\ end"
        let events = try OpenAIRealtimeSpeech.clientEvents(text: text, voice: "marin")
        let decoded = try events.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }

        let item = try XCTUnwrap(decoded[1]["item"] as? [String: Any])
        let content = try XCTUnwrap(item["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, text)
        let session = try XCTUnwrap(decoded[0]["session"] as? [String: Any])
        let input = try XCTUnwrap((session["audio"] as? [String: Any])?["input"] as? [String: Any])
        XCTAssertTrue(input["turn_detection"] is NSNull, "No audio is sent, so nothing may be detected as a turn.")
    }

    func testAudioAndTheResponsesEndAreClassifiedFromTheirDocumentedFields() {
        let pcm = Data([0x10, 0x20, 0x30])
        XCTAssertEqual(classify(["type": "response.output_audio.delta", "delta": pcm.base64EncodedString()]), .audio(pcm))
        XCTAssertEqual(classify(["type": "response.done", "response": ["status": "completed"]]), .finished)
        XCTAssertEqual(classify(["type": "response.done", "response": ["status": "incomplete"]]), .stoppedEarly)
        // WHY: A cancelled or failed response is not a truncation the user can still hear the rest
        // of; it is the provider failing the request.
        XCTAssertEqual(classify(["type": "response.done", "response": ["status": "cancelled"]]), .failed(.provider))
        XCTAssertEqual(classify(["type": "response.done", "response": ["status": "failed"]]), .failed(.provider))
    }

    func testEventsThatNeitherCarryAudioNorEndTheResponseAreIgnored() {
        // WHY: A response interleaves lifecycle and transcript events with its audio, and the API
        // adds event types over time. Failing on any of them would end speech that is still coming.
        for type in ["session.created", "session.updated", "response.created", "response.output_audio.done",
                     "response.output_audio_transcript.delta", "rate_limits.updated", "some.future.event"] {
            XCTAssertEqual(classify(["type": type]), .ignored, type)
        }
    }

    func testOnlyTheDocumentedErrorIdentifiersChooseTheFailure() {
        XCTAssertEqual(classify(["type": "error", "error": ["type": "invalid_request_error", "code": "invalid_api_key"]]),
                       .failed(.authentication))
        XCTAssertEqual(classify(["type": "error", "error": ["type": "invalid_request_error", "code": "invalid_model"]]),
                       .failed(.invalidRequest))
        // WHY: An error the app cannot place, including one with no detail at all, is still the
        // provider failing: it must never be mistaken for success or for the user's mistake.
        XCTAssertEqual(classify(["type": "error", "error": ["type": "server_error"]]), .failed(.provider))
        XCTAssertEqual(classify(["type": "error"]), .failed(.provider))
    }

    func testAnEventWithoutAReadableTypeIsMalformed() {
        XCTAssertEqual(OpenAIRealtimeSpeech.classify(Data("not json".utf8)), .failed(.malformed))
        XCTAssertEqual(OpenAIRealtimeSpeech.classify(Data("[1, 2]".utf8)), .failed(.malformed))
        XCTAssertEqual(classify(["delta": "AAAA"]), .failed(.malformed))
        XCTAssertEqual(classify(["type": "response.output_audio.delta"]), .failed(.malformed))
    }

    private func classify(_ event: [String: Any]) -> OpenAIRealtimeSpeech.ServerEvent {
        // swiftlint:disable:next force_try
        OpenAIRealtimeSpeech.classify(try! JSONSerialization.data(withJSONObject: event))
    }
}
