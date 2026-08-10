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
        let testIdentifier = MockURLProtocol.beginManagerConstructionForCurrentTest()
        defer { MockURLProtocol.managerConstructionDidFinish(forTestIdentifier: testIdentifier) }
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
    private static let testExecutionGate = DispatchSemaphore(value: 1)
    private static let testExecutionGateDepthKey = "com.clipboardtts.tests.mockurlprotocol.gatedepth"
    fileprivate static let testExecutionLock = NSRecursiveLock()
    private var testIdentifier: String?
    private var settingsSnapshot: UserDefaultsSnapshot?
    private var acquiredTestExecutionGate = false
    private var teardownRecovery: DispatchSemaphore?
    private var postQuiescenceAssertions: [() -> Void] = []

    /// Queues an assertion that runs after the mock scope has invalidated sessions and drained loads.
    func assertAfterMockQuiescence(_ assertion: @escaping () -> Void) {
        postQuiescenceAssertions.append(assertion)
    }

    /// Waits for timeout recovery when a nested test scope owns the mock-test gate.
    func waitForSettingsRestorationAfterTeardown() {
        teardownRecovery?.wait()
        teardownRecovery = nil
    }

    override func setUp() {
        super.setUp()
        MockURLProtocolTestCase.testExecutionLock.lock()
        acquiredTestExecutionGate = MockURLProtocolTestCase.enterTestExecutionGate()
        testIdentifier = MockURLProtocol.beginTest()
        MockURLProtocol.reset()
        settingsSnapshot = UserDefaultsSnapshot(keys: SettingsKeys.allUserDefaultsKeys)
        SettingsKeys.allUserDefaultsKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    override func tearDown() {
        guard let testIdentifier else {
            XCTFail("MockURLProtocol test scope was not created.")
            settingsSnapshot?.restore()
            settingsSnapshot = nil
            MockURLProtocolTestCase.leaveTestExecutionGate()
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
        let capturedSettingsSnapshot = self.settingsSnapshot
        self.settingsSnapshot = nil
        if unhandledRequests.didQuiesce {
            postQuiescenceAssertions.forEach { $0() }
            capturedSettingsSnapshot?.restore()
            MockURLProtocolTestCase.leaveTestExecutionGate()
        } else {
            let recovery = DispatchSemaphore(value: 0)
            teardownRecovery = recovery
            if acquiredTestExecutionGate {
                MockURLProtocolTestCase.abandonTestExecutionGateUntilRecovery()
            } else {
                MockURLProtocolTestCase.leaveTestExecutionGate()
            }
            let shouldReleaseGateAfterRecovery = acquiredTestExecutionGate
            DispatchQueue.global(qos: .userInitiated).async {
                MockURLProtocol.finishClosingTestWhenQuiescent(identifier: testIdentifier)
                capturedSettingsSnapshot?.restore()
                recovery.signal()
                if shouldReleaseGateAfterRecovery {
                    MockURLProtocolTestCase.testExecutionGate.signal()
                }
            }
        }
        postQuiescenceAssertions.removeAll()
        self.testIdentifier = nil
        MockURLProtocolTestCase.testExecutionLock.unlock()
        super.tearDown()
    }

    /// Enters the process-wide mock-test gate, supporting the nested lifecycle test scope.
    fileprivate static func enterTestExecutionGate() -> Bool {
        let threadDictionary = Thread.current.threadDictionary
        let depth = threadDictionary[testExecutionGateDepthKey] as? Int ?? 0
        if depth == 0 {
            testExecutionGate.wait()
        }
        threadDictionary[testExecutionGateDepthKey] = depth + 1
        return depth == 0
    }

    /// Leaves one nested mock-test gate scope, releasing the next test at the outermost boundary.
    fileprivate static func leaveTestExecutionGate() {
        let threadDictionary = Thread.current.threadDictionary
        let depth = threadDictionary[testExecutionGateDepthKey] as? Int ?? 0
        precondition(depth > 0, "MockURLProtocol test gate was released without a matching acquisition.")
        if depth == 1 {
            threadDictionary.removeObject(forKey: testExecutionGateDepthKey)
            testExecutionGate.signal()
        } else {
            threadDictionary[testExecutionGateDepthKey] = depth - 1
        }
    }

    /// Removes the current thread's gate ownership while an asynchronous timeout recovery retains it.
    fileprivate static func abandonTestExecutionGateUntilRecovery() {
        let threadDictionary = Thread.current.threadDictionary
        let depth = threadDictionary[testExecutionGateDepthKey] as? Int ?? 0
        precondition(depth == 1, "Only an outermost mock-test scope can defer its gate release.")
        threadDictionary.removeObject(forKey: testExecutionGateDepthKey)
    }
}

final class MockURLProtocolSettingsIsolationTests: MockURLProtocolTestCase {
    private var seededValues: [String: String] = [:]

    override func invokeTest() {
        // WHY: This runs before the inherited per-test setup, letting the test seed the real
        // defaults domain exactly as a developer installation might. The recursive test lock
        // makes that short pre-setup interval exclusive with every other mock-network test.
        let acquiredTestExecutionGate = MockURLProtocolTestCase.enterTestExecutionGate()
        MockURLProtocolTestCase.testExecutionLock.lock()
        let developerSnapshot = UserDefaultsSnapshot(keys: SettingsKeys.allUserDefaultsKeys)
        defer {
            developerSnapshot.restore()
            MockURLProtocolTestCase.testExecutionLock.unlock()
            if acquiredTestExecutionGate {
                MockURLProtocolTestCase.leaveTestExecutionGate()
            }
        }

        seededValues = Dictionary(
            uniqueKeysWithValues: SettingsKeys.allUserDefaultsKeys.enumerated().compactMap { index, key in
                guard index.isMultiple(of: 2) || key == SettingsKeys.legacyOpenAIAPIKey else { return nil }
                return (key, "developer-value-\(key)")
            }
        )
        SettingsKeys.allUserDefaultsKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        seededValues.forEach { key, value in
            UserDefaults.standard.set(value, forKey: key)
        }

        super.invokeTest()
        waitForSettingsRestorationAfterTeardown()

        for key in SettingsKeys.allUserDefaultsKeys {
            XCTAssertEqual(
                UserDefaults.standard.string(forKey: key),
                seededValues[key],
                "The mock-network lifecycle must restore \(key) after the test finishes."
            )
        }
    }

    func testManagerStartupCannotMigrateSeededSettingsOutsideTheMockTestScope() {
        // WHY: Manager startup always invokes legacy-key migration. It must see the isolated
        // defaults domain, so that the test cannot migrate or delete a developer's plaintext key.
        _ = TestNetworkFactory.makeManager()
        for key in SettingsKeys.allUserDefaultsKeys {
            XCTAssertNil(UserDefaults.standard.object(forKey: key), "\(key) should be isolated during the test.")
        }
        assertAfterMockQuiescence {
            for key in SettingsKeys.allUserDefaultsKeys {
                XCTAssertNil(
                    UserDefaults.standard.object(forKey: key),
                    "\(key) must remain isolated until mock sessions and loads are quiescent."
                )
            }
        }
    }
}

final class MockURLProtocolConstructionTests: XCTestCase {
    func testClosingScopeWaitsForManagerInitializationBeforeItCanQuiesce() {
        // WHY: TTSNetworkManager reads and migrates settings before it registers its URLSession.
        // Treating that interval as quiescent would restore developer settings while migration is
        // still active, letting the late initializer mutate them after teardown.
        MockURLProtocolTestCase.testExecutionLock.lock()
        let acquiredTestExecutionGate = MockURLProtocolTestCase.enterTestExecutionGate()
        defer {
            if acquiredTestExecutionGate {
                MockURLProtocolTestCase.leaveTestExecutionGate()
            }
            MockURLProtocolTestCase.testExecutionLock.unlock()
        }

        let testIdentifier = MockURLProtocol.beginTest()
        _ = MockURLProtocol.beginManagerConstructionForCurrentTest()

        let endResult = MockURLProtocol.endTest(identifier: testIdentifier, timeout: 0)

        XCTAssertFalse(endResult.didQuiesce, "An initializing manager must keep settings restoration blocked.")
        MockURLProtocol.managerConstructionDidFinish(forTestIdentifier: testIdentifier)
        MockURLProtocol.finishClosingTestWhenQuiescent(identifier: testIdentifier)
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
