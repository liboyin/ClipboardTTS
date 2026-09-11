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

    func testACleartextRedirectOfADiscoveryRequestIsAlsoRefused() {
        // WHY: URLSession consults this delegate for the completion-handler tasks discovery uses,
        // and those requests carry the same bearer key. The refusal must not depend on the task
        // being the active speech request, which a guard written only for speech would.
        let releaseResponse = DispatchSemaphore(value: 0)
        let manager = makeCustomManager()
        guard let task = startBlockedDiscoveryRequest(on: manager, releasedBy: releaseResponse) else { return }
        defer { releaseResponse.signal() }

        var followedRequest: URLRequest?
        manager.urlSession(
            manager.session,
            task: task,
            willPerformHTTPRedirection: redirectResponse(for: task),
            newRequest: redirectRequest(to: "http://models.example.com/v1/models")
        ) { followedRequest = $0 }

        XCTAssertNil(followedRequest, "A discovery redirect to cleartext must not be followed.")
        XCTAssertEqual(manager.modelSuggestions.values, [], "A refused discovery redirect must publish nothing.")
    }

    func testAForeignOriginRedirectOfADiscoveryRequestIsRefusedSilently() {
        // WHY: Discovery carries the same bearer key to the same configured origin, so it answers
        // to the same destination rule. It has no session to fail and no speech state to publish —
        // a metadata failure is silent, as every other one is — so the refusal must be recorded
        // against the speech request only when the task is that request.
        let releaseResponse = DispatchSemaphore(value: 0)
        let manager = makeCustomManager()
        guard let task = startBlockedDiscoveryRequest(on: manager, releasedBy: releaseResponse) else { return }
        defer { releaseResponse.signal() }

        var followedRequest: URLRequest?
        manager.urlSession(
            manager.session,
            task: task,
            willPerformHTTPRedirection: redirectResponse(for: task),
            newRequest: redirectRequest(to: "https://models.example.com/v1/models")
        ) { followedRequest = $0 }

        XCTAssertNil(followedRequest, "A discovery redirect to a foreign origin must not be followed.")
        XCTAssertEqual(manager.modelSuggestions.values, [], "A refused discovery redirect must publish nothing.")
        XCTAssertNil(manager.lastError, "A refused discovery redirect must stay silent.")
    }

    func testARefusedDiscoveryRedirectLeavesTheSpeechRequestInFlightAlone() {
        // WHY: Settings fetches models when it opens, so a discovery task and a speech request are
        // alive together whenever the user opens it during playback. Recording a refusal against
        // whichever request happens to be active would stop speech the provider never redirected,
        // and a metadata failure has no voice of its own to say so. The speech request here is left
        // to finish on its own response, because what distinguishes the two outcomes is which
        // failure it publishes: its provider's status, or a refusal that was never its own.
        let manager = makeCustomManager()
        let releaseDiscovery = DispatchSemaphore(value: 0)
        let discoveryStarted = expectation(description: "The discovery request starts")
        MockURLProtocol.installRequestHandler { request in
            if request.url?.absoluteString.contains("/models") == true {
                discoveryStarted.fulfill()
                _ = releaseDiscovery.wait(timeout: .now() + 2.0)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 307, httpVersion: nil, headerFields: nil)!
            return (response, nil)
        }
        manager.fetchAvailableModels(
            baseURL: "https://custom.api/v1/audio/speech",
            apiKey: "test-custom-api-key",
            selectedProvider: "Custom"
        )
        wait(for: [discoveryStarted], timeout: 2.0)
        manager.streamTTS(text: "Speak while Settings is open") { _ in }
        guard let discoveryTask = manager.modelMetadataTaskForTesting() else {
            XCTFail("The started discovery request must own a metadata task.")
            releaseDiscovery.signal()
            return
        }

        manager.urlSession(
            manager.session,
            task: discoveryTask,
            willPerformHTTPRedirection: redirectResponse(for: discoveryTask),
            newRequest: redirectRequest(to: "https://models.example.com/v1/models")
        ) { XCTAssertNil($0, "A discovery redirect to a foreign origin must not be followed.") }

        // Releasing the held discovery response lets the speech request reach its own, which is a
        // plain 307 it never asked to follow: the status is what it must report.
        assertTerminalState(of: manager, expectedError: "Speech request failed (HTTP 307).") {
            releaseDiscovery.signal()
        }
    }
}
