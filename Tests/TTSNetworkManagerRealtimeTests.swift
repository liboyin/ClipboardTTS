import XCTest
@testable import ClipboardTTSApp

/// An OpenAI speech request over the Realtime WebSocket: what it opens and sends, how its frames
/// reach the client, how each way it can end is reported, and that it answers to the same
/// revocation as an HTTP request.
final class TTSNetworkManagerRealtimeTests: MockURLProtocolTestCase {
    private let pcm1 = Data([0x01, 0x02, 0x03, 0x04])
    private let pcm2 = Data([0x05, 0x06])

    // MARK: - What the request opens and sends

    func testARealtimeRequestOpensTheConfiguredModelWithOnlyABearerCredential() throws {
        // WHY: The Realtime API reads the model only from the connection URL, so a model left out of
        // the query, or encoded differently, opens a session for the wrong model or none. The saved
        // key must travel in the one header this provider documents and nowhere else.
        let connections = ScriptedRealtimeConnections()
        let manager = makeRealtimeManager(connections, model: "gpt-realtime-2.1")

        manager.streamTTS(text: "Hello") { _ in }

        let connection = try XCTUnwrap(connections.all.first)
        addConnectionTeardown(connection)
        XCTAssertEqual(connection.request.url?.absoluteString, "wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1")
        XCTAssertEqual(connection.request.value(forHTTPHeaderField: "Authorization"), "Bearer realtime-key")
        XCTAssertNil(connection.request.value(forHTTPHeaderField: "x-goog-api-key"))
        XCTAssertTrue(connection.isResumed)
        XCTAssertTrue(manager.isStreaming)
    }

    func testARealtimeRequestConfiguresTheSessionThenSendsTheTextThenAsksForOneResponse() throws {
        // WHY: The server applies events in the order they arrive. Session settings sent after the
        // response request would leave the response in the default voice and format, and a missing
        // instruction would let the model answer the text instead of reading it.
        let connections = ScriptedRealtimeConnections()
        let manager = makeRealtimeManager(connections, voice: "cedar")

        manager.streamTTS(text: "What is the capital of France?") { _ in }

        let connection = try XCTUnwrap(connections.all.first)
        addConnectionTeardown(connection)
        let events = connection.sentEvents
        XCTAssertEqual(events.map { $0["type"] as? String }, ["session.update", "conversation.item.create", "response.create"])

        let session = try XCTUnwrap(events.first?["session"] as? [String: Any])
        XCTAssertEqual(session["type"] as? String, "realtime")
        XCTAssertEqual(session["output_modalities"] as? [String], ["audio"])
        XCTAssertEqual(session["instructions"] as? String, OpenAIRealtimeSpeech.instructions)
        let output = try XCTUnwrap((session["audio"] as? [String: Any])?["output"] as? [String: Any])
        XCTAssertEqual(output["voice"] as? String, "cedar")
        let format = try XCTUnwrap(output["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "audio/pcm")
        XCTAssertEqual(format["rate"] as? Int, 24_000, "The player decodes OpenAI audio at 24 kHz.")

        let item = try XCTUnwrap(events[1]["item"] as? [String: Any])
        XCTAssertEqual(item["role"] as? String, "user")
        let content = try XCTUnwrap(item["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "input_text")
        XCTAssertEqual(content.first?["text"] as? String, "What is the capital of France?")
    }

    // MARK: - Delivery and completion

    func testRealtimeAudioReachesTheClientInOrderAndTheSessionEndsBehindIt() throws {
        // WHY: The terminal event exists so a client can tell speech that finished from audio still
        // on its way. Events the response sends between its audio, such as transcript deltas, must
        // neither be played nor end it.
        let connections = ScriptedRealtimeConnections()
        let manager = makeRealtimeManager(connections)
        let events = SessionEventLog()
        let terminated = expectation(description: "The session is terminated")

        assertTerminalState(of: manager, expectedError: nil) {
            manager.streamTTS(text: "Hello", client: makeLoggingClient(events, terminated: terminated))
            guard let connection = connections.all.first else { return XCTFail("No connection was opened.") }
            addConnectionTeardown(connection)
            connection.deliverEvent(["type": "session.created", "session": [:]])
            connection.deliverAudio(pcm1)
            connection.deliverEvent(["type": "response.output_audio_transcript.delta", "delta": "Hel"])
            connection.deliverAudio(pcm2)
            connection.deliverResponseDone()
        }
        wait(for: [terminated], timeout: 2.0)

        XCTAssertEqual(events.recorded, [.audio(pcm1), .audio(pcm2), .terminated(.finished)])
        XCTAssertTrue(try XCTUnwrap(connections.all.first).isCancelled, "A finished request must close its connection.")
    }

    func testAResponseThatCompletesWithoutAudioIsAFailure() {
        // WHY: A completed response with nothing to play would otherwise end silently as a success.
        assertRealtimeFailure(
            expectedError: TTSNetworkManager.noPlayableAudioFailure,
            frames: { $0.deliverResponseDone() }
        )
    }

    func testAnIncompleteResponseKeepsItsAudioAndSaysItStoppedEarly() {
        // WHY: The PCM that arrived stays playable, so the message must describe a truncation the
        // user can hear rather than claim that no audio arrived.
        let events = assertRealtimeFailure(
            expectedError: TTSNetworkManager.truncatedResponseFailure,
            frames: { connection in
                connection.deliverAudio(self.pcm1)
                connection.deliverResponseDone(status: "incomplete")
            }
        )
        XCTAssertEqual(events, [.audio(pcm1), .terminated(.failed)])
    }

    func testARejectedKeyIsReportedWithoutRepeatingTheProvidersMessage() {
        // WHY: OpenAI reports a bad key as an `error` event after a successful upgrade, and its
        // message quotes part of the key back. The app's own text must name the remedy and nothing
        // the provider wrote.
        assertRealtimeFailure(
            expectedError: "Authentication failed. Check your API key and try again.",
            frames: { connection in
                connection.deliverEvent(["type": "error", "error": [
                    "type": "invalid_request_error", "code": "invalid_api_key",
                    "message": "Incorrect API key provided: sk-secret-fragment."
                ]])
            }
        )
    }

    func testARejectedRequestPointsAtTheModelAndVoice() {
        // WHY: An unsupported model or voice is the request error a user can fix, and only in Settings.
        assertRealtimeFailure(
            expectedError: "The TTS service rejected the request. Check the model and voice in Settings and try again.",
            frames: { connection in
                connection.deliverEvent(["type": "error", "error": [
                    "type": "invalid_request_error", "code": "invalid_value", "message": "Invalid value: 'nova'."
                ]])
            }
        )
    }

    func testAProviderFailureAndAFailedResponseAreReportedAsTheProvidersError() {
        // WHY: Neither is the user's to fix, so both must say the service failed, not that the
        // request or connection was wrong.
        let message = "The TTS service reported an error. Please try again."
        assertRealtimeFailure(expectedError: message) { connection in
            connection.deliverEvent(["type": "error", "error": ["type": "server_error", "message": "Internal"]])
        }
        assertRealtimeFailure(expectedError: message) { $0.deliverResponseDone(status: "failed") }
    }

    func testAFrameThatIsNotTheDocumentedContractFailsTheRequest() {
        // WHY: Every case here is a stream the app cannot trust: playing around a frame it could not
        // read would hide that speech is missing.
        let failure = TTSNetworkManager.noPlayableAudioFailure
        // Text that is not JSON.
        assertRealtimeFailure(expectedError: failure) { $0.deliver(.success(.string("not json"))) }
        // A binary frame.
        assertRealtimeFailure(expectedError: failure) { $0.deliver(.success(.data(Data([0x00, 0x01])))) }
        // Audio that is not base64.
        assertRealtimeFailure(expectedError: failure) {
            $0.deliverEvent(["type": "response.output_audio.delta", "delta": "%%%"])
        }
        // A response with no status.
        assertRealtimeFailure(expectedError: failure) { $0.deliverEvent(["type": "response.done", "response": [:]]) }
    }

    func testAConnectionThatEndsBeforeTheResponseIsATransportFailureAfterItsAudio() {
        // WHY: A connection lost mid-response leaves the speech incomplete, so it must not end as a
        // success, and the audio that did arrive must still reach the player ahead of the failure.
        let events = assertRealtimeFailure(
            expectedError: TTSNetworkManager.unreachableServiceFailure,
            frames: { connection in
                connection.deliverAudio(self.pcm1)
                connection.deliver(.failure(URLError(.networkConnectionLost)))
            }
        )
        XCTAssertEqual(events, [.audio(pcm1), .terminated(.failed)])
    }

    // MARK: - Revocation

    func testStoppingARealtimeRequestClosesItsConnectionAndDeliversNothingLater() throws {
        // WHY: A stop must end what the user can hear. Frames the provider had already sent must not
        // reach the stopped session, and a stopped session is owed no terminal event.
        let connections = ScriptedRealtimeConnections()
        let manager = makeRealtimeManager(connections)
        let events = SessionEventLog()
        let terminated = expectation(description: "No terminal event reaches a stopped session")
        terminated.isInverted = true

        manager.streamTTS(text: "Hello", client: makeLoggingClient(events, terminated: terminated))
        let connection = try XCTUnwrap(connections.all.first)
        addConnectionTeardown(connection)
        manager.stopStreaming()
        connection.deliverAudio(pcm1)
        connection.deliverResponseDone()
        connection.drain()
        wait(for: [terminated], timeout: 0.3)

        XCTAssertTrue(connection.isCancelled)
        XCTAssertEqual(events.recorded, [])
        XCTAssertFalse(manager.isStreaming)
    }

    func testAReplacedRealtimeRequestCannotDeliverIntoItsReplacement() throws {
        // WHY: The replacement owns the pipeline from the moment it starts. A frame the replaced
        // connection still delivers — one already in flight when it was cancelled — must neither
        // play into the new session nor end it. The replaced connection keeps its receive waiting
        // across the cancellation, so those frames reach the manager while the replacement owns it.
        let connections = ScriptedRealtimeConnections(failsPendingReceiveOnCancel: false)
        let manager = makeRealtimeManager(connections)
        let staleEvents = SessionEventLog()
        let currentEvents = SessionEventLog()
        let staleTerminated = expectation(description: "The replaced session is not terminated")
        staleTerminated.isInverted = true
        let currentTerminated = expectation(description: "The replacement session is terminated")

        manager.streamTTS(text: "First", client: makeLoggingClient(staleEvents, terminated: staleTerminated))
        manager.streamTTS(text: "Second", client: makeLoggingClient(currentEvents, terminated: currentTerminated))
        XCTAssertEqual(connections.all.count, 2)
        let (replaced, replacement) = (connections.all[0], connections.all[1])
        addConnectionTeardown(replaced)
        addConnectionTeardown(replacement)
        XCTAssertTrue(replaced.isCancelled, "Starting a replacement must close the connection it replaces.")

        replaced.deliverAudio(pcm1)
        replaced.deliverResponseDone()
        replacement.deliverAudio(pcm2)
        replacement.deliverResponseDone()
        wait(for: [currentTerminated], timeout: 2.0)
        replaced.drain()
        wait(for: [staleTerminated], timeout: 0.3)

        XCTAssertEqual(staleEvents.recorded, [])
        XCTAssertEqual(currentEvents.recorded, [.audio(pcm2), .terminated(.finished)])
    }

    // MARK: - Routing

    func testAnUnscriptedRealtimeHandshakeIsClaimedByTheTestsMockRouting() {
        // WHY: The production connection factory opens its WebSocket task on the manager's own
        // session. That is what keeps the caller's routing in charge of where a Realtime request
        // can go: a test that forgot to script one must see the handshake in its mock, carrying the
        // credential and its scope, and must never reach the network.
        let manager = TestNetworkFactory.makeManager()
        let expectedIdentifier = MockURLProtocol.currentTestIdentifier()
        let handshakeObserved = expectation(description: "The WebSocket handshake reaches MockURLProtocol")
        handshakeObserved.assertForOverFulfill = false
        MockURLProtocol.installRequestHandler { request in
            XCTAssertEqual(request.url?.host, "api.openai.com")
            XCTAssertEqual(request.url?.path, "/v1/realtime")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer realtime-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: MockURLProtocol.testIdentifierHeader), expectedIdentifier)
            handshakeObserved.fulfill()
            return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        manager.updateSettings(baseURL: OpenAIRealtimeSpeech.endpoint, apiKey: "realtime-key",
                               model: "gpt-realtime-2.1-mini", voice: "alloy", selectedProvider: "OpenAI")

        assertTerminalState(of: manager, expectedError: TTSNetworkManager.unreachableServiceFailure) {
            manager.streamTTS(text: "Hello") { _ in }
        }
        wait(for: [handshakeObserved], timeout: 2.0)
    }

    // MARK: - Helpers

    private func makeRealtimeManager(_ connections: ScriptedRealtimeConnections,
                                     model: String = "gpt-realtime-2.1-mini",
                                     voice: String = "alloy") -> TTSNetworkManager {
        let manager = TestNetworkFactory.makeManager(realtimeConnections: connections)
        manager.updateSettings(baseURL: OpenAIRealtimeSpeech.endpoint, apiKey: "realtime-key",
                               model: model, voice: voice, selectedProvider: "OpenAI")
        return manager
    }

    /// Starts a request, plays `frames` into its connection, and asserts the failure it publishes
    /// and that its session ends failed. Returns what the client received.
    @discardableResult
    private func assertRealtimeFailure(expectedError: String,
                                       file: StaticString = #filePath,
                                       line: UInt = #line,
                                       frames: @escaping (ScriptedRealtimeConnection) -> Void) -> [SessionEventLog.Event] {
        let connections = ScriptedRealtimeConnections()
        let manager = makeRealtimeManager(connections)
        let events = SessionEventLog()
        let terminated = expectation(description: "The failed request terminates its session")

        assertTerminalState(of: manager, expectedError: expectedError) {
            manager.streamTTS(text: "Hello", client: makeLoggingClient(events, terminated: terminated))
            guard let connection = connections.all.first else { return XCTFail("No connection was opened.", file: file, line: line) }
            addConnectionTeardown(connection)
            frames(connection)
        }
        wait(for: [terminated], timeout: 2.0)

        XCTAssertEqual(events.recorded.last, .terminated(.failed), file: file, line: line)
        XCTAssertTrue(connections.all.first?.isCancelled ?? false, "A failed request must close its connection.",
                      file: file, line: line)
        return events.recorded
    }

    private func makeLoggingClient(_ events: SessionEventLog, terminated: XCTestExpectation) -> SpeechStreamClient {
        SpeechStreamClient(
            didReceiveAudio: { events.record(.audio($0)) },
            didTerminate: { termination in
                events.record(.terminated(termination))
                terminated.fulfill()
            }
        )
    }

    /// Closes the connection and waits out every handler it started, however the test ends.
    private func addConnectionTeardown(_ connection: ScriptedRealtimeConnection) {
        addTeardownBlock {
            connection.cancel()
            connection.drain()
        }
    }
}
