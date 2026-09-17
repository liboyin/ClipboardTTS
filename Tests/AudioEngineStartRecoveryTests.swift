import XCTest
import AVFoundation
@testable import ClipboardTTSApp

/// What a failed engine start leaves behind, and what a later successful start must clear.
///
/// Every player here is built with an engine that failed to start, because that is the only way a
/// test can put an owned engine into the stopped state a real start failure or device change leaves.
final class AudioEngineStartRecoveryTests: XCTestCase {
    private static let engineStartFailureMessage = "Couldn't start audio playback. Try again."
    private static let unsupportedSampleRateMessage = "PCM sample rate must be a finite value from 8,000 to 48,000 Hz."

    func testSuccessfulPlayAfterAFailedPlayClearsTheFailureAndKeepsTheGraphReady() {
        // WHY: A failed start used to mark the format itself invalid, so a Play that later
        // succeeded left the old error on screen and refused every new session until Settings was
        // opened. A start that succeeds has resolved the failure, and a failed start never made the
        // format unplayable in the first place.
        let starter = SwitchableAudioEngineStarter(shouldFail: true)
        let timer = ProgressTimerSpy()
        let player = AudioPlayerManager(
            engineStarter: starter.start,
            automaticPlaybackScheduler: ManualAutomaticPlaybackScheduler().schedule,
            progressTimerScheduler: timer.schedule
        )
        defer { player.stop() }

        player.play()

        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.sampleRateError, Self.engineStartFailureMessage)
        XCTAssertTrue(player.isReadyForNewStream, "A failed start must not refuse the next session outright.")

        starter.shouldFail = false
        player.play()

        XCTAssertTrue(player.isPlaying)
        XCTAssertNil(player.sampleRateError, "A successful start must clear the failure an earlier start left.")
        XCTAssertTrue(player.isReadyForNewStream)
        XCTAssertEqual(starter.callCount, 3)
    }

    func testSuccessfulEngineStartDoesNotClearAnUnsupportedFormat() {
        // WHY: The two failures recover differently. Starting the engine cannot make an
        // unsupported rate playable, so a start that succeeds must leave that failure visible and
        // keep refusing sessions that would decode PCM at a rate the graph does not hold.
        let starter = SwitchableAudioEngineStarter(shouldFail: true)
        let timer = ProgressTimerSpy()
        let player = AudioPlayerManager(
            engineStarter: starter.start,
            automaticPlaybackScheduler: ManualAutomaticPlaybackScheduler().schedule,
            progressTimerScheduler: timer.schedule
        )
        defer { player.stop() }
        XCTAssertEqual(player.setSampleRate(.nan), .invalid)

        player.play()
        XCTAssertEqual(
            player.sampleRateError,
            Self.unsupportedSampleRateMessage,
            "A format failure outranks an engine failure, because no start can fix it."
        )

        starter.shouldFail = false
        player.play()

        XCTAssertEqual(player.sampleRateError, Self.unsupportedSampleRateMessage)
        XCTAssertFalse(player.isReadyForNewStream)
        XCTAssertFalse(player.prepareForNewStream())
    }

    func testPreparingANewStreamRetriesAStoppedEngine() {
        // WHY: This is the retry the failure message invites. Preparing reports whether a session
        // may begin, so it must attempt the start itself, publish a repeated failure, and clear the
        // failure once the start succeeds.
        let starter = SwitchableAudioEngineStarter(shouldFail: true)
        let player = AudioPlayerManager(
            engineStarter: starter.start,
            automaticPlaybackScheduler: ManualAutomaticPlaybackScheduler().schedule
        )
        defer { player.stop() }

        XCTAssertFalse(player.prepareForNewStream())
        XCTAssertEqual(starter.callCount, 2)
        XCTAssertEqual(player.sampleRateError, Self.engineStartFailureMessage)

        starter.shouldFail = false

        XCTAssertTrue(player.prepareForNewStream())
        XCTAssertEqual(starter.callCount, 3)
        XCTAssertNil(player.sampleRateError)

        XCTAssertTrue(player.prepareForNewStream())
        XCTAssertEqual(starter.callCount, 3, "A running engine must not be started again.")
    }

    func testSuccessfulAutomaticStartClearsAnEarlierEngineFailure() {
        // WHY: The prebuffer start is the other path that starts the engine on its own. If only
        // Play reconciled the failure, a stream that began playing automatically would still show
        // the error that its own start had just resolved.
        let scheduler = ManualAutomaticPlaybackScheduler()
        let starter = SwitchableAudioEngineStarter(shouldFail: true)
        let timer = ProgressTimerSpy()
        let stateUpdates = AudioStateUpdateRecorder()
        let player = AudioPlayerManager(
            engineStarter: starter.start,
            automaticPlaybackScheduler: scheduler.schedule,
            progressTimerScheduler: timer.schedule,
            audioStateObserver: stateUpdates.record
        )
        defer { player.stop() }
        XCTAssertEqual(player.sampleRateError, Self.engineStartFailureMessage)

        starter.shouldFail = false
        let buffered = stateUpdates.expectNextUpdate()
        let generation = player.startNewStream()
        player.scheduleAudio(data: Data(repeating: 0, count: 2), streamGeneration: generation)
        wait(for: [buffered], timeout: 1.0)
        let started = expectation(description: "The deferred start reaches the main queue")
        scheduler.runNextAction()
        DispatchQueue.main.async { started.fulfill() }
        wait(for: [started], timeout: 1.0)

        XCTAssertTrue(player.isPlaying)
        XCTAssertNil(player.sampleRateError)
    }
}
