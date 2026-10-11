import XCTest
@testable import ClipboardTTSApp

final class TTSNetworkManagerSessionPolicyTests: MockURLProtocolTestCase {
    func testMockRoutedManagerSessionKeepsTheProductionPolicy() {
        // WHY: The production policy must prevent retained responses and shared credential state.
        // Routing is the only thing a caller may layer onto it, so the policy is read from the
        // session a mock-routed manager built for itself, and a request through that same session
        // must still reach MockURLProtocol, tagged with the scope that owns it, which is how that
        // scope accounts for the request and tears the session down.
        let manager = TestNetworkFactory.makeManager()
        assertProductionPolicy(manager.session.configuration)

        let expectedIdentifier = MockURLProtocol.currentTestIdentifier()
        let requestObserved = expectation(description: "Mock-routed request observed")
        MockURLProtocol.installRequestHandler { request in
            XCTAssertEqual(request.url?.absoluteString, "https://mock.api/v1/audio/speech")
            XCTAssertEqual(request.value(forHTTPHeaderField: MockURLProtocol.testIdentifierHeader), expectedIdentifier)
            requestObserved.fulfill()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }

        manager.updateSettings(
            baseURL: "https://mock.api/v1/audio/speech",
            apiKey: "test-key",
            model: "test-model",
            voice: "test-voice",
            selectedProvider: "OpenAI"
        )
        manager.streamTTS(text: "Test session policy") { _ in }

        wait(for: [requestObserved], timeout: 1.0)
    }
}

final class SessionConfigurationRoutingTests: XCTestCase {
    func testNoRoutingLeavesTheProductionPolicyOnTheSystemsOwnLoading() {
        // WHY: Production passes no routing, so the configuration it builds from must be the policy
        // alone: no protocol replacing the system's loading and no header added to its requests.
        // Reading the configuration rather than a manager's session keeps an unrouted session out
        // of the test process.
        let configuration = TTSNetworkManager.sessionConfiguration(routing: nil)
        assertProductionPolicy(configuration)
        XCTAssertNil(configuration.httpAdditionalHeaders)
        XCTAssertEqual(
            protocolIdentifiers(configuration.protocolClasses),
            protocolIdentifiers(URLSessionConfiguration.ephemeral.protocolClasses),
            "No routing must leave the system's own protocol list in place."
        )
    }

    func testRoutingIsLayeredOntoTheProductionPolicy() {
        // WHY: A routing layer may choose where requests load and which headers they carry, and
        // nothing about what the session retains.
        let configuration = TTSNetworkManager.sessionConfiguration(
            routing: TTSNetworkManager.SessionRouting(
                protocolClasses: [RefusingURLProtocol.self],
                additionalHeaders: ["X-Routing-Layer": "applied"]
            )
        )
        assertProductionPolicy(configuration)
        XCTAssertEqual(protocolIdentifiers(configuration.protocolClasses), [ObjectIdentifier(RefusingURLProtocol.self)])
        XCTAssertEqual(configuration.httpAdditionalHeaders?["X-Routing-Layer"] as? String, "applied")
    }

    private func protocolIdentifiers(_ classes: [AnyClass]?) -> [ObjectIdentifier] {
        (classes ?? []).map(ObjectIdentifier.init)
    }
}

/// Asserts the production session's non-persistent policy: no retained responses, cookies, or credentials.
private func assertProductionPolicy(_ configuration: URLSessionConfiguration,
                                    file: StaticString = #filePath,
                                    line: UInt = #line) {
    XCTAssertNil(configuration.urlCache, file: file, line: line)
    XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData, file: file, line: line)
    XCTAssertNil(configuration.httpCookieStorage, file: file, line: line)
    XCTAssertFalse(configuration.httpShouldSetCookies, file: file, line: line)
    XCTAssertNil(configuration.urlCredentialStorage, file: file, line: line)
}
