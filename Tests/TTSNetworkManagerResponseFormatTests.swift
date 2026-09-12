import XCTest
@testable import ClipboardTTSApp

/// What a speech response has to declare before any of its bytes are played as 16-bit PCM.
///
/// The two provider paths declare that in different places — an OpenAI-compatible body says what it
/// is in its `Content-Type`, a Gemini stream says it inside each event's inline payload — so both
/// live here, with the refusal each one publishes.
final class TTSNetworkManagerResponseFormatTests: MockURLProtocolTestCase {
    private static let refusalMessage = TTSNetworkManager.unplayableResponseFormatFailure
    private static let noPlayableAudioMessage = "The TTS service returned no playable audio. Please try again."

    func testASuccessDeclaringJSONDeliversNoAudioAndNamesTheEndpoint() {
        // WHY: This is the defect. A proxy or a misaddressed endpoint can answer HTTP 200 with a
        // JSON error, and those bytes read as 16-bit samples are full-scale noise rather than a
        // message. The request must publish its own explanation and hand the player nothing.
        let manager = makeOpenAICompatibleManager()
        let deliveredAudio = LockedValue<[Data]>([])

        withStartedRequest(on: manager, audio: { data in deliveredAudio.withValue { $0.append(data) } }) { task in
            receive(manager, response: response(for: task, contentType: "application/json"), for: task)
            manager.urlSession(manager.session, dataTask: task, didReceive: Data("{\"error\":\"nope\"}".utf8))
            assertTerminalState(of: manager, expectedError: Self.refusalMessage) {
                manager.urlSession(manager.session, task: task, didCompleteWithError: nil)
            }
        }

        drainAudioDelivery(of: manager)
        XCTAssertEqual(deliveredAudio.value, [], "A body declared as JSON must not reach the player.")
        XCTAssertFalse(manager.isStreaming)
    }

    func testASuccessDeclaringAudioStillDeliversItsPCM() {
        // WHY: The refusal is only worth having if it leaves an ordinary provider response alone.
        // A declared audio type is the case this rule must never touch.
        let manager = makeOpenAICompatibleManager()
        let expectedPCM = Data([0x01, 0x02, 0x03, 0x04])

        assertDelivers(expectedPCM, on: manager, contentType: "audio/pcm") { manager, task in
            manager.urlSession(manager.session, dataTask: task, didReceive: expectedPCM)
        }
    }

    func testASuccessDeclaringNoContentTypeStillDeliversItsPCM() {
        // WHY: OpenAI documents no content type for its speech endpoint, so this is the shape a
        // conforming response is allowed to have. A rule that required a declaration would silence
        // the provider the app ships pointed at.
        let manager = makeOpenAICompatibleManager()
        let expectedPCM = Data([0x10, 0x20])

        assertDelivers(expectedPCM, on: manager, contentType: nil) { manager, task in
            manager.urlSession(manager.session, dataTask: task, didReceive: expectedPCM)
        }
    }

    func testACustomEndpointRefusesADeclaredNonAudioBodyAsWell() {
        // WHY: Custom is the provider most likely to be pointed at the wrong URL, because the user
        // types it. It sends the same raw-sample request as OpenAI, so it must get the same answer.
        let manager = makeCustomManager()
        let deliveredAudio = LockedValue<[Data]>([])

        withStartedRequest(on: manager, audio: { data in deliveredAudio.withValue { $0.append(data) } }) { task in
            receive(manager, response: response(for: task, contentType: "text/html; charset=utf-8"), for: task)
            manager.urlSession(manager.session, dataTask: task, didReceive: Data("<html></html>".utf8))
            assertTerminalState(of: manager, expectedError: Self.refusalMessage) {
                manager.urlSession(manager.session, task: task, didCompleteWithError: nil)
            }
        }

        drainAudioDelivery(of: manager)
        XCTAssertEqual(deliveredAudio.value, [])
    }

    func testAnHTTPErrorStatusExplainsItselfRatherThanTheBodyItWasSentWith() {
        // WHY: Provider errors normally arrive as JSON with a failing status. The status is the
        // more actionable cause, so reading the declaration of a body that was never going to be
        // played must not displace it.
        let manager = makeOpenAICompatibleManager()

        withStartedRequest(on: manager, audio: { _ in XCTFail("An error response must not deliver audio.") }) { task in
            receive(manager, response: response(for: task, statusCode: 401, contentType: "application/json"), for: task)
            manager.urlSession(manager.session, dataTask: task, didReceive: Data("{\"error\":\"bad key\"}".utf8))
            assertTerminalState(
                of: manager,
                expectedError: "Authentication failed (HTTP 401). Check your API key and try again."
            ) {
                manager.urlSession(manager.session, task: task, didCompleteWithError: nil)
            }
        }
    }

    func testARefusedFormatExplainsItselfRatherThanATransportErrorBehindIt() {
        // WHY: A body the app has already decided to discard can still stop arriving. Reporting the
        // connection would send the user to their network when the endpoint is what is wrong.
        let manager = makeOpenAICompatibleManager()

        withStartedRequest(on: manager, audio: { _ in XCTFail("A refused body must not deliver audio.") }) { task in
            receive(manager, response: response(for: task, contentType: "application/json"), for: task)
            assertTerminalState(of: manager, expectedError: Self.refusalMessage) {
                manager.urlSession(
                    manager.session,
                    task: task,
                    didCompleteWithError: URLError(.networkConnectionLost)
                )
            }
        }
    }

    func testTheRefusalQuotesNothingTheProviderSent() {
        // WHY: A declared content type is provider-controlled text on the same footing as an error
        // body, and this app's failure copy never repeats either.
        let manager = makeOpenAICompatibleManager()
        let providerDeclaration = "application/vnd.provider.secret+json"

        withStartedRequest(on: manager, audio: { _ in XCTFail("A refused body must not deliver audio.") }) { task in
            receive(manager, response: response(for: task, contentType: providerDeclaration), for: task)
            assertTerminalState(of: manager, expectedError: Self.refusalMessage) {
                manager.urlSession(manager.session, task: task, didCompleteWithError: nil)
            }
        }

        XCTAssertFalse(manager.lastError?.contains(providerDeclaration) ?? true)
        XCTAssertFalse(manager.lastError?.contains("vnd.provider") ?? true)
    }

    func testAGeminiPartDeclaringTheLinearPCMItCarriesIsDelivered() {
        // WHY: This is the declaration Gemini's speech output actually sends, parameters included,
        // over the event-stream content type its endpoint sends with it. A rule that compared the
        // raw value, folded no case, or reached the response at all would silence this provider.
        let manager = makeGeminiManager()
        let expectedPCM = Data([0, 1, 2, 3])

        assertDelivers(expectedPCM, on: manager, contentType: "text/event-stream") { manager, task in
            manager.urlSession(
                manager.session,
                dataTask: task,
                didReceive: geminiEvent(audio: expectedPCM, declaration: "\"audio/L16;codec=pcm;rate=24000\"")
            )
        }
    }

    func testAGeminiPartDeclaringMediaItCannotPlayEndsTheStream() {
        // WHY: Gemini's inline blob is the same one that carries documents and images elsewhere in
        // the API, and the decoder reads whatever it finds there as raw 16-bit samples. A part
        // declaring a PDF is not quiet corruption but full-scale noise, so the event is fatal.
        let manager = makeGeminiManager()

        withStartedRequest(on: manager, audio: { _ in XCTFail("A refused part must not deliver audio.") }) { task in
            receive(manager, response: response(for: task, contentType: "text/event-stream"), for: task)
            assertTerminalState(of: manager, expectedError: Self.noPlayableAudioMessage) {
                manager.urlSession(
                    manager.session,
                    dataTask: task,
                    didReceive: geminiEvent(audio: Data([0, 1, 2, 3]), declaration: "\"application/pdf\"")
                )
            }
        }
    }

    func testAGeminiPartWhoseDeclarationIsNotAStringIsDelivered() {
        // WHY: A declaration this app cannot read declares nothing, which is how a `finishReason`
        // of the wrong type is already treated: a provider schema change must leave the remaining
        // completion checks in charge rather than revoke speech the user can hear.
        let manager = makeGeminiManager()
        let expectedPCM = Data([4, 5])

        assertDelivers(expectedPCM, on: manager, contentType: "text/event-stream") { manager, task in
            manager.urlSession(
                manager.session,
                dataTask: task,
                didReceive: geminiEvent(audio: expectedPCM, declaration: "42")
            )
        }
    }

    func testAGeminiPartDeclaringNothingIsStillDelivered() {
        // WHY: The request asks for the AUDIO response modality alone, so a part arriving under it
        // is audio by the terms of the request. Refusing an undeclared one would trade a defect
        // nothing has produced for the loss of every utterance if the field were ever omitted.
        let manager = makeGeminiManager()
        let expectedPCM = Data([6, 7])

        assertDelivers(expectedPCM, on: manager, contentType: "text/event-stream") { manager, task in
            manager.urlSession(
                manager.session,
                dataTask: task,
                didReceive: geminiEvent(audio: expectedPCM, declaration: nil)
            )
        }
    }

    /// Drives one response through a started request and asserts it delivered exactly that PCM.
    private func assertDelivers(_ expectedPCM: Data,
                                on manager: TTSNetworkManager,
                                contentType: String?,
                                body: (TTSNetworkManager, URLSessionDataTask) -> Void) {
        let deliveredAudio = LockedValue<[Data]>([])
        let audioDelivered = expectation(description: "The accepted response delivers its audio")

        withStartedRequest(on: manager, audio: { data in
            deliveredAudio.withValue { $0.append(data) }
            audioDelivered.fulfill()
        }) { task in
            receive(manager, response: response(for: task, contentType: contentType), for: task)
            body(manager, task)
            wait(for: [audioDelivered], timeout: 2.0)
            assertTerminalState(of: manager, expectedError: nil) {
                manager.urlSession(manager.session, task: task, didCompleteWithError: nil)
            }
        }

        drainAudioDelivery(of: manager)
        XCTAssertEqual(deliveredAudio.value, [expectedPCM])
    }

    /// Builds one complete Gemini event whose inline payload carries `declaration` verbatim as its
    /// `mimeType` JSON value, so a test can state one that is not a string, or none at all.
    private func geminiEvent(audio: Data, declaration: String?) -> Data {
        let prefix = "data: {\"candidates\":[{\"content\":{\"parts\":[{\"inlineData\":{\"data\":\""
        let declared = declaration.map { ",\"mimeType\":\($0)" } ?? ""
        return Data("\(prefix)\(audio.base64EncodedString())\"\(declared)}}]}}]}\r\n\r\n".utf8)
    }

    private func makeOpenAICompatibleManager() -> TTSNetworkManager {
        let manager = TestNetworkFactory.makeManager()
        manager.updateSettings(
            baseURL: "https://mock.api/v1/audio/speech",
            apiKey: "fake-key",
            model: "tts-test",
            voice: "test-voice",
            selectedProvider: "OpenAI"
        )
        return manager
    }

    private func response(for task: URLSessionDataTask,
                          statusCode: Int = 200,
                          contentType: String?) -> HTTPURLResponse {
        guard let url = task.currentRequest?.url else {
            preconditionFailure("A started task must retain the request it sent.")
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: contentType.map { ["Content-Type": $0] }
        ) else {
            preconditionFailure("A mock response must be constructible for a started task's URL.")
        }
        return response
    }

    private func receive(_ manager: TTSNetworkManager,
                         response: HTTPURLResponse,
                         for task: URLSessionDataTask) {
        manager.urlSession(manager.session, dataTask: task, didReceive: response) { disposition in
            XCTAssertEqual(
                disposition,
                .allow,
                "A refused format is dropped rather than cancelled, so the task ends with its own reason."
            )
        }
    }

    /// Starts a request whose response the test drives itself, and hands `body` its task.
    ///
    /// The mock handler is held open for the duration so URLSession cannot deliver a response of
    /// its own alongside the ones each test states.
    private func withStartedRequest(on manager: TTSNetworkManager,
                                    audio: @escaping @Sendable (Data) -> Void,
                                    body: (URLSessionDataTask) -> Void) {
        let requestStarted = expectation(description: "The request reaches the provider")
        let releaseResponse = DispatchSemaphore(value: 0)
        MockURLProtocol.installRequestHandler { request in
            requestStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 2.0)
            return (mockHTTPResponse(for: request, statusCode: 200), nil)
        }

        manager.streamTTS(text: "Response format test", dataHandler: audio)
        wait(for: [requestStarted], timeout: 2.0)
        defer { releaseResponse.signal() }
        guard let task = manager.activeTaskForTesting else {
            XCTFail("Expected streamTTS to retain the task it started.")
            return
        }
        body(task)
    }

    /// Waits for every callback already queued on the manager's delivery queue to run.
    private func drainAudioDelivery(of manager: TTSNetworkManager) {
        let drained = expectation(description: "Queued delivery callbacks have run")
        manager.audioDeliveryQueue.async { drained.fulfill() }
        wait(for: [drained], timeout: 2.0)
    }
}
