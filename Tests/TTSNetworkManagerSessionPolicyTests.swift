import XCTest
@testable import ClipboardTTSApp

final class TTSNetworkManagerSessionPolicyTests: MockURLProtocolTestCase {
    func testProductionSessionPolicyDisablesPersistenceWhileRetainingMockRouting() {
        // WHY: The production policy must prevent retained responses and shared credential state,
        // but tests still need MockURLProtocol to own each request and session teardown.
        let productionManager = TestNetworkFactory.makeManager(
            sessionConfiguration: .productionDefault
        )
        let configuration = productionManager.session.configuration
        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.urlCredentialStorage)

        let manager = TestNetworkFactory.makeManager(
            sessionConfiguration: .provided(TTSNetworkManager.productionSessionConfiguration())
        )
        let mockConfiguration = manager.session.configuration
        XCTAssertNil(mockConfiguration.urlCache)
        XCTAssertEqual(mockConfiguration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(mockConfiguration.httpCookieStorage)
        XCTAssertFalse(mockConfiguration.httpShouldSetCookies)
        XCTAssertNil(mockConfiguration.urlCredentialStorage)

        let requestObserved = expectation(description: "Mock-routed request observed")
        MockURLProtocol.installRequestHandler { request in
            XCTAssertEqual(request.url?.absoluteString, "https://mock.api/v1/audio/speech")
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
