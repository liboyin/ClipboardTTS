import XCTest

final class MockURLProtocolTests: MockURLProtocolTestCase {
    func testMockSessionCarriesItsCreationIdentifier() {
        let expectedIdentifier = MockURLProtocol.currentTestIdentifier()
        let completion = expectation(description: "Mock-routed request completed")
        let request = URLRequest(url: URL(string: "https://mock.api/session-identifier")!)

        MockURLProtocol.installRequestHandler { request in
            XCTAssertEqual(
                request.value(forHTTPHeaderField: MockURLProtocol.testIdentifierHeader),
                expectedIdentifier
            )
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }

        TestNetworkFactory.makeSession().dataTask(with: request) { _, _, _ in
            completion.fulfill()
        }.resume()

        wait(for: [completion], timeout: 2.0)
    }

    func testMissingHandlerReportsURLLoadingError() {
        MockURLProtocol.expectUnhandledRequests()
        let completion = expectation(description: "Missing handler fails the request")
        let request = URLRequest(url: URL(string: "https://mock.api/missing-handler")!)

        TestNetworkFactory.makeSession().dataTask(with: request) { data, response, error in
            XCTAssertNil(data)
            XCTAssertNil(response)
            XCTAssertEqual((error as? URLError)?.code, .cannotLoadFromNetwork)
            completion.fulfill()
        }.resume()

        wait(for: [completion], timeout: 2.0)
    }

    func testResetPreventsAFormerHandlerFromServingLaterRequests() {
        MockURLProtocol.installRequestHandler { request in
            XCTFail("A reset handler must not serve a later request")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        MockURLProtocol.reset()
        MockURLProtocol.expectUnhandledRequests()

        let completion = expectation(description: "Reset handler fails the request")
        let request = URLRequest(url: URL(string: "https://mock.api/reset-handler")!)

        TestNetworkFactory.makeSession().dataTask(with: request) { _, _, error in
            XCTAssertEqual((error as? URLError)?.code, .cannotLoadFromNetwork)
            completion.fulfill()
        }.resume()

        wait(for: [completion], timeout: 2.0)
    }

    func testTearDownWaitsForAnInFlightHandlerBeforeReleasingTheTestScope() {
        let requestStarted = expectation(description: "Mock request started")
        let releaseHandler = DispatchSemaphore(value: 0)
        let handlerFinished = LockedFlag()

        MockURLProtocol.installRequestHandler { request in
            requestStarted.fulfill()
            _ = releaseHandler.wait(timeout: .now() + 1.0)
            handlerFinished.set()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }

        TestNetworkFactory.makeSession().dataTask(
            with: URL(string: "https://mock.api/in-flight-handler")!
        ).resume()
        wait(for: [requestStarted], timeout: 1.0)

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            releaseHandler.signal()
        }
        assertAfterMockQuiescence {
            XCTAssertTrue(handlerFinished.value)
        }
    }

    func testTearDownInvalidatesSessionsBeforeADeferredTaskCanStartLoading() {
        let handlerWasCalled = LockedFlag()
        let resumeTask = DispatchSemaphore(value: 0)
        let resumeAttempted = DispatchSemaphore(value: 0)

        MockURLProtocol.installRequestHandler { request in
            handlerWasCalled.set()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }

        let session = TestNetworkFactory.makeSession()
        let task = session.dataTask(with: URL(string: "https://mock.api/deferred-task")!)
        DispatchQueue.global().async {
            _ = resumeTask.wait(timeout: .now() + 1.0)
            task.resume()
            resumeAttempted.signal()
        }

        assertAfterMockQuiescence {
            resumeTask.signal()
            XCTAssertEqual(resumeAttempted.wait(timeout: .now() + 1.0), .success)
            Thread.sleep(forTimeInterval: 0.1)
            XCTAssertFalse(handlerWasCalled.value)
        }
    }
}

private final class LockedFlag {
    private let lock = NSLock()
    private var storedValue = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func set() {
        lock.lock()
        storedValue = true
        lock.unlock()
    }
}
