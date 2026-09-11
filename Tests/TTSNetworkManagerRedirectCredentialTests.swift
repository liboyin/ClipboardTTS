import XCTest
@testable import ClipboardTTSApp

/// Covers what a followed redirect carries: that a permitted target is still reached with its
/// request's own replay state, and that it authenticates with the credential that request was
/// built with and no other. `TTSNetworkManagerRedirectTests` owns which targets are refused, and
/// `RedirectTestSupport` owns the started requests both suites drive.
final class TTSNetworkManagerRedirectCredentialTests: MockURLProtocolTestCase {
    func testASameOriginRedirectIsStillFollowedAndDeliversItsAudio() {
        // WHY: The rule refuses a foreign recipient, not redirection. A provider that moves its
        // speech path within its own origin must keep working, or the guard would break an
        // ordinary deployment change while protecting nothing. What is followed is the request
        // URLSession built, with only its credentials replaced: a 307 replays the method and the
        // body, and rebuilding a request around the target URL would drop both. The method and
        // content headers are what a test can hold it to — the body URLSession replays is not on
        // this request at all, which is why the delegate copies it rather than building its own.
        let manager = makeCustomManager()
        let releaseResponse = DispatchSemaphore(value: 0)
        let audioDelivered = expectation(description: "The followed redirect still delivers audio")
        guard let task = startBlockedRequest(on: manager, releasedBy: releaseResponse, dataHandler: { data in
            XCTAssertEqual(data, Data([0, 1]))
            audioDelivered.fulfill()
        }) else { return }
        defer { releaseResponse.signal() }

        let relocated = URL(string: "https://custom.api/v2/audio/speech")!
        var followedRequest: URLRequest?
        manager.urlSession(
            manager.session,
            task: task,
            willPerformHTTPRedirection: redirectResponse(for: task),
            newRequest: redirectRequest(to: relocated.absoluteString)
        ) { followedRequest = $0 }

        XCTAssertEqual(followedRequest?.url, relocated, "A permitted redirect target must be followed.")
        XCTAssertEqual(
            followedRequest?.httpMethod,
            "POST",
            "A followed redirect must replay the method its own 307 asked for."
        )
        XCTAssertEqual(
            followedRequest?.value(forHTTPHeaderField: "Content-Type"),
            "application/json",
            "A followed redirect must keep the request URLSession built, apart from its credentials."
        )
        manager.urlSession(
            manager.session,
            dataTask: task,
            didReceive: HTTPURLResponse(url: relocated, statusCode: 200, httpVersion: nil, headerFields: nil)!
        ) { _ in }
        manager.urlSession(manager.session, dataTask: task, didReceive: Data([0, 1]))
        wait(for: [audioDelivered], timeout: 2.0)

        assertTerminalState(of: manager, expectedError: nil) {
            manager.urlSession(manager.session, task: task, didCompleteWithError: nil)
        }
    }
    func testARedirectBelongsToTheRequestThatStartedRatherThanToSettingsEditedSince() {
        // WHY: Settings can change while a request is in flight — the user corrects the endpoint or
        // pastes a new key mid-stream — and a request owns the origin and credential it was built
        // with, exactly as its retry replays the request it sent. Reading either from current
        // settings would refuse this request's own redirect while making the newly typed endpoint
        // the one origin a redirect could reach, and would hand it a key that origin never issued.
        let manager = makeCustomManager()
        let releaseResponse = DispatchSemaphore(value: 0)
        guard let task = startBlockedRequest(on: manager, releasedBy: releaseResponse, dataHandler: { _ in
        }) else { return }
        defer { releaseResponse.signal() }
        manager.updateSettings(
            baseURL: "https://replacement.custom.api/v1/audio/speech",
            apiKey: "test-replacement-api-key",
            model: "test-model",
            voice: "test-voice",
            selectedProvider: "Custom"
        )

        var followedOwnOrigin: URLRequest?
        manager.urlSession(
            manager.session,
            task: task,
            willPerformHTTPRedirection: redirectResponse(for: task),
            newRequest: redirectRequest(to: "https://custom.api/v2/audio/speech")
        ) { followedOwnOrigin = $0 }

        XCTAssertEqual(
            followedOwnOrigin?.url?.absoluteString,
            "https://custom.api/v2/audio/speech",
            "A request's own origin stays reachable however Settings changed since it started."
        )
        XCTAssertEqual(
            followedOwnOrigin?.value(forHTTPHeaderField: "Authorization"),
            "Bearer test-custom-api-key",
            "A followed redirect must carry the key its request was built with, not the newer one."
        )

        var followedReplacementOrigin: URLRequest?
        manager.urlSession(
            manager.session,
            task: task,
            willPerformHTTPRedirection: redirectResponse(for: task),
            newRequest: redirectRequest(to: "https://replacement.custom.api/v1/audio/speech")
        ) { followedReplacementOrigin = $0 }

        XCTAssertNil(
            followedReplacementOrigin,
            "An endpoint saved after this request started authorizes nothing for it."
        )
    }
    func testAFollowedRedirectCarriesItsRequestsBearerKeyAndNoOtherCredential() {
        // WHY: CFNetwork strips `Authorization` from every redirect it builds, a same-origin one
        // included — probed on this toolchain — so following the request it hands over unchanged
        // would fail authentication at the provider's own new path. What is restored is the value
        // this request was built with, which is also what removes a credential header the app never
        // authorized: a redirect carries exactly the credentials its own request did.
        let manager = makeCustomManager()
        let releaseResponse = DispatchSemaphore(value: 0)
        guard let task = startBlockedRequest(on: manager, releasedBy: releaseResponse, dataHandler: { _ in
        }) else { return }
        defer { releaseResponse.signal() }

        var followedRequest: URLRequest?
        manager.urlSession(
            manager.session,
            task: task,
            willPerformHTTPRedirection: redirectResponse(for: task),
            newRequest: redirectRequest(
                to: "https://custom.api/v2/audio/speech",
                carrying: ["x-goog-api-key": "unauthorized-key-from-the-response"]
            )
        ) { followedRequest = $0 }

        XCTAssertEqual(
            followedRequest?.value(forHTTPHeaderField: "Authorization"),
            "Bearer test-custom-api-key",
            "A followed redirect must authenticate with the key its own request carried."
        )
        XCTAssertNil(
            followedRequest?.value(forHTTPHeaderField: "x-goog-api-key"),
            "A followed redirect must not carry a credential the request never authorized."
        )
    }
    func testAFollowedGeminiRedirectCarriesItsRequestsAPIKeyHeaderAndNoOtherCredential() {
        // WHY: The app's contract is the request's own credential, not the subset CFNetwork
        // happens to preserve today — it keeps `x-goog-api-key` and drops `Authorization`, which is
        // the more dangerous half of that behaviour and is not a guarantee to build on. Gemini
        // authenticates through the header CFNetwork currently keeps, so this is the case where a
        // restoration written only for the bearer shape would silently do nothing.
        let manager = makeGeminiManager()
        let releaseResponse = DispatchSemaphore(value: 0)
        guard let task = startBlockedRequest(on: manager, releasedBy: releaseResponse, dataHandler: { _ in
        }) else { return }
        defer { releaseResponse.signal() }

        var followedRequest: URLRequest?
        manager.urlSession(
            manager.session,
            task: task,
            willPerformHTTPRedirection: redirectResponse(for: task),
            newRequest: redirectRequest(
                to: "https://generativelanguage.googleapis.com/v1beta/models/relocated:streamGenerateContent",
                carrying: ["Authorization": "Bearer unauthorized-key-from-the-response"]
            )
        ) { followedRequest = $0 }

        XCTAssertEqual(
            followedRequest?.value(forHTTPHeaderField: "x-goog-api-key"),
            "test-gemini-api-key",
            "A followed Gemini redirect must authenticate with the key its own request carried."
        )
        XCTAssertNil(
            followedRequest?.value(forHTTPHeaderField: "Authorization"),
            "A followed redirect must not carry a credential the request never authorized."
        )
    }
    func testAFollowedDiscoveryRedirectCarriesItsRequestsBearerKey() {
        // WHY: Discovery loses the same stripped `Authorization` header a speech request does, and
        // it authenticates with the same saved key, so the restoration cannot be written only for
        // the task the manager happens to be tracking as its active speech request.
        let releaseResponse = DispatchSemaphore(value: 0)
        let manager = makeCustomManager()
        guard let task = startBlockedDiscoveryRequest(on: manager, releasedBy: releaseResponse) else { return }
        defer { releaseResponse.signal() }

        var followedRequest: URLRequest?
        manager.urlSession(
            manager.session,
            task: task,
            willPerformHTTPRedirection: redirectResponse(for: task),
            newRequest: redirectRequest(to: "https://custom.api/v2/models")
        ) { followedRequest = $0 }

        XCTAssertEqual(
            followedRequest?.value(forHTTPHeaderField: "Authorization"),
            "Bearer test-custom-api-key",
            "A followed discovery redirect must authenticate with the key its own request carried."
        )
    }
}
