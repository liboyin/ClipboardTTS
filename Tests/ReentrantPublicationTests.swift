import XCTest
import Combine
@testable import ClipboardTTSApp

/// `@Published` notifies observers before it stores a value, so an observer that stops or replaces
/// a request during a request-state publication runs while the outer value is still unstored. D14:
/// that observer's own publications take effect once the outer one finishes, in order, before it
/// returns. Every assertion here runs without draining the main queue, because state that is only
/// correct a turn later is what main-queue work queued in between would read.
final class ReentrantPublicationTests: MockURLProtocolTestCase {
    private struct PublishedState: Equatable {
        let isStreaming: Bool
        let lastError: String?
    }

    func testStopFromAStreamingObserverLeavesTheRequestStoppedWhenTheStartReturns() {
        // WHY: Before D14 the stop's `isStreaming = false` landed inside the outer `true`, which was
        // then stored over it, leaving the menu reporting a request that no longer exists.
        let manager = TestNetworkFactory.makeManager()
        manager.updateSettings(baseURL: "https://mock.api/v1/audio/speech", apiKey: "fake-key",
                               model: "test", voice: "test", selectedProvider: "OpenAI")
        let releaseResponse = DispatchSemaphore(value: 0)
        MockURLProtocol.installRequestHandler { request in
            _ = releaseResponse.wait(timeout: .now() + 1.0)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { releaseResponse.signal() }

        var storedStateAtEachWillChange: [PublishedState] = []
        var revocationWasSynchronous = false
        var didStop = false
        let willChange = manager.objectWillChange.sink {
            storedStateAtEachWillChange.append(PublishedState(isStreaming: manager.isStreaming, lastError: manager.lastError))
        }
        let streaming = manager.$isStreaming.dropFirst().sink { isStreaming in
            guard isStreaming, !didStop else { return }
            didStop = true
            manager.stopStreaming()
            revocationWasSynchronous = manager.activeTaskForTesting == nil
        }
        defer {
            willChange.cancel()
            streaming.cancel()
        }

        manager.streamTTS(text: "Stopped while its start is published") { _ in }

        XCTAssertTrue(didStop)
        XCTAssertTrue(revocationWasSynchronous, "The stop must still revoke the request before the observer returns.")
        XCTAssertNil(manager.activeTaskForTesting)
        XCTAssertFalse(manager.isStreaming)
        XCTAssertNil(manager.lastError)
        // The start's clear and `true`, then the stop's clear and `false`, which must be announced
        // only after the start's `true` has been stored rather than inside it.
        XCTAssertEqual(storedStateAtEachWillChange, [
            PublishedState(isStreaming: false, lastError: nil),
            PublishedState(isStreaming: false, lastError: nil),
            PublishedState(isStreaming: true, lastError: nil),
            PublishedState(isStreaming: true, lastError: nil)
        ])
    }

    func testStopFromAFailureObserverLeavesNoFailureWhenThePublicationReturns() {
        // WHY: Stop clears the menu's failure. Applied inside the failure's own publication, that
        // clear was overwritten by the failure it was meant to dismiss.
        let failure = "TTS configuration is invalid. Check the API endpoint and try again."
        let manager = TestNetworkFactory.makeManager()
        manager.updateSettings(baseURL: "not a valid endpoint", apiKey: "fake-key",
                               model: "test", voice: "test", selectedProvider: "OpenAI")
        var storedErrorWhenClearIsAnnounced: [String?] = []
        var didStop = false
        let errors = manager.$lastError.dropFirst().sink { error in
            if didStop {
                storedErrorWhenClearIsAnnounced.append(manager.lastError)
                XCTAssertNil(error)
                return
            }
            guard error == failure else { return }
            didStop = true
            manager.stopStreaming()
        }
        defer { errors.cancel() }

        manager.streamTTS(text: "Stopped while its failure is published") { _ in }

        XCTAssertTrue(didStop)
        XCTAssertNil(manager.lastError)
        XCTAssertFalse(manager.isStreaming)
        XCTAssertEqual(storedErrorWhenClearIsAnnounced, [failure])
    }

    func testPublicationsRequestedDuringAPublicationApplyInTheOrderTheyWereRequested() {
        // WHY: The observer's last request is its intent. Applying the queue out of order would let
        // an earlier failure replace the clear that followed it.
        let manager = TestNetworkFactory.makeManager()
        var didRespond = false
        let errors = manager.$lastError.dropFirst().sink { error in
            guard error == "Outer failure", !didRespond else { return }
            didRespond = true
            manager.publishFailure("Failure the observer then clears")
            manager.clearLastError()
        }
        defer { errors.cancel() }

        manager.publishFailure("Outer failure")

        XCTAssertTrue(didRespond)
        XCTAssertNil(manager.lastError)
        XCTAssertFalse(manager.isStreaming)
    }

    func testAQueuedFailureThatAStopRevokedIsNeverAnnounced() {
        // WHY: The failure was current when the observer requested it, but the stop that followed
        // retired its request. Judged when it applies, it belongs to no request and must not flash
        // in the menu bar before the stop's clear.
        let manager = TestNetworkFactory.makeManager()
        var announcedAfterOuter: [String?] = []
        var didRespond = false
        let errors = manager.$lastError.dropFirst().sink { error in
            if didRespond {
                announcedAfterOuter.append(error)
                return
            }
            guard error == "Outer failure" else { return }
            didRespond = true
            manager.publishFailure("Revoked failure", requestGeneration: manager.currentRequestGeneration())
            manager.stopStreaming()
        }
        defer { errors.cancel() }

        manager.publishFailure("Outer failure")

        XCTAssertTrue(didRespond)
        XCTAssertEqual(announcedAfterOuter, [nil])
        XCTAssertNil(manager.lastError)
    }

    func testAQueuedPublicationJudgesTheStateItWillReplaceRatherThanTheStateWhenItWasRequested() {
        // WHY: While the outer value is unstored, the old message is still readable. Withdrawing the
        // startup read failure must compare against the failure that has replaced it by the time
        // the withdrawal applies, or it erases guidance the user still needs.
        let secretStore = ScriptedSecretStore()
        secretStore.failingProviders = [.custom]
        let manager = TestNetworkFactory.makeManager(
            secretStore: secretStore,
            defaults: makeOwnedDefaults([SettingsKeys.ttsProvider: "Custom"])
        )
        XCTAssertEqual(manager.lastError, APIKeyStartupState.readFailureMessage(for: .custom))
        var announcedAfterOuter: [String?] = []
        var didWithdraw = false
        let errors = manager.$lastError.dropFirst().sink { error in
            if didWithdraw {
                announcedAfterOuter.append(error)
                return
            }
            guard error == "Newer request failure" else { return }
            didWithdraw = true
            manager.withdrawKeyReadFailure(for: .custom)
        }
        defer { errors.cancel() }

        manager.publishFailure("Newer request failure")

        XCTAssertTrue(didWithdraw)
        XCTAssertEqual(manager.lastError, "Newer request failure")
        XCTAssertEqual(announcedAfterOuter, [], "A withdrawal that no longer applies must announce nothing.")
    }

    func testAMigrationWarningWithdrawnWhileItIsPublishedIsWithdrawnWhenThePublicationReturns() {
        // WHY: Settings republishes the warning for the provider still pending, and a retry can
        // secure it at once. Judged against the unstored old warning, the withdrawal matched
        // nothing and the new warning stayed on screen with no record left to withdraw it by.
        let defaults = makeOwnedDefaults([
            SettingsKeys.ttsProvider: "Custom",
            SettingsKeys.legacyCustomAPIKey: "test-legacy-custom-key"
        ])
        let store = InMemorySecretStore()
        store.nextError = .unavailable
        let manager = TestNetworkFactory.makeManager(secretStore: store, defaults: defaults)
        XCTAssertEqual(manager.lastError, APIKeyMigrationService.failureMessage(for: .custom))
        let openAIWarning = APIKeyMigrationService.failureMessage(for: .openAI)
        var didWithdraw = false
        let errors = manager.$lastError.dropFirst().sink { error in
            guard error == openAIWarning, !didWithdraw else { return }
            didWithdraw = true
            manager.updateMigrationFailureWarning(for: nil)
        }
        defer { errors.cancel() }

        manager.updateMigrationFailureWarning(for: .openAI)

        XCTAssertTrue(didWithdraw)
        XCTAssertNil(manager.lastError)
    }
}
