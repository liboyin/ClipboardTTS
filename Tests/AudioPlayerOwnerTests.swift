import Foundation
import XCTest
@testable import ClipboardTTSApp

/// Proves `AudioPlayerOwner` ends every test player's lifecycle: work in flight at teardown finishes
/// inside it, a held automatic start never runs, and work arriving afterwards is counted and
/// reaches nothing of the test's.
///
/// Most tests run the owner's teardown themselves so they can inspect what follows it; the teardown
/// XCTest runs afterwards then finds it already done. Every wait bounds an event, and a wait a test
/// lets expire on purpose is scoped by `XCTExpectFailure` with an issue matcher.
@MainActor
final class AudioPlayerOwnerTests: XCTestCase {
    /// Bounds a wait for an event that must happen, so a broken owner fails the test, not the run.
    private static let safetyBound: DispatchTimeInterval = .seconds(10)
    /// How long a packet held on the audio queue gives teardown to return, which it must not do.
    /// A correct teardown is blocked in its barrier throughout, so it passes however short this is.
    private static let wrongReturnWindow: DispatchTimeInterval = .seconds(1)
    /// The assertion wait these tests let expire.
    private static let expiringWait: TimeInterval = 0.2

    func testAnOpenOwnerForwardsEveryObservationToTheTest() {
        // WHY: The owner sits between the player and every observer a test awaits. Closing early or
        // swallowing a call would leave each suite waiting on an event that already happened.
        let reached = LockedValue(Observations())
        let published = expectation(description: "The packet's state is published")
        let owned = makeAudioPlayerOwner(
            scheduledBufferObserver: { _ in reached.withValue { $0.scheduledBuffers += 1 } },
            audioDataProcessingObserver: { reached.withValue { $0.processing += 1 } },
            audioStateObserver: {
                reached.withValue { $0.publications += 1 }
                published.fulfill()
            }
        )
        let generation = owned.player.startNewStream()

        owned.player.scheduleAudio(data: Data(repeating: 0, count: 2), streamGeneration: generation)

        wait(for: [published], timeout: 2.0)
        XCTAssertEqual(reached.value, Observations(scheduledBuffers: 1, processing: 1, publications: 1))
        XCTAssertTrue(owned.player.hasAudio)
        XCTAssertFalse(owned.owner.isClosed)
        XCTAssertEqual(owned.owner.ledger, AudioPlayerOwner.Ledger())
    }

    func testTheOwnersDefaultsKeepTheAutomaticStartAndProgressTimerInTheTest() {
        // WHY: A suite that injects nothing must still own every deferred action. Production's
        // scheduler would start a real engine 0.1 second after the test stopped waiting, and its
        // run-loop timer would tick the progress of a player no test is reading any more.
        let publications = AudioStateUpdateRecorder()
        let owned = makeAudioPlayerOwner(audioStateObserver: publications.record)
        let held = owned.owner.heldAutomaticStarts
        bufferStream(in: owned.player, publications: publications)

        drainMainQueue()
        XCTAssertEqual(held.scheduledDelays, [0.1], "The prebuffer start must be held, not run on a deadline.")
        XCTAssertFalse(owned.player.isPlaying)

        held.runNextAction()
        drainMainQueue()
        XCTAssertTrue(owned.player.isPlaying, "The held action must be the player's own start.")
        XCTAssertTrue(owned.owner.progressTimer.isRunning, "The progress timer must be held by the owner.")

        bufferStream(in: owned.player, publications: publications)
        XCTAssertEqual(held.scheduledActionCount, 1, "Precondition: the next stream's start is held.")
        owned.owner.tearDown()

        XCTAssertEqual(held.scheduledActionCount, 0, "Teardown must release every start it held.")
        XCTAssertFalse(owned.owner.progressTimer.isRunning, "Teardown must stop the progress timer.")
        XCTAssertEqual(owned.owner.automaticStartsRun, 1)
        XCTAssertEqual(owned.owner.ledger, AudioPlayerOwner.Ledger(droppedAutomaticStarts: 1))
    }

    func testAnAutomaticStartHeldAtTeardownNeverRuns() {
        // WHY: A held start that outlives its test would run whenever its holder next runs one.
        // The test's own scheduler still holds the stand-in here and runs it after teardown, which
        // is the latest a forgotten action could be released.
        let scheduler = ManualAutomaticPlaybackScheduler()
        let publications = AudioStateUpdateRecorder()
        let owned = makeAudioPlayerOwner(automaticPlaybackScheduler: scheduler.schedule,
                                         audioStateObserver: publications.record)
        bufferStream(in: owned.player, publications: publications)
        XCTAssertEqual(scheduler.scheduledActionCount, 1, "Precondition: the stream's start is held.")

        owned.owner.tearDown()
        scheduler.runNextAction()
        drainMainQueue()

        XCTAssertEqual(owned.owner.automaticStartsRun, 0, "A start held at teardown must never reach the player.")
        XCTAssertEqual(owned.owner.ledger,
                       AudioPlayerOwner.Ledger(droppedAutomaticStarts: 1, refusedAutomaticStarts: 1))
        XCTAssertFalse(owned.player.isPlaying)
    }

    func testTeardownFinishesAudioWorkInFlightAndReleasesThePlayer() {
        // WHY: Work still running on the audio queue at teardown queues main-queue publications
        // when it finishes, and each holds the player until it runs. Teardown must wait that work
        // out and then run what it queued; a player still held once teardown returns means some of
        // its work can still run in a later test. The packet here is held on the audio queue until
        // teardown has returned, or the window has passed, so a teardown without the barrier
        // returns while it is held, and one that drains the main queue too early, or never, leaves
        // the packet's publication holding the player.
        let window = Self.wrongReturnWindow
        let probe = HeldPacketProbe()
        weak var releasedPlayer: AudioPlayerManager?
        var heldAtReturn = true
        do {
            let owned = makeAudioPlayerOwner(scheduledBufferObserver: { _ in
                probe.hold(until: window)
            })
            releasedPlayer = owned.player
            let generation = owned.player.startNewStream()
            owned.player.scheduleAudio(data: Data(repeating: 0, count: 2), streamGeneration: generation)
            XCTAssertEqual(probe.entered.wait(timeout: .now() + Self.safetyBound), .success,
                           "Precondition: the packet is held on the audio queue.")

            owned.owner.tearDown()
            heldAtReturn = probe.isHeld
            probe.teardownReturned.signal()
        }

        XCTAssertFalse(heldAtReturn, "Teardown must not return while the audio queue is still processing a packet.")
        XCTAssertNil(releasedPlayer, "Once teardown returns, no queued audio work may still hold the player.")
        // A broken teardown leaves that work behind; finish it here so it cannot run in a later test.
        if let survivor = releasedPlayer {
            _ = survivor.changesAudioFormat(to: AudioPlayerManager.defaultSampleRate)
            drainMainQueue()
        }
    }

    func testTeardownWaitsOutAnObservationForwardedJustBeforeItClosed() {
        // WHY: A packet can reach the audio queue while teardown is draining the main queue, after
        // its barrier and before it closes. Its processing is then forwarded to the test, and it
        // may still be running on the audio queue when the owner closes; teardown must not return
        // until it has finished, or the test's observer runs after its test has ended. A main-queue
        // block queued before teardown delivers that packet from inside the drain, and holds the
        // drain until the forwarded observation has begun, so the owner is still open when it does.
        let window = Self.wrongReturnWindow
        let safetyBound = Self.safetyBound
        let probe = HeldPacketProbe()
        let reached = LockedValue(Observations())
        let owned = makeAudioPlayerOwner(audioDataProcessingObserver: {
            reached.withValue { $0.processing += 1 }
            probe.hold(until: window)
        })
        let player = owned.player
        let retiredGeneration = player.startNewStream()
        DispatchQueue.main.async {
            player.scheduleAudio(data: Data(repeating: 0, count: 2), streamGeneration: retiredGeneration)
            _ = probe.entered.wait(timeout: .now() + safetyBound)
        }

        owned.owner.tearDown()
        let heldAtReturn = probe.isHeld
        probe.teardownReturned.signal()
        // A broken teardown leaves that observation running, or the packet unsent; finish both here.
        drainMainQueue()
        _ = player.changesAudioFormat(to: AudioPlayerManager.defaultSampleRate)

        XCTAssertEqual(reached.value, Observations(processing: 1),
                       "Precondition: the packet arrived while the owner was still open.")
        XCTAssertFalse(heldAtReturn, "Teardown must not return while an observation it forwarded is still running.")
        XCTAssertEqual(owned.owner.ledger, AudioPlayerOwner.Ledger())
    }

    func testWorkArrivingAfterTeardownIsCountedAndReachesNothingOfTheTests() {
        // WHY: A delivery that misses its test's wait can still arrive after that test's teardown,
        // because the network scope is closed only afterwards. Its processing and publication must
        // be counted where they land, not handed to observers that belong to a finished test: one
        // fulfilling an expectation whose wait has expired records an issue, and one writing a
        // recorder writes state its test has stopped reading. A test-owned queue stands in for the
        // late network delivery, and the session is started after teardown so the packet is
        // current and publishes.
        let reached = LockedValue(Observations())
        let processed = expectation(description: "A late packet is processed")
        let owned = makeAudioPlayerOwner(
            scheduledBufferObserver: { _ in reached.withValue { $0.scheduledBuffers += 1 } },
            audioDataProcessingObserver: {
                reached.withValue { $0.processing += 1 }
                processed.fulfill()
            },
            audioStateObserver: { reached.withValue { $0.publications += 1 } }
        )
        let player = owned.player
        expectOnlyTimeout(of: "A late packet is processed") {
            wait(for: [processed], timeout: Self.expiringWait)
        }

        owned.owner.tearDown()
        let lateGeneration = player.startNewStream()
        let delivery = DispatchQueue(label: "com.clipboardtts.tests.audioplayerowner.latedelivery")
        delivery.async {
            player.scheduleAudio(data: Data(repeating: 0, count: 2), streamGeneration: lateGeneration)
        }
        delivery.sync {}
        // The packet is on the audio queue; a barrier there finishes it, and one main-queue turn
        // then applies the publication it queued.
        _ = player.changesAudioFormat(to: AudioPlayerManager.defaultSampleRate)
        drainMainQueue()

        XCTAssertTrue(player.hasAudio, "Precondition: the late packet was current, so it published.")
        XCTAssertEqual(reached.value, Observations(), "Nothing arriving after teardown may reach the test's observers.")
        XCTAssertEqual(owned.owner.ledger, AudioPlayerOwner.Ledger(
            refusedAutomaticStarts: 1,
            lateScheduledBuffers: 1,
            lateProcessing: 1,
            latePublications: 1
        ))
    }

    func testTeardownRunsAfterTheTestFails() throws {
        // WHY: The teardown is what makes a failed test safe to follow. A test that times out and
        // exits early by throwing never reaches a cleanup written at its end, so the owner must be
        // torn down by XCTest. The check is a teardown block registered before the player's, which
        // XCTest runs after it.
        let observedOwner = LockedValue<AudioPlayerOwner?>(nil)
        addTeardownBlock {
            guard let owner = observedOwner.value else {
                XCTFail("The test never built its player.")
                return
            }
            XCTAssertTrue(owner.isClosed, "The owner's teardown must run however its test ended.")
            XCTAssertEqual(owner.ledger, AudioPlayerOwner.Ledger(droppedAutomaticStarts: 1))
        }
        let publications = AudioStateUpdateRecorder()
        let owned = makeAudioPlayerOwner(audioStateObserver: publications.record)
        observedOwner.withValue { $0 = owned.owner }
        bufferStream(in: owned.player, publications: publications)

        let neverHappens = expectation(description: "An event this test waits for in vain")
        expectOnlyTimeout(of: "An event this test waits for in vain") {
            wait(for: [neverHappens], timeout: Self.expiringWait)
        }
        let thrownOnly = XCTExpectedFailure.Options()
        thrownOnly.issueMatcher = { $0.type == .thrownError }
        XCTExpectFailure("The test ends by throwing, skipping the rest of its body.", options: thrownOnly)
        throw AbandonedTest.exitedEarly
    }

    /// Buffers one packet as a new stream and waits for its publication.
    private func bufferStream(in player: AudioPlayerManager,
                              publications: AudioStateUpdateRecorder,
                              file: StaticString = #filePath,
                              line: UInt = #line) {
        let published = publications.expectNextUpdate()
        let generation = player.startNewStream()
        player.scheduleAudio(data: Data(repeating: 0, count: 2), streamGeneration: generation)
        wait(for: [published], timeout: 2.0)
        XCTAssertTrue(player.hasAudio, "Precondition: the stream is buffered.", file: file, line: line)
    }

    /// Runs one main-queue turn, so a publication already queued lands before the assertions.
    private func drainMainQueue() {
        let drained = expectation(description: "The main queue completed a turn")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2.0)
    }

    /// Runs `body`, which must let the wait named `description` expire, and accepts only that.
    private func expectOnlyTimeout(of description: String, _ body: () -> Void) {
        let timeoutOnly = XCTExpectedFailure.Options()
        timeoutOnly.issueMatcher = { issue in
            issue.compactDescription.contains("Exceeded timeout") && issue.compactDescription.contains(description)
        }
        XCTExpectFailure("The test lets this wait expire on purpose.", options: timeoutOnly, failingBlock: body)
    }
}

/// What one test's own observers were handed by its player.
private struct Observations: Equatable, Sendable {
    var scheduledBuffers = 0
    var processing = 0
    var publications = 0
}

private enum AbandonedTest: Error {
    case exitedEarly
}

/// Holds one packet on the player's audio queue, inside its scheduled-buffer observer, until the
/// test reports that teardown returned or the window passes.
private final class HeldPacketProbe: Sendable {
    /// Signalled once the packet is held on the audio queue.
    let entered = DispatchSemaphore(value: 0)
    /// Signalled by the test once teardown has returned.
    let teardownReturned = DispatchSemaphore(value: 0)
    private let held = LockedValue(false)

    var isHeld: Bool {
        held.value
    }

    func hold(until window: DispatchTimeInterval) {
        held.withValue { $0 = true }
        entered.signal()
        _ = teardownReturned.wait(timeout: .now() + window)
        held.withValue { $0 = false }
    }
}
