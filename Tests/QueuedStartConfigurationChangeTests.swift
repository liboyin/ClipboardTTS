import XCTest
import AVFoundation
import Combine
@testable import ClipboardTTSApp

/// Playback starts that were already queued on the main queue when a configuration change arrived.
///
/// AVFoundation stops the engine and then posts the change from its own thread, and recovery can only
/// run once the main queue reaches it. Each test here queues a start ahead of that recovery and shows
/// the start stands down, so speech never begins on the new output before recovery pauses it.
final class QueuedStartConfigurationChangeTests: XCTestCase {

    func testAutomaticStartQueuedAheadOfRecoveryDoesNotStartPlayback() {
        // WHY: The prebuffer start restarts a stopped engine by design, for an engine that failed to
        // start. Queued ahead of the recovery, it would restart the engine for the new output and
        // play there until the recovery paused it.
        let context = makeConfigurationChangePlayer()
        let player = context.player
        defer { player.stop() }
        bufferStream(ConfigurationChangePCM.oneSecond, in: context)
        let playingStates = recordPlayingStates(of: player)
        defer { playingStates.cancel() }

        context.heldAutomaticStart.runNextAction()
        postConfigurationChange(in: context)

        XCTAssertFalse(playingStates.values.contains(true), "Playback must never start on the changed output.")
        XCTAssertFalse(player.isNodePlaying)
        XCTAssertTrue(player.hasAudio)
    }

    func testUnderrunResumeQueuedAheadOfRecoveryDoesNotResumePlayback() {
        // WHY: PCM that ends an underrun resumes the node from its main-queue publication. If that
        // publication is already queued when the change arrives, and something has restarted the
        // engine in between, it would resume speech on the new output before the recovery ran.
        let context = makeConfigurationChangePlayer()
        let player = context.player
        defer { player.stop() }
        let generation = startPlayingStream(in: context)
        context.renderedPosition.sampleTime = 24_000 // the whole second buffered so far
        context.progressTimer.fireTick()
        XCTAssertFalse(player.isPlaying, "Precondition: the stream ran dry while its request is open.")
        let playingStates = recordPlayingStates(of: player)
        defer { playingStates.cancel() }

        context.processedPacket.armForNextPacket()
        player.scheduleAudio(data: ConfigurationChangePCM.halfSecond, streamGeneration: generation)
        context.processedPacket.waitForArmedPacket()
        postConfigurationChange(in: context, restartingEngineBeforeRecovery: true)

        XCTAssertFalse(playingStates.values.contains(true), "The queued resume must stand down for the recovery.")
        XCTAssertFalse(player.isNodePlaying)
        XCTAssertEqual(player.bufferDuration, 1.5, accuracy: 0.000_001)
    }

    func testUnderrunResumeOnAStoppedEngineLeavesPlaybackPaused() {
        // WHY: The engine stops before its notification is posted, so PCM can end an underrun while
        // the engine is stopped and nothing has said why yet. Playing the node of a stopped engine
        // raises, so the resume must leave the stream paused for Play instead.
        let context = makeConfigurationChangePlayer()
        let player = context.player
        defer { player.stop() }
        let generation = startPlayingStream(in: context)
        context.renderedPosition.sampleTime = 24_000
        context.progressTimer.fireTick()
        XCTAssertFalse(player.isPlaying, "Precondition: the stream ran dry while its request is open.")

        context.engine.stop()
        let laterPCM = context.stateUpdates.expectNextUpdate()
        player.scheduleAudio(data: ConfigurationChangePCM.halfSecond, streamGeneration: generation)
        wait(for: [laterPCM], timeout: 1.0)

        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.isNodePlaying)
        XCTAssertFalse(context.progressTimer.isRunning)
        XCTAssertTrue(player.hasAudio)
    }

    func testStreamStartedBetweenTwoRecoveriesWaitsForTheSecondRecovery() {
        // WHY: A second change can be counted before its recovery is queued, so the first recovery can
        // finish while the second is still outstanding. A stream started in that interval is not one
        // the first recovery paused, and only the outstanding change can keep its automatic start from
        // playing on the changed output. A flag the first recovery cleared would let it through.
        let context = makeConfigurationChangePlayer(holdingRecoveries: true)
        let player = context.player
        defer { player.stop() }
        let recoveries = context.heldRecoveries!
        startPlayingStream(in: context)
        postConfigurationChange(in: context)
        postConfigurationChange(in: context)
        XCTAssertEqual(recoveries.heldCount, 2, "Precondition: both changes await recovery.")
        recoveries.runNextRecovery()
        XCTAssertFalse(player.isPlaying)
        let playingStates = recordPlayingStates(of: player)
        defer { playingStates.cancel() }

        bufferStream(ConfigurationChangePCM.oneSecond, in: context)
        runAutomaticStart(in: context)

        XCTAssertFalse(playingStates.values.contains(true), "The outstanding change must hold the new stream back.")
        XCTAssertFalse(player.isNodePlaying)
        recoveries.runNextRecovery()
        XCTAssertFalse(player.isPlaying)
        XCTAssertTrue(player.hasAudio)
    }

    // MARK: - Helpers

    /// Records every `isPlaying` value published after this call.
    private func recordPlayingStates(of player: AudioPlayerManager) -> PlayingStateRecording {
        let recording = PlayingStateRecording()
        recording.subscription = player.$isPlaying.dropFirst().sink { recording.values.append($0) }
        return recording
    }
}

/// The `isPlaying` values a player published, in order. Main-queue confined, like the publication.
private final class PlayingStateRecording {
    var values: [Bool] = []
    var subscription: AnyCancellable?

    func cancel() {
        subscription?.cancel()
    }
}
