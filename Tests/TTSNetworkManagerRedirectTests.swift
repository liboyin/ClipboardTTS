import XCTest
@testable import ClipboardTTSApp

/// Covers where a started request may be redirected: which targets are refused, and how each
/// refusal is reported to the request that owns the refused task. `EndpointTransportPolicyTests`
/// owns the transport and origin rules themselves, `TTSNetworkManagerRedirectCredentialTests` owns
/// what a followed redirect carries, and `RedirectTestSupport` owns the started requests both use.
final class TTSNetworkManagerRedirectTests: MockURLProtocolTestCase {
    private static let insecureTransportError =
        "The TTS endpoint must use HTTPS unless it runs on localhost. Update Settings and try again."
    private static let foreignOriginRedirectError =
        "The TTS service redirected to a different address, so your key was not sent. Check the API endpoint in Settings and try again."

    func testACleartextRedirectIsRefusedAndReportedAsATransportFailure() {
        // WHY: URLSession follows redirects on its own, and a 307 or 308 replays the original
        // method and body — the user's clipboard text — at whatever endpoint the response names.
        // Checking only the configured endpoint would let a provider move a started request onto
        // cleartext, and the user must be told that rather than shown its redirect status. This
        // target is a foreign origin as well, which pins the order the two refusals are reported
        // in: cleartext is the one the user can act on, and its remedy is the documented one.
        let manager = makeCustomManager()
        let releaseResponse = DispatchSemaphore(value: 0)
        guard let task = startBlockedRequest(on: manager, releasedBy: releaseResponse, dataHandler: { _ in
            XCTFail("A refused redirect must not produce audio.")
        }) else { return }
        defer { releaseResponse.signal() }

        var didAnswerRedirect = false
        var followedRequest: URLRequest?
        manager.urlSession(
            manager.session,
            task: task,
            willPerformHTTPRedirection: redirectResponse(for: task),
            newRequest: redirectRequest(to: "http://tts.example.com/v1/audio/speech")
        ) { request in
            didAnswerRedirect = true
            followedRequest = request
        }

        XCTAssertTrue(didAnswerRedirect, "The redirect decision must be answered so the task can finish.")
        XCTAssertNil(followedRequest, "A cleartext redirect target must not be followed.")
        assertTerminalState(of: manager, expectedError: Self.insecureTransportError) {
            manager.urlSession(manager.session, task: task, didCompleteWithError: nil)
        }
    }

    func testAForeignOriginRedirectIsRefusedAndReportedRatherThanItsRedirectStatus() {
        // WHY: CFNetwork replays this app's own `x-goog-api-key` header — and the POST body holding
        // the user's clipboard text — at whatever host a 307 names, which a loopback probe
        // confirmed on Xcode 26.6 (CFNetwork 3860.700.1). HTTPS protects that traffic in transit
        // and says nothing about who receives it, so the destination must answer to the origin the
        // request was built for. Refusing leaves the task to finish on the redirect response
        // itself, so the refusal has to outrank the 3xx status the user cannot act on.
        let manager = makeCustomManager()
        let releaseResponse = DispatchSemaphore(value: 0)
        guard let task = startBlockedRequest(on: manager, releasedBy: releaseResponse, dataHandler: { _ in
            XCTFail("A refused redirect must not produce audio.")
        }) else { return }
        defer { releaseResponse.signal() }

        var didAnswerRedirect = false
        var followedRequest: URLRequest?
        manager.urlSession(
            manager.session,
            task: task,
            willPerformHTTPRedirection: redirectResponse(for: task),
            newRequest: redirectRequest(to: "https://relocated.custom.api/v1/audio/speech")
        ) { request in
            didAnswerRedirect = true
            followedRequest = request
        }

        XCTAssertTrue(didAnswerRedirect, "The redirect decision must be answered so the task can finish.")
        XCTAssertNil(followedRequest, "A foreign-origin redirect target must not be followed.")
        manager.urlSession(manager.session, dataTask: task, didReceive: redirectResponse(for: task)) { _ in }
        assertTerminalState(of: manager, expectedError: Self.foreignOriginRedirectError) {
            manager.urlSession(manager.session, task: task, didCompleteWithError: nil)
        }
    }

    func testACleartextRedirectOfARealtimeHandshakeIsAlsoRefused() {
        // WHY: URLSession consults this delegate for every task the session owns, and a Realtime
        // handshake carries the same bearer key. The refusal must not depend on the task being the
        // active speech request, which a guard written only for data tasks would.
        let manager = makeCustomManager()
        let task = makeUnstartedRealtimeHandshake(on: manager)

        var followedRequest: URLRequest?
        manager.urlSession(
            manager.session,
            task: task,
            willPerformHTTPRedirection: redirectResponse(for: task),
            newRequest: redirectRequest(to: "http://realtime.example.com/v1/realtime")
        ) { followedRequest = $0 }

        XCTAssertNil(followedRequest, "A handshake redirect to cleartext must not be followed.")
        XCTAssertNil(manager.lastError, "A refusal that belongs to no data task must publish nothing itself.")
    }

    func testAForeignOriginRedirectOfARealtimeHandshakeIsRefusedWithoutBeingRecordedAsSpeech() {
        // WHY: The handshake carries the key to OpenAI's own origin, so it answers to the same
        // destination rule. It is not the active data task, so the refusal must not be recorded
        // against one: the Realtime request reports the failed handshake itself, as a lost
        // connection.
        let manager = makeCustomManager()
        let task = makeUnstartedRealtimeHandshake(on: manager)

        var followedRequest: URLRequest?
        manager.urlSession(
            manager.session,
            task: task,
            willPerformHTTPRedirection: redirectResponse(for: task),
            newRequest: redirectRequest(to: "https://realtime.example.com/v1/realtime")
        ) { followedRequest = $0 }

        XCTAssertNil(followedRequest, "A handshake redirect to a foreign origin must not be followed.")
        XCTAssertNil(manager.lastError, "A refusal that belongs to no data task must publish nothing itself.")
    }

    func testARefusedHandshakeRedirectLeavesTheSpeechRequestInFlightAlone() {
        // WHY: A task that is not the active data task can be refused while a speech request is in
        // flight. Recording that refusal against whichever request happens to be active would stop
        // speech the provider never redirected. The speech request here is left to finish on its own
        // response, because what distinguishes the two outcomes is which failure it publishes: its
        // provider's status, or a refusal that was never its own.
        let manager = makeCustomManager()
        let releaseSpeech = DispatchSemaphore(value: 0)
        guard let speechTask = startBlockedRequest(on: manager, releasedBy: releaseSpeech, dataHandler: { _ in }) else { return }
        defer { releaseSpeech.signal() }
        let handshake = makeUnstartedRealtimeHandshake(on: manager)

        manager.urlSession(
            manager.session,
            task: handshake,
            willPerformHTTPRedirection: redirectResponse(for: handshake),
            newRequest: redirectRequest(to: "https://realtime.example.com/v1/realtime")
        ) { XCTAssertNil($0, "A handshake redirect to a foreign origin must not be followed.") }
        XCTAssertEqual(manager.activeTaskForTesting?.taskIdentifier, speechTask.taskIdentifier)

        // Releasing the held response lets the speech request reach its own, which is a plain 307 it
        // never asked to follow: the status is what it must report.
        assertTerminalState(of: manager, expectedError: "Speech request failed (HTTP 307).") {
            releaseSpeech.signal()
        }
    }
}
