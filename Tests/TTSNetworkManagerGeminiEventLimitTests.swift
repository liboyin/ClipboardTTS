import XCTest
@testable import ClipboardTTSApp

final class TTSNetworkManagerGeminiEventLimitTests: MockURLProtocolTestCase {
    func testGeminiEventGrowingPastTheCapFailsTheStreamAtTheFirstByteOver() {
        // WHY: A provider that never ends an event must not grow request-owned memory without
        // bound. Refusing one byte early would also refuse the largest event the cap admits.
        assertCapRevokesGeminiRequest(overCapPacket: Data("A".utf8))
    }

    func testWellFormedGeminiEventEndingPastTheCapInOneCallbackFailsWithoutDelivery() {
        // WHY: The callback that takes an event past the cap may also end it. Checking only the
        // bytes left over after that callback would decode and play the over-cap event instead.
        assertCapRevokesGeminiRequest(overCapPacket: Data("\"}}]}}]}\n\n".utf8))
    }

    /// Streams the unfinished start of a well-formed Gemini audio event holding exactly the cap,
    /// then sends `overCapPacket`. Closing that event after the cap yields decodable audio, so a
    /// missed cap delivers it rather than failing as malformed with the same message.
    private func assertCapRevokesGeminiRequest(overCapPacket: Data,
                                               file: StaticString = #filePath,
                                               line: UInt = #line) {
        let manager = TestNetworkFactory.makeManager()
        manager.updateSettings(
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            apiKey: "fake-gemini-key",
            model: "gemini-3.1-flash-tts-preview",
            voice: "Aoede",
            selectedProvider: "Gemini"
        )
        let requestStarted = expectation(description: "Gemini request starts")
        let releaseResponse = DispatchSemaphore(value: 0)
        MockURLProtocol.installRequestHandler { request in
            requestStarted.fulfill()
            // Hold the response open for the whole test. Were it to complete, end of stream would
            // fail the unfinished event with the same message and hide whether the cap did.
            _ = releaseResponse.wait(timeout: .now() + 30.0)
            return (eventStreamResponse(for: request), nil)
        }
        manager.streamTTS(text: "Gemini event limit test") { _ in
            XCTFail("An event over the cap must not deliver audio.")
        }
        defer { releaseResponse.signal() }
        wait(for: [requestStarted], timeout: 1.0)
        guard let task = manager.activeTaskForTesting else {
            return XCTFail("Expected streamTTS to retain its Gemini task.")
        }
        manager.urlSession(manager.session, dataTask: task, didReceive: eventStreamResponse(for: task.currentRequest!)) {
            XCTAssertEqual($0, .allow)
        }

        // D13's value, stated here rather than read from the parser, so raising the production
        // cap fails this boundary as lowering it does.
        let cap = 64 * 1024 * 1024
        let field = Data("data: ".utf8)
        let json = Data("{\"candidates\":[{\"content\":{\"parts\":[{\"inlineData\":{\"data\":\"".utf8)
        let base64Count = (cap - field.count - json.count) / 4 * 4
        let padding = Data(repeating: UInt8(ascii: " "), count: cap - field.count - json.count - base64Count)
        manager.urlSession(manager.session, dataTask: task, didReceive: field + padding + json)
        let chunk = Data(repeating: UInt8(ascii: "A"), count: 1 << 20)
        var remaining = base64Count
        while remaining > 0 {
            let count = min(remaining, chunk.count)
            manager.urlSession(manager.session, dataTask: task, didReceive: chunk.prefix(count))
            remaining -= count
        }
        XCTAssertNotNil(manager.activeTaskForTesting, "An event holding exactly the cap must keep streaming.", file: file, line: line)

        assertTerminalState(of: manager, expectedError: "The TTS service returned no playable audio. Please try again.") {
            manager.urlSession(manager.session, dataTask: task, didReceive: overCapPacket)
            XCTAssertNil(
                manager.activeTaskForTesting,
                "The packet over the cap must revoke the request as it arrives.",
                file: file,
                line: line
            )
        }
        assertAfterMockQuiescence {
            XCTAssertNil(manager.activeTaskForTesting)
            XCTAssertFalse(manager.isStreaming)
        }
    }
}

/// File scope so the `@Sendable` mock handler builds a response without capturing the test case.
private func eventStreamResponse(for request: URLRequest) -> HTTPURLResponse {
    HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "text/event-stream"]
    )!
}
