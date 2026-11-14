import XCTest
@testable import ClipboardTTSApp

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

    func testFactoryManagerSessionIsRegisteredForTeardownToInvalidate() {
        // WHY: Teardown invalidates only the sessions registered with the scope, and its
        // quiescence check waits for each of those to report invalidation. An unregistered session
        // is never invalidated, outlives its test holding its delegate, and quiescence still passes.
        // Each factory path gets its own test, so no other registration can answer for this one.
        let manager = TestNetworkFactory.makeManager()
        XCTAssertTrue(
            MockURLProtocol.isRegisteredWithCurrentTest(manager.session),
            "A factory manager's session must be registered for teardown to invalidate."
        )
    }

    func testFactorySessionIsRegisteredForTeardownToInvalidate() {
        // WHY: As for a factory manager's session: teardown invalidates only what the scope registered.
        XCTAssertTrue(
            MockURLProtocol.isRegisteredWithCurrentTest(TestNetworkFactory.makeSession()),
            "A factory session must be registered for teardown to invalidate."
        )
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

    func testTearDownInvalidatesSessionsBeforeADeferredTaskCanStartLoading() {
        // WHY: A task the test created but never resumed can still be resumed after teardown, by
        // work the test no longer controls, and would then load inside whichever test runs next.
        // Invalidating the session cancels even a task that never started, and URLSession reports
        // that cancellation before the invalidation teardown waits for, so by quiescence the task has
        // already completed as cancelled and a later resume leaves it completed instead of loading it.
        // If teardown left the task alive, the test cancels it through its own session and waits for
        // that completion instead of resuming it, so a failure leaves no load behind either.
        let completionErrors = LockedValue<[URLError.Code?]>([])
        let completed = DispatchSemaphore(value: 0)
        let session = TestNetworkFactory.makeSession()
        let task = session.dataTask(with: URL(string: "https://mock.api/deferred-task")!) { _, _, error in
            completionErrors.withValue { $0.append((error as? URLError)?.code) }
            completed.signal()
        }

        assertAfterMockQuiescence {
            guard completionErrors.value == [.cancelled] else {
                XCTFail("Teardown must cancel a task it has not resumed before it releases the test scope.")
                session.invalidateAndCancel()
                // A leftover task that never completes cannot be contained, so the run ends here.
                guard completed.wait(timeout: .now() + 2.0) == .success else {
                    fatalError("A task teardown left alive did not complete after its session was cancelled.")
                }
                return
            }
            task.resume()
            XCTAssertEqual(task.state, .completed, "A task resumed after teardown must not start loading.")
        }
    }
}

/// Opens and closes a mock scope itself, running the close `MockURLProtocolTestCase.tearDown` runs,
/// so a test can watch that close refuse to finish.
///
/// The ordinary lifecycle only lets a test observe a teardown that succeeded, which cannot show
/// that the teardown waited for anything.
final class MockURLProtocolInFlightLoadTests: XCTestCase {
    func testTearDownWaitsForAnInFlightHandlerBeforeReleasingTheTestScope() {
        // WHY: URLSession finishes invalidating a session while one of its protocol loads is still
        // running a handler, so only the scope's own load accounting stops teardown from releasing
        // the scope, and with it the next test, while that handler can still record into it.
        // Teardown has no event saying it is waiting, so the handler is released only after the
        // close has given up: one that did not wait would already have quiesced and released its
        // delivery owner while the handler was still running. Correct code reports a non-quiescent
        // close whatever the deadline, which only bounds how long a broken one gets to quiesce.
        MockURLProtocolTestCase.testExecutionLock.lock()
        let acquiredTestExecutionGate = MockURLProtocolTestCase.enterTestExecutionGate()
        let releaseHandler = DispatchSemaphore(value: 0)
        var openTestIdentifier: String?
        defer {
            releaseHandler.signal()
            if let openTestIdentifier {
                MockURLProtocolTestCase.finishClosingScopeOrEndRun(identifier: openTestIdentifier)
            }
            if acquiredTestExecutionGate {
                MockURLProtocolTestCase.leaveTestExecutionGate()
            }
            MockURLProtocolTestCase.testExecutionLock.unlock()
        }

        let testIdentifier = MockURLProtocol.beginTest()
        openTestIdentifier = testIdentifier
        let handlerFinished = LockedValue(false)
        // The scope releases its delivery owners only once it has decided its loads are drained, so
        // the release records whether the handler had returned when that decision was made.
        let handlerFinishedAtRelease = LockedValue<[Bool]>([])
        MockURLProtocol.register(
            audioDeliveryQueue: DispatchQueue(label: "com.clipboardtts.tests.in-flight-load"),
            releasePendingDelivery: {
                handlerFinishedAtRelease.withValue { $0.append(handlerFinished.value) }
            },
            finishRevocation: {},
            forTestIdentifier: testIdentifier
        )
        let requestStarted = expectation(description: "Mock request started")
        MockURLProtocol.installRequestHandler { request in
            requestStarted.fulfill()
            _ = releaseHandler.wait(timeout: .now() + 2.0)
            handlerFinished.withValue { $0 = true }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        TestNetworkFactory.makeSession().dataTask(
            with: URL(string: "https://mock.api/in-flight-handler")!
        ).resume()
        wait(for: [requestStarted], timeout: 1.0)

        guard !MockURLProtocol.endTest(identifier: testIdentifier, timeout: 0.2).didQuiesce else {
            // The scope is gone while its handler still runs, so nothing can own what that load does
            // next. As for any scope that cannot be contained, the run ends rather than hand it on.
            fatalError("Teardown released a test scope while one of its handlers was still running.")
        }
        XCTAssertEqual(handlerFinishedAtRelease.value, [], "A scope must not release its owners while a load is in flight.")

        releaseHandler.signal()
        MockURLProtocolTestCase.finishClosingScopeOrEndRun(identifier: testIdentifier)
        openTestIdentifier = nil
        XCTAssertEqual(
            handlerFinishedAtRelease.value,
            [true],
            "A scope must release its owners only after its in-flight handler has returned."
        )
    }
}
