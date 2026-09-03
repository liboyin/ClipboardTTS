import XCTest
@testable import ClipboardTTSApp

final class TerminalStateAssertionTests: MockURLProtocolTestCase {
    func testSuccessfulTerminalStateRequiresAnObservedActiveRequest() {
        // WHY: A manager is initially idle with no error, which has the same fields as a successful
        // terminal state. Accepting it would let a test pass even when its request never began.
        XCTAssertFalse(
            matchesExpectedTerminalState(
                error: nil,
                isStreaming: false,
                expectedError: nil,
                observedActiveRequest: false,
                isPostActionPublication: true
            )
        )
        XCTAssertTrue(
            matchesExpectedTerminalState(
                error: nil,
                isStreaming: false,
                expectedError: nil,
                observedActiveRequest: true,
                isPostActionPublication: true
            )
        )
    }

    func testTerminalStateRejectsAStateThatWasPublishedBeforeTheActionStarted() {
        // WHY: Combine replays the manager's current state when a test subscribes. An expected
        // failure that already matches would settle an assertion whose action never reached the
        // network, hiding a broken request path behind the previous attempt's error.
        let expectedFailure = "Speech request failed (HTTP 500)."
        XCTAssertFalse(
            matchesExpectedTerminalState(
                error: expectedFailure,
                isStreaming: false,
                expectedError: expectedFailure,
                observedActiveRequest: true,
                isPostActionPublication: false
            )
        )
        // A failure may be published synchronously without ever setting `isStreaming`, so the
        // post-action boundary must be the only additional requirement it has to satisfy.
        XCTAssertTrue(
            matchesExpectedTerminalState(
                error: expectedFailure,
                isStreaming: false,
                expectedError: expectedFailure,
                observedActiveRequest: false,
                isPostActionPublication: true
            )
        )
    }

    func testTerminalFailureAssertionCannotSettleFromAnEarlierRequestsMatchingError() {
        // WHY: Combine replays `lastError` when a terminal-state assertion subscribes. If a stale
        // failure could settle it, a test would report a verified failure path while its action
        // started no request at all, so a regression in that path would ship undetected.
        let manager = TestNetworkFactory.makeManager()
        let staleFailure = "TTS configuration is invalid. Check the API endpoint and try again."
        manager.updateSettings(
            baseURL: "not a valid endpoint",
            apiKey: "fake-key",
            model: "test",
            voice: "test",
            selectedProvider: "OpenAI"
        )
        manager.streamTTS(text: "Earlier failing attempt") { _ in }
        XCTAssertEqual(manager.lastError, staleFailure)

        // A bounded wait is the only way to observe that nothing settles. The helper itself stays
        // event-driven; only this negative assertion needs a deadline to prove the absence.
        let didSettle = awaitTerminalState(of: manager, expectedError: staleFailure, timeout: 0.2) {}

        XCTAssertFalse(didSettle, "A pre-action failure must not satisfy an assertion for a new request.")
        XCTAssertEqual(manager.lastError, staleFailure)
        XCTAssertFalse(manager.isStreaming)
    }

    func testTerminalFailureAssertionCannotSettleFromAnEarlierRequestsQueuedPublication() {
        // WHY: An off-main caller publishes through `DispatchQueue.main.async`, so an earlier
        // request's state can still be queued when an assertion starts. Accepting it because it
        // merely lands after the action would let another request's outcome verify this one.
        let manager = TestNetworkFactory.makeManager()
        let staleFailure = "TTS configuration is invalid. Check the API endpoint and try again."
        manager.updateSettings(
            baseURL: "not a valid endpoint",
            apiKey: "fake-key",
            model: "test",
            voice: "test",
            selectedProvider: "OpenAI"
        )
        manager.streamTTS(text: "Earlier failing attempt") { _ in }
        XCTAssertEqual(manager.lastError, staleFailure)

        let republished = expectation(description: "The earlier request queues its state again")
        DispatchQueue.global(qos: .userInitiated).async {
            manager.publishFailure(staleFailure, requestGeneration: 1)
            republished.fulfill()
        }
        wait(for: [republished], timeout: 1.0)

        let didSettle = awaitTerminalState(of: manager, expectedError: staleFailure, timeout: 0.2) {}

        XCTAssertFalse(didSettle, "A publication queued before the action must not satisfy the assertion.")
        XCTAssertEqual(manager.lastError, staleFailure)
        XCTAssertFalse(manager.isStreaming)
    }

    func testTerminalStateAssertionRejectsAnOffMainCallSite() {
        // WHY: The helper writes its observation flags on the caller's thread and reads them in a
        // sink Combine delivers on the main queue. Only a main-thread caller orders those accesses,
        // so an off-main call site must fail loudly. Racing instead would let the helper settle on
        // whichever value it happened to read and report that as a verified terminal state.
        // Match only the guard's own failure. An unfiltered expectation accepts any later issue
        // from any thread, so an unrelated flake would satisfy it and this test would pass without
        // the guard ever firing. The closure-scoped form cannot replace this: the failure is
        // recorded on a background queue, which that form does not match.
        let guardFailureOnly = XCTExpectedFailure.Options()
        guardFailureOnly.issueMatcher = { issue in
            issue.compactDescription.contains("awaitTerminalState must be called from the main thread")
        }
        XCTExpectFailure("An off-main call site must be reported as a failure, not raced.", options: guardFailureOnly)
        let manager = TestNetworkFactory.makeManager()
        var didSettle = true

        // The call needs its own queue: a `sync` hop can keep running on this thread and would
        // satisfy the guard it is meant to trip. `wait(for:)` keeps pumping the main queue, so
        // removing the guard lets the helper reach its drain and return a quiet, failure-free
        // `false` instead of stalling. That is what makes the expected failure detect the mutant.
        let offMainCallSite = DispatchQueue(label: "com.clipboardtts.tests.off-main-call-site")
        let finished = expectation(description: "The off-main call returned")
        offMainCallSite.async { [self] in
            didSettle = awaitTerminalState(of: manager, expectedError: nil, timeout: 0.2) {}
            finished.fulfill()
        }
        wait(for: [finished], timeout: 1.0)
        // Quiescence, not merely fulfilment. The queue is serial, so this returns only after the
        // block above has exited, and it runs even when the wait expires. Without it an expired
        // wait would leave the call free to record its failure after this test's expected-failure
        // window closed, and to write `didSettle` while the assertion below reads it.
        offMainCallSite.sync {}

        XCTAssertFalse(didSettle, "A rejected call site must not report a terminal state.")
    }

    func testTerminalFailureAssertionAcceptsASynchronousFailurePublishedByItsAction() {
        // WHY: Request-body encoding fails before the manager ever sets `isStreaming`. The
        // post-action boundary must not force such tests off the shared helper, or synchronous
        // failure paths would regress to untimed direct state reads with no observation contract.
        let manager = TestNetworkFactory.makeManager { _ in
            throw TerminalStateAssertionEncodingError.failed
        }
        manager.updateSettings(baseURL: "https://mock.api/v1/audio/speech", apiKey: "fake-key", model: "test", voice: "test", selectedProvider: "OpenAI")

        assertTerminalState(
            of: manager,
            expectedError: "Couldn't prepare the speech request. Check the settings and try again."
        ) {
            manager.streamTTS(text: "Synchronous encoding failure") { _ in
                XCTFail("An unencoded request must not produce audio.")
            }
        }

        XCTAssertFalse(manager.isStreaming)
    }
}

private enum TerminalStateAssertionEncodingError: Error {
    case failed
}
