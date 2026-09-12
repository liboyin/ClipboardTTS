import AVFoundation
import Combine
import XCTest
@testable import ClipboardTTSApp

/// What may and may not interleave with a format change, at each point where the request it cancels
/// could end underneath it.
///
/// These are the windows the session owner's cancellation has to survive: a request ending before
/// the change, between deciding to revoke and revoking, while the audio graph is rebuilt, during the
/// handoff to a retry, and while a malformed stream is being torn down. Each is opened deliberately
/// through a seam rather than waited for, because a window reached by timing is a window some runs
/// will miss. Every test runs on the main actor, where the audio graph is confined.
@MainActor
final class SpeechSessionFormatChangeRaceTests: MockURLProtocolTestCase {

    func testAFormatChangeBetweenARequestEndingAndItsStopBeingPublishedClaimsNothing() {
        // WHY: A completed request releases its context on the delegate's thread and only then
        // queues the main-queue publication that says it stopped, so `isStreaming` is still true
        // for that gap. Deciding the pairing from the published flag would cancel a request that no
        // longer exists and advance the request generation for it — the token the menu's deferred
        // clipboard read drops its click on. The completion is driven off-main while this test's
        // own turn holds the main queue, which is what keeps that gap open across the assertion.
        let owned = makeOwnedSpeechSession()
        defer { finishSpeechSession(owned) }
        let releaseResponse = DispatchSemaphore(value: 0)
        let held = startHeldSpeechSession(owned, releasedBy: releaseResponse)
        defer { releaseResponse.signal() }
        defer { held.observation.cancel() }
        wait(for: [held.audioBuffered], timeout: 2.0)
        guard let task = owned.networkManager.activeTaskForTesting else {
            XCTFail("Expected the session to retain the task it started.")
            return
        }
        let completionReturned = DispatchSemaphore(value: 0)
        let networkManager = owned.networkManager
        DispatchQueue.global().async {
            networkManager.urlSession(networkManager.session, task: task, didCompleteWithError: nil)
            completionReturned.signal()
        }
        XCTAssertEqual(completionReturned.wait(timeout: .now() + 2.0), .success, "The completion must have been handled.")
        XCTAssertTrue(owned.networkManager.isStreaming, "The stop must still be queued behind this test's own turn.")
        let pipelineGeneration = owned.networkManager.currentRequestGeneration()

        XCTAssertEqual(owned.session.applyAudioFormat(sampleRate: 48_000), .updated)

        XCTAssertEqual(
            owned.networkManager.currentRequestGeneration(),
            pipelineGeneration,
            "A request that has already ended is not one the format change may cancel."
        )
    }
    func testAFormatChangeDecidesOwnershipAndRevokesInOneStep() {
        // WHY: The ownership decision and the revocation have to be one visit to the request state.
        // Split apart, a completion landing between them leaves the revocation advancing a
        // generation nothing owns any more — the token a menu click waiting out its deferred
        // clipboard read drops itself on. The authority every revocation crosses is where the
        // completion is forced, so the gap is opened deliberately rather than waited for.
        let authority = LockObservingCallbackAuthority()
        let owned = makeOwnedSpeechSession(callbackAuthority: authority)
        defer { finishSpeechSession(owned) }
        let releaseResponse = DispatchSemaphore(value: 0)
        let task = startHeldRequest(owned, releasedBy: releaseResponse)
        defer { releaseResponse.signal() }
        let pipelineGeneration = owned.networkManager.currentRequestGeneration()
        let networkManager = owned.networkManager
        authority.runOnNextAcquisition {
            // The request ends here: after any check the caller made, and before it revokes.
            let completed = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                networkManager.urlSession(networkManager.session, task: task, didCompleteWithError: nil)
                completed.signal()
            }
            XCTAssertEqual(completed.wait(timeout: .now() + 2.0), .success, "The forced completion must have been handled.")
        }

        XCTAssertEqual(owned.session.applyAudioFormat(sampleRate: 48_000), .updated)

        XCTAssertEqual(
            owned.networkManager.currentRequestGeneration(),
            pipelineGeneration,
            "A request that ended on the way into the revocation is not one the format change may claim."
        )
    }

    func testNothingReachesTheRequestStateBetweenDecidingToRevokeAndRevoking() {
        // WHY: The ownership decision and the revocation have to be one request-state transaction.
        // Read in one visit and revoked in a second, a completion landing in between leaves the
        // revocation advancing a generation nothing owns any more — the token a menu click waiting
        // out its deferred clipboard read drops itself on. A completion reaches that state through
        // the request-state queue without taking callback authority, so holding authority is not
        // what stops it; being inside the transaction is. This states that in the queue's own terms
        // rather than in elapsed time: work submitted to it from the decision point runs after the
        // transaction that submitted it, so it finds the revocation already applied. Split into two
        // visits, the same work runs between them and sees the request still owning a generation
        // that is about to be advanced regardless.
        let observed = LockedValue<(ownsPipeline: Bool, generation: UInt64)?>(nil)
        let stateReadAfterDecision = expectation(description: "Request state is read after the decision point")
        // The observer needs the manager it observes, so it reads its action from a box the test
        // fills once that manager exists.
        let readRequestState = LockedValue<(@Sendable () -> Void)?>(nil)
        let owned = makeOwnedSpeechSession(revocationTransactionObserver: { readRequestState.withValue { $0 }?() })
        defer { finishSpeechSession(owned) }
        let networkManager = owned.networkManager
        readRequestState.withValue {
            $0 = {
                networkManager.stateQueue.async {
                    observed.withValue {
                        $0 = (ownsPipeline: networkManager.activeRequest != nil,
                              generation: networkManager.requestGeneration)
                    }
                    stateReadAfterDecision.fulfill()
                }
            }
        }
        let releaseResponse = DispatchSemaphore(value: 0)
        _ = startHeldRequest(owned, releasedBy: releaseResponse)
        defer { releaseResponse.signal() }
        let pipelineGeneration = owned.networkManager.currentRequestGeneration()

        XCTAssertEqual(owned.session.applyAudioFormat(sampleRate: 48_000), .updated)

        wait(for: [stateReadAfterDecision], timeout: 2.0)
        XCTAssertEqual(
            observed.withValue({ $0 })?.ownsPipeline,
            false,
            "The revocation must have released the request before anything else reaches the request state."
        )
        XCTAssertEqual(
            observed.withValue({ $0 })?.generation,
            pipelineGeneration &+ 1,
            "The revocation must have advanced the generation before anything else reaches the request state."
        )
    }

    func testAFormatChangeInsideTheRetryHandoffStopsTheRetryFromStarting() {
        // WHY: A completion that earned a retry has ended the attempt it describes and the retry has
        // not begun, so this window is the one place the pipeline could look unowned while a request
        // is about to resume on it. Releasing ownership there leaves a format change with nothing to
        // cancel; the retry then passes its unchanged-generation guard and streams into the session
        // the change retired, which is NB9 again. The change is forced from inside that window, so
        // the interleaving is stated rather than waited for.
        let applyFormatChange = LockedValue<(@Sendable () -> Void)?>(nil)
        let owned = makeOwnedSpeechSession(retryInstallationObserver: { applyFormatChange.withValue { $0 }?() })
        defer { finishSpeechSession(owned) }
        configureGeminiProvider(owned.networkManager)
        let attempts = RequestAttemptLog()
        let formatChanged = expectation(description: "The format changes inside the retry handoff")
        let session = owned.session
        // The observer runs on the session's delegate queue while the audio graph is main-confined,
        // so the change is built here and run only on the main queue.
        let changeFormat = MainQueueSessionAction {
            XCTAssertEqual(session.applyAudioFormat(sampleRate: 48_000), .updated)
            formatChanged.fulfill()
        }
        applyFormatChange.withValue {
            $0 = { DispatchQueue.main.sync { changeFormat.run() } }
        }
        MockURLProtocol.installRequestHandler { request in
            attempts.record(request)
            return (mockHTTPResponse(for: request, statusCode: 500), Data("{\"error\":{}}".utf8))
        }
        let pipelineGeneration = owned.networkManager.currentRequestGeneration()

        owned.session.start(text: "Transient Gemini failure")

        wait(for: [formatChanged], timeout: 2.0)
        drainSpeechDelivery(of: owned.networkManager)
        drainSpeechMainQueueTurn()
        XCTAssertEqual(attempts.count, 1, "The retry must not reach the provider once its session is retired.")
        XCTAssertNil(owned.networkManager.activeTaskForTesting, "A refused retry must leave no request behind.")
        XCTAssertEqual(
            owned.networkManager.currentRequestGeneration(),
            pipelineGeneration &+ 2,
            "The request the session started and the format change that cancelled it each advance the generation once."
        )
    }

    func testAFormatChangeCancelsItsRequestBeforeRebuildingTheGraph() {
        // WHY: Rebuilding the audio graph is not instant, and a request completing while it happens
        // would, if the cancellation came afterwards, find its generation still current and publish
        // the failure of the very session the format change retired. Cancelling first is what makes
        // that completion stale. The completion is forced from the engine start the rebuild
        // performs, so it lands inside the rebuild rather than near it.
        let forceCompletion = LockedValue<(@Sendable () -> Void)?>(nil)
        let owned = makeOwnedSpeechSession(engineStarter: { engine in
            try engine.start()
            forceCompletion.withValue { $0 }?()
        })
        defer { finishSpeechSession(owned) }
        let releaseResponse = DispatchSemaphore(value: 0)
        let task = startHeldRequest(owned, releasedBy: releaseResponse)
        defer { releaseResponse.signal() }
        let networkManager = owned.networkManager
        let completionHandled = expectation(description: "The request fails while the graph is rebuilt")
        forceCompletion.withValue {
            $0 = {
                let completed = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    networkManager.urlSession(
                        networkManager.session,
                        task: task,
                        didCompleteWithError: URLError(.networkConnectionLost)
                    )
                    completed.signal()
                    completionHandled.fulfill()
                }
                XCTAssertEqual(completed.wait(timeout: .now() + 2.0), .success, "The forced completion must be handled.")
            }
        }

        XCTAssertEqual(owned.session.applyAudioFormat(sampleRate: 48_000), .updated)

        wait(for: [completionHandled], timeout: 2.0)
        drainSpeechMainQueueTurn()
        XCTAssertNil(
            owned.networkManager.lastError,
            "A session the format change retired must not publish the failure of the request it cancelled."
        )
        XCTAssertFalse(owned.networkManager.isStreaming)
    }

    func testAFormatChangeLeavesAMalformedStreamToPublishItsOwnFailure() {
        // WHY: A fatally malformed Gemini stream advances its generation first and leaves its
        // context in place until the revocation waiting at callback authority collects it. That
        // request is already revoked and is about to publish the failure the user must see, so a
        // format change arriving in that window must not mistake the retained context for an owner:
        // cancelling it would advance a generation nothing owns and swallow the message.
        let authority = LockObservingCallbackAuthority()
        let owned = makeOwnedSpeechSession(callbackAuthority: authority)
        defer { finishSpeechSession(owned) }
        configureGeminiProvider(owned.networkManager)
        let releaseResponse = DispatchSemaphore(value: 0)
        let task = startHeldRequest(owned, releasedBy: releaseResponse)
        defer { releaseResponse.signal() }
        let networkManager = owned.networkManager
        let reachedRevocation = DispatchSemaphore(value: 0)
        let formatChanged = DispatchSemaphore(value: 0)
        authority.runOnNextAcquisition {
            reachedRevocation.signal()
            XCTAssertEqual(formatChanged.wait(timeout: .now() + 2.0), .success, "The format change must have completed.")
        }
        DispatchQueue.global().async {
            networkManager.urlSession(
                networkManager.session,
                dataTask: task,
                didReceive: Data("data: not-json\n\n".utf8)
            )
        }
        XCTAssertEqual(reachedRevocation.wait(timeout: .now() + 2.0), .success, "The malformed stream must reach its revocation.")
        let revokedGeneration = owned.networkManager.currentRequestGeneration()

        XCTAssertEqual(owned.session.applyAudioFormat(sampleRate: 48_000), .updated)
        formatChanged.signal()

        XCTAssertEqual(
            owned.networkManager.currentRequestGeneration(),
            revokedGeneration,
            "A context its own generation has already outlived is not one the format change may claim."
        )
        drainSpeechDelivery(of: owned.networkManager)
        drainSpeechMainQueueTurn()
        XCTAssertEqual(
            owned.networkManager.lastError,
            "The TTS service returned no playable audio. Please try again.",
            "The malformed stream must still reach the user with its own failure."
        )
    }
}
