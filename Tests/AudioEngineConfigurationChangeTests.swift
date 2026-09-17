import XCTest
import AVFoundation
@testable import ClipboardTTSApp

/// What a player does when its engine reports that the output hardware changed.
///
/// A real configuration change needs a physical device switch, so each test stops the engine it owns
/// and posts the notification AVFoundation would post for it, through a notification center the test
/// owns. Posting is synchronous, so every test also shows that the player recovers later on the main
/// queue rather than inside the post. `QueuedStartConfigurationChangeTests` holds recoveries to place
/// other work between them.
final class AudioEngineConfigurationChangeTests: XCTestCase {

    func testConfigurationChangeWhilePlayingPausesAtThePositionAndPlayResumesFromIt() {
        // WHY: The engine stops itself when the output changes, which left the menu showing playback
        // that was not happening. Speech must not move to a different device unasked, so the
        // session pauses where it was, the engine is ready again for the new output, and Play
        // renders the rest of the buffered PCM from that position rather than from whatever the
        // stopped engine had scheduled.
        let context = makeConfigurationChangePlayer()
        let player = context.player
        defer { player.stop() }
        startPlayingStream(in: context)
        player.seek(to: 0.5)
        let buffersBeforeChange = context.scheduledBuffers.count

        postConfigurationChange(in: context)

        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.isNodePlaying)
        XCTAssertFalse(context.progressTimer.isRunning)
        XCTAssertTrue(context.engine.isRunning, "The engine must be restarted for the new output.")
        XCTAssertNil(player.sampleRateError)
        XCTAssertTrue(player.hasAudio, "The buffered session must be kept for Play.")
        XCTAssertEqual(player.bufferDuration, 1.0, accuracy: 0.000_001)
        XCTAssertEqual(player.playbackProgress, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(context.scheduledBuffers.count, buffersBeforeChange + 1, "The node must be re-anchored.")
        XCTAssertEqual(context.scheduledBuffers.lastFrameLength, 12_000)

        player.play()

        XCTAssertTrue(player.isPlaying)
        XCTAssertTrue(player.isNodePlaying)
        XCTAssertEqual(player.progress(forRenderedSampleTime: 0) ?? -1, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(context.scheduledBuffers.count, buffersBeforeChange + 1, "Play must not schedule again.")
    }

    func testConfigurationChangeRevokesThePendingAutomaticStart() {
        // WHY: A stream still inside its prebuffer window would otherwise start by itself on the new
        // output a moment after the change, which is exactly the unasked device switch the pause
        // exists to prevent.
        let context = makeConfigurationChangePlayer()
        let player = context.player
        defer { player.stop() }
        bufferStream(ConfigurationChangePCM.oneSecond, in: context)

        postConfigurationChange(in: context)
        runAutomaticStart(in: context)

        XCTAssertFalse(player.isPlaying)
        XCTAssertTrue(player.hasAudio)
    }

    func testConfigurationChangeBeforeTheFirstPCMRevokesThatStreamsAutomaticStart() {
        // WHY: The session that owns the pipeline is paused as a whole, not only the audio it already
        // holds, so PCM its request delivers after the change waits for Play as well.
        let context = makeConfigurationChangePlayer()
        let player = context.player
        defer { player.stop() }
        let generation = player.startNewStream()

        postConfigurationChange(in: context)
        let buffered = context.stateUpdates.expectNextUpdate()
        player.scheduleAudio(data: ConfigurationChangePCM.oneSecond, streamGeneration: generation)
        wait(for: [buffered], timeout: 1.0)
        runAutomaticStart(in: context)

        XCTAssertFalse(player.isPlaying)
        XCTAssertTrue(player.hasAudio, "The request's PCM must still be buffered for Play.")
    }

    func testConfigurationChangeDuringAnUnderrunStopsLaterPCMFromResumingPlayback() {
        // WHY: An underrun is the one stop that later PCM undoes. Left in place across the change, the
        // provider's next chunk would restart speech on the new output by itself.
        let context = makeConfigurationChangePlayer()
        let player = context.player
        defer { player.stop() }
        let generation = startPlayingStream(in: context)
        context.renderedPosition.sampleTime = 24_000 // the whole second buffered so far
        context.progressTimer.fireTick()
        XCTAssertFalse(player.isPlaying, "Precondition: the stream ran dry while its request is open.")

        postConfigurationChange(in: context)
        let laterPCM = context.stateUpdates.expectNextUpdate()
        player.scheduleAudio(data: ConfigurationChangePCM.halfSecond, streamGeneration: generation)
        wait(for: [laterPCM], timeout: 1.0)

        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.isNodePlaying)
        XCTAssertEqual(player.bufferDuration, 1.5, accuracy: 0.000_001)
    }

    func testConfigurationChangeWhoseRestartFailsReleasesTheUnderrunForAnyLaterRestart() {
        // WHY: The re-anchoring seek also releases an underrun, but it only runs after a successful
        // restart. The pause itself has to release it: otherwise, once something else restarts the
        // engine (Settings synchronizing an unchanged rate does), the provider's next chunk would
        // resume speech on the new output that nobody asked to play.
        let context = makeConfigurationChangePlayer()
        let player = context.player
        defer { player.stop() }
        let generation = startPlayingStream(in: context)
        context.renderedPosition.sampleTime = 24_000 // the whole second buffered so far
        context.progressTimer.fireTick()
        XCTAssertFalse(player.isPlaying, "Precondition: the stream ran dry while its request is open.")
        context.starter.shouldFail = true

        postConfigurationChange(in: context)
        XCTAssertFalse(context.engine.isRunning)
        XCTAssertEqual(player.sampleRateError, "Couldn't start audio playback. Try again.")
        context.starter.shouldFail = false
        XCTAssertEqual(player.setSampleRate(AudioPlayerManager.defaultSampleRate), .unchanged)
        XCTAssertTrue(context.engine.isRunning, "Precondition: a Settings sync restarted the engine.")

        let laterPCM = context.stateUpdates.expectNextUpdate()
        player.scheduleAudio(data: ConfigurationChangePCM.halfSecond, streamGeneration: generation)
        wait(for: [laterPCM], timeout: 1.0)

        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.isNodePlaying)
        XCTAssertFalse(context.progressTimer.isRunning)
    }

    func testConfigurationChangeKeepsAManualPauseWhereTheUserLeftIt() {
        // WHY: A paused session belongs to the user. The change must not resume it or lose its place,
        // and must still leave Play able to continue from that place on the restarted engine.
        let context = makeConfigurationChangePlayer()
        let player = context.player
        defer { player.stop() }
        startPlayingStream(in: context)
        player.seek(to: 0.25)
        player.pause()
        let buffersBeforeChange = context.scheduledBuffers.count

        postConfigurationChange(in: context)

        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.playbackProgress, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(context.scheduledBuffers.count, buffersBeforeChange + 1, "The paused node must be re-anchored.")
        XCTAssertEqual(context.scheduledBuffers.lastFrameLength, 18_000)

        player.play()

        XCTAssertTrue(player.isPlaying)
        XCTAssertTrue(player.isNodePlaying)
        XCTAssertEqual(player.progress(forRenderedSampleTime: 0) ?? -1, 0.25, accuracy: 0.000_001)
    }

    func testConfigurationChangeWhileIdleLeavesTheNextSessionFreeToStart() {
        // WHY: With nothing speaking, the change only has to make the engine usable again. The pause
        // it records must not reach a session started afterwards.
        let context = makeConfigurationChangePlayer()
        let player = context.player
        defer { player.stop() }

        postConfigurationChange(in: context)

        XCTAssertTrue(context.engine.isRunning)
        XCTAssertTrue(player.isReadyForNewStream)
        startPlayingStream(in: context)
        XCTAssertTrue(player.isPlaying)
    }

    func testPlayRestartsAndReanchorsWhenTheRecoveryRestartFailed() {
        // WHY: A restart can fail while the new output settles. The failure must be shown, and the
        // Play it invites must restart the engine and render from the paused position, because the
        // buffers the old engine held cannot be trusted.
        let context = makeConfigurationChangePlayer()
        let player = context.player
        defer { player.stop() }
        startPlayingStream(in: context)
        player.seek(to: 0.5)
        context.starter.shouldFail = true

        postConfigurationChange(in: context)

        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(context.engine.isRunning)
        XCTAssertEqual(player.sampleRateError, "Couldn't start audio playback. Try again.")
        let buffersBeforePlay = context.scheduledBuffers.count

        context.starter.shouldFail = false
        player.play()

        XCTAssertTrue(context.engine.isRunning)
        XCTAssertTrue(player.isPlaying)
        XCTAssertTrue(player.isNodePlaying)
        XCTAssertNil(player.sampleRateError)
        XCTAssertEqual(context.scheduledBuffers.count, buffersBeforePlay + 1)
        XCTAssertEqual(context.scheduledBuffers.lastFrameLength, 12_000)
        XCTAssertEqual(player.progress(forRenderedSampleTime: 0) ?? -1, 0.5, accuracy: 0.000_001)
    }

    func testPlayOnARunningEngineDoesNotRescheduleBufferedAudio() {
        // WHY: Re-anchoring belongs only to a Play that had to start a stopped engine. An ordinary
        // resume after Pause keeps the node's own schedule and position.
        let context = makeConfigurationChangePlayer()
        let player = context.player
        defer { player.stop() }
        startPlayingStream(in: context)
        player.pause()
        let buffersBeforePlay = context.scheduledBuffers.count

        player.play()

        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(context.scheduledBuffers.count, buffersBeforePlay)
    }

    func testConfigurationChangeOfAnotherEngineIsIgnored() {
        // WHY: Every engine in the process posts this notification. Only this player's engine
        // changing says anything about this player's playback.
        let context = makeConfigurationChangePlayer()
        let player = context.player
        defer { player.stop() }
        startPlayingStream(in: context)
        let otherEngine = AVAudioEngine()

        postConfigurationChange(in: context, object: otherEngine)

        XCTAssertTrue(player.isPlaying)
        XCTAssertTrue(player.isNodePlaying)
    }

    func testObservingConfigurationChangesDoesNotKeepThePlayerAlive() {
        // WHY: The observer lives in a notification center that outlives any one player. Holding the
        // player strongly would keep its engine and graph alive for the life of the process.
        let center = NotificationCenter()
        weak var releasedPlayer: AudioPlayerManager?
        autoreleasepool {
            let player = AudioPlayerManager(
                automaticPlaybackScheduler: ManualAutomaticPlaybackScheduler().schedule,
                notificationCenter: center
            )
            releasedPlayer = player
        }

        XCTAssertNil(releasedPlayer)
    }

    func testReleasingThePlayerRemovesItsConfigurationChangeRegistration() {
        // WHY: A notification center keeps a block registration until it is removed explicitly, even
        // after the block's weak player is gone. Without removal each player would leave a dead
        // registration behind for the life of the process-wide center.
        let center = RegistrationTrackingNotificationCenter()
        autoreleasepool {
            _ = AudioPlayerManager(
                automaticPlaybackScheduler: ManualAutomaticPlaybackScheduler().schedule,
                notificationCenter: center
            )
        }

        XCTAssertEqual(center.configurationChangeRegistrations.count, 1)
        XCTAssertEqual(
            center.removedRegistrations,
            center.configurationChangeRegistrations,
            "Releasing the player must remove the registration it added."
        )
    }
}
