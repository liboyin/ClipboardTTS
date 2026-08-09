import Foundation
import XCTest
import AppKit
import Combine
@testable import ClipboardTTSApp

/// Returns a request body whether URLSession retained it as data or exposed it as a stream.
func requestBodyData(from request: URLRequest) -> Data? {
    if let httpBody = request.httpBody {
        return httpBody
    }
    guard let stream = request.httpBodyStream else {
        return nil
    }

    stream.open()
    defer { stream.close() }
    var body = Data()
    var buffer = [UInt8](repeating: 0, count: 1_024)
    while true {
        let bytesRead = stream.read(&buffer, maxLength: buffer.count)
        guard bytesRead > 0 else { break }
        body.append(buffer, count: bytesRead)
    }
    return body
}

extension XCTestCase {
    /// Waits for a request to publish its expected terminal state instead of relying on a timing delay.
    func assertTerminalState(of manager: TTSNetworkManager,
                             expectedError: String?,
                             after action: () -> Void) {
        let stateSettled = expectation(description: "Request reaches its expected terminal state")
        var observedActiveRequest = manager.isStreaming
        var didSettle = false
        let observation = Publishers.CombineLatest(manager.$lastError, manager.$isStreaming).sink { error, isStreaming in
            observedActiveRequest = observedActiveRequest || isStreaming
            guard error == expectedError,
                  !isStreaming,
                  !didSettle,
                  expectedError != nil || observedActiveRequest else { return }
            didSettle = true
            stateSettled.fulfill()
        }

        action()
        wait(for: [stateSettled], timeout: 2.0)
        observation.cancel()
    }
}

/// Creates sessions and network managers whose requests are always routed through MockURLProtocol.
enum TestNetworkFactory {
    static func makeManager(
        secretStore: SecretStoring = InMemorySecretStore(),
        requestBodyEncoder: @escaping (Data) throws -> Data = { $0 },
        audioDeliveryQueue: DispatchQueue = DispatchQueue(label: "com.clipboardtts.tests.audiodelivery")
    ) -> TTSNetworkManager {
        let testIdentifier = MockURLProtocol.currentTestIdentifier()
        return TTSNetworkManager(
            configuration: makeConfiguration(testIdentifier: testIdentifier),
            sessionCreated: { MockURLProtocol.register(session: $0, forTestIdentifier: testIdentifier) },
            sessionInvalidated: { MockURLProtocol.sessionDidInvalidate($0, forTestIdentifier: testIdentifier) },
            secretStore: secretStore,
            requestBodyEncoder: requestBodyEncoder,
            audioDeliveryQueue: audioDeliveryQueue
        )
    }

    static func makeSession() -> URLSession {
        let testIdentifier = MockURLProtocol.currentTestIdentifier()
        let delegate = TestSessionDelegate(testIdentifier: testIdentifier)
        let session = URLSession(
            configuration: makeConfiguration(testIdentifier: testIdentifier),
            delegate: delegate,
            delegateQueue: nil
        )
        MockURLProtocol.register(session: session, delegate: delegate, forTestIdentifier: testIdentifier)
        return session
    }

    private static func makeConfiguration(testIdentifier: String) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        configuration.httpAdditionalHeaders = [
            MockURLProtocol.testIdentifierHeader: testIdentifier
        ]
        return configuration
    }
}

/// Signals when a factory-created session has invalidated, completing its test scope's barrier.
private final class TestSessionDelegate: NSObject, URLSessionDelegate {
    private let testIdentifier: String

    init(testIdentifier: String) {
        self.testIdentifier = testIdentifier
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        MockURLProtocol.sessionDidInvalidate(session, forTestIdentifier: testIdentifier)
    }
}

/// Serializes tests using MockURLProtocol and clears its process-global handler at each boundary.
class MockURLProtocolTestCase: XCTestCase {
    private static let testExecutionLock = NSLock()
    private var testIdentifier: String?
    private var postQuiescenceAssertions: [() -> Void] = []

    /// Queues an assertion that runs after the mock scope has invalidated sessions and drained loads.
    func assertAfterMockQuiescence(_ assertion: @escaping () -> Void) {
        postQuiescenceAssertions.append(assertion)
    }

    override func setUp() {
        super.setUp()
        MockURLProtocolTestCase.testExecutionLock.lock()
        testIdentifier = MockURLProtocol.beginTest()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        guard let testIdentifier else {
            XCTFail("MockURLProtocol test scope was not created.")
            MockURLProtocolTestCase.testExecutionLock.unlock()
            super.tearDown()
            return
        }

        MockURLProtocol.reset()
        let unhandledRequests = MockURLProtocol.endTest(identifier: testIdentifier)
        XCTAssertTrue(
            unhandledRequests.didQuiesce,
            "Mock-routed sessions or protocol loads did not finish before the test scope ended."
        )
        XCTAssertEqual(
            unhandledRequests.observedUnhandledRequestCount,
            unhandledRequests.expectedUnhandledRequestCount,
            "Unexpected mock-routed request without an installed handler."
        )
        postQuiescenceAssertions.forEach { $0() }
        postQuiescenceAssertions.removeAll()
        self.testIdentifier = nil
        MockURLProtocolTestCase.testExecutionLock.unlock()
        super.tearDown()
    }
}

final class FakePasteboardReader: PasteboardReading {
    private let text: String?

    init(text: String? = nil) {
        self.text = text
    }

    func string(forType dataType: NSPasteboard.PasteboardType) -> String? {
        text
    }
}
