import Combine
import XCTest
@testable import ClipboardTTSApp

final class TTSNetworkManagerRequestLifecycleTests: MockURLProtocolTestCase {
    func testNestedStopAndRetryObserverKeepsTheReplacementRequestActive() {
        // WHY: A synchronous observer can stop a request during one published mutation and retry
        // during a nested mutation. The outer failure must not later mark that replacement idle.
        let manager = TestNetworkFactory.makeManager()
        manager.updateSettings(
            baseURL: "not a valid endpoint",
            apiKey: "fake-key",
            model: "test",
            voice: "test",
            selectedProvider: "OpenAI"
        )
        manager.streamTTS(text: "Create generation one") { _ in }
        manager.updateSettings(baseURL: "https://mock.api/v1/audio/speech", apiKey: "fake-key", model: "test", voice: "test", selectedProvider: "OpenAI")

        let replacementStarted = expectation(description: "Nested replacement starts")
        let releaseResponse = DispatchSemaphore(value: 0)
        MockURLProtocol.installRequestHandler { request in
            replacementStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 1.0)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data([0, 1]))
        }

        var publicationCount = 0
        let observation = manager.objectWillChange.sink {
            publicationCount += 1
            if publicationCount == 1 {
                manager.stopStreaming()
            } else if publicationCount == 4 {
                manager.streamTTS(text: "Nested replacement") { _ in }
            }
        }
        defer { observation.cancel() }

        manager.publishFailure("Generation one failure", requestGeneration: 1)
        wait(for: [replacementStarted], timeout: 2.0)
        XCTAssertNil(manager.lastError)
        XCTAssertTrue(manager.isStreaming)

        assertTerminalState(of: manager, expectedError: nil) {
            releaseResponse.signal()
        }
    }
}
