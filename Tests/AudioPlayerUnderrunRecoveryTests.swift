import XCTest
import AVFoundation
@testable import ClipboardTTSApp

/// Covers the four ways playback comes to rest at the end of the buffered PCM, and which of them
/// the next chunk of PCM is allowed to undo. Each test states the rendered position the manager
/// reads and fires its progress timer itself, so the moment playback runs out of audio is chosen
/// rather than waited for.
final class AudioPlayerUnderrunRecoveryTests: XCTestCase {

    private let twoSecondsOfPCM = Data(repeating: 0, count: 96_000) // 48,000 frames at 24 kHz
    private let halfSecondOfPCM = Data(repeating: 0, count: 24_000) // 12,000 frames at 24 kHz
    private let packetProcessed = ProcessedPacketSignal()

    func testPCMArrivingAfterAnUnderrunResumesPlaybackWhereItStopped() {
        // WHY: A provider that pauses between chunks left playback stopped at the end of what had
        // arrived, and nothing ever started it again. The next PCM must resume the same stream from
        // the position it stopped at: no buffer already heard rescheduled, no second prebuffer
        // window, and no position credited for the silence the node rendered while it ran dry.
        let context = makePlayer()
        let player = context.player
        defer { player.stop() }
        let generation = startBufferedStream(in: context)

        player.play()
        XCTAssertTrue(player.isPlaying)
        context.renderedPosition.sampleTime = 50_400 // 2.1 seconds: 0.1 second of it rendered dry
        context.progressTimer.fireTick()

        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.isNodePlaying)
        XCTAssertEqual(player.playbackProgress, 2.0, accuracy: 0.000_001)
        XCTAssertFalse(context.progressTimer.isRunning)
        XCTAssertEqual(context.scheduledBuffers.count, 1)

        let resumingPCM = context.stateUpdates.expectNextUpdate()
        player.scheduleAudio(data: halfSecondOfPCM, streamGeneration: generation)
        wait(for: [resumingPCM], timeout: 1.0)

        XCTAssertTrue(player.isPlaying)
        XCTAssertTrue(player.isNodePlaying)
        XCTAssertTrue(context.progressTimer.isRunning)
        XCTAssertEqual(context.progressTimer.requestedInterval, 0.1)
        XCTAssertEqual(player.bufferDuration, 2.5, accuracy: 0.000_001)
        XCTAssertEqual(player.playbackProgress, 2.0, accuracy: 0.000_001)
        XCTAssertEqual(context.scheduledBuffers.count, 2)
        XCTAssertEqual(context.scheduledBuffers.totalFrameCount, 60_000)
        XCTAssertEqual(context.heldAutomaticStart.scheduledDelays, [0.1])

        context.renderedPosition.sampleTime = 55_200 // 0.2 second of the resumed PCM rendered
        context.progressTimer.fireTick()

        XCTAssertEqual(player.playbackProgress, 2.2, accuracy: 0.000_001)
        XCTAssertTrue(player.isPlaying)
    }

    func testPCMArrivingWhileAStreamPlaysLeavesItsProgressTimerRunning() {
        // WHY: A stream is only resumed once per underrun. A manager that treated every chunk as a
        // resume would rebuild the progress timer on each one, and a provider sending chunks faster
        // than the 0.1-second cadence would then reset it before it ever ticked, freezing the
        // position the menu shows for as long as the audio kept arriving.
        let context = makePlayer()
        let player = context.player
        defer { player.stop() }
        let generation = startBufferedStream(in: context)

        player.play()
        context.renderedPosition.sampleTime = 50_400 // 2.1 seconds
        context.progressTimer.fireTick()
        XCTAssertFalse(player.isPlaying)

        let resumingPCM = context.stateUpdates.expectNextUpdate()
        player.scheduleAudio(data: halfSecondOfPCM, streamGeneration: generation)
        wait(for: [resumingPCM], timeout: 1.0)
        let resumedTimer = context.progressTimer.timer
        XCTAssertTrue(player.isPlaying)
        XCTAssertNotNil(resumedTimer)

        let furtherPCM = context.stateUpdates.expectNextUpdate()
        player.scheduleAudio(data: halfSecondOfPCM, streamGeneration: generation)
        wait(for: [furtherPCM], timeout: 1.0)

        XCTAssertEqual(player.bufferDuration, 3.0, accuracy: 0.000_001)
        XCTAssertTrue(player.isPlaying)
        XCTAssertTrue(context.progressTimer.timer === resumedTimer)
    }

    func testStreamWhoseRequestHasTerminatedIsNotRestartedByLatePCM() {
        // WHY: Reaching the end of a request that has already delivered its terminal event is the
        // genuine end of playback, and the manager owns that distinction: audio presented for a
        // stream it has been told is over must be buffered for replay without starting the node
        // again, whatever ordering the caller delivering it happens to provide. Rendering that
        // lands exactly on the buffered end has reached it, so it stops there rather than playing
        // on until a later tick overshoots.
        let context = makePlayer()
        let player = context.player
        defer { player.stop() }
        let generation = startBufferedStream(in: context)

        let terminationPublished = context.stateUpdates.expectNextUpdate()
        player.finishStream(streamGeneration: generation, termination: .finished)
        wait(for: [terminationPublished], timeout: 1.0)
        XCTAssertEqual(player.streamTermination, .finished)

        player.play()
        context.renderedPosition.sampleTime = 48_000 // exactly the 2 seconds that were buffered
        context.progressTimer.fireTick()

        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.playbackProgress, 2.0, accuracy: 0.000_001)

        let latePCM = context.stateUpdates.expectNextUpdate()
        player.scheduleAudio(data: halfSecondOfPCM, streamGeneration: generation)
        wait(for: [latePCM], timeout: 1.0)

        XCTAssertEqual(player.bufferDuration, 2.5, accuracy: 0.000_001)
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.isNodePlaying)
        XCTAssertFalse(context.progressTimer.isRunning)
    }

    func testManualPauseIsNotUndoneByPCMArrivingBehindIt() {
        // WHY: Pause is the user's decision, and a stream keeps buffering while it is paused. The
        // chunks that arrive behind a Pause must extend what Resume will play, never start playing
        // it, which is the one thing that separates a Pause from a stream that ran dry.
        let context = makePlayer()
        let player = context.player
        defer { player.stop() }
        let generation = startBufferedStream(in: context)

        player.play()
        context.renderedPosition.sampleTime = 4_800 // 0.2 second, well inside the buffer
        context.progressTimer.fireTick()
        XCTAssertEqual(player.playbackProgress, 0.2, accuracy: 0.000_001)
        XCTAssertTrue(player.isPlaying)

        player.pause()
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.isNodePlaying)

        let pcmBehindThePause = context.stateUpdates.expectNextUpdate()
        player.scheduleAudio(data: halfSecondOfPCM, streamGeneration: generation)
        wait(for: [pcmBehindThePause], timeout: 1.0)

        XCTAssertEqual(player.bufferDuration, 2.5, accuracy: 0.000_001)
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.isNodePlaying)
        XCTAssertFalse(context.progressTimer.isRunning)
    }

    func testSeekDuringAnUnderrunKeepsPlaybackWhereTheUserPutIt() {
        // WHY: Choosing a position while a dry stream is stopped is as deliberate as pausing. The
        // PCM that arrives next must extend the buffer the user is sitting in, not jump playback
        // back to the end they seeked away from and start it.
        let context = makePlayer()
        let player = context.player
        defer { player.stop() }
        let generation = startBufferedStream(in: context)

        player.play()
        context.renderedPosition.sampleTime = 50_400 // 2.1 seconds
        context.progressTimer.fireTick()
        XCTAssertFalse(player.isPlaying)

        player.seek(to: 0.5)
        XCTAssertEqual(player.playbackProgress, 0.5, accuracy: 0.000_001)

        let pcmAfterTheSeek = context.stateUpdates.expectNextUpdate()
        player.scheduleAudio(data: halfSecondOfPCM, streamGeneration: generation)
        wait(for: [pcmAfterTheSeek], timeout: 1.0)

        XCTAssertEqual(player.bufferDuration, 2.5, accuracy: 0.000_001)
        XCTAssertEqual(player.playbackProgress, 0.5, accuracy: 0.000_001)
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(context.progressTimer.isRunning)
    }

    func testCancelledStreamsPCMCannotResumeTheUnderrunItLeftBehind() {
        // WHY: Clear Buffer and a replacing session both stop the player, and a request still in
        // flight can deliver another chunk afterwards. That chunk belongs to a stream nobody owns
        // any more, so it must neither be buffered nor restart the playback the cancellation ended.
        let context = makePlayer()
        let player = context.player
        defer { player.stop() }
        let generation = startBufferedStream(in: context)

        player.play()
        context.renderedPosition.sampleTime = 50_400 // 2.1 seconds
        context.progressTimer.fireTick()
        XCTAssertFalse(player.isPlaying)

        player.stop()

        let cancelledPCM = context.processedPackets.expectNextProcessing()
        player.scheduleAudio(data: halfSecondOfPCM, streamGeneration: generation)
        wait(for: [cancelledPCM], timeout: 1.0)

        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.hasAudio)
        XCTAssertEqual(player.bufferDuration, 0.0)
        XCTAssertFalse(context.progressTimer.isRunning)
    }

    func testTickSeeingAChunkTheNodeHasButTheMenuHasNotIsNotAnUnderrun() {
        // WHY: Scheduling PCM onto the node and publishing its new duration are two steps, and a
        // tick can land between them. Judged against the duration the menu has been told, a stream
        // already rendering its next chunk looks as though it ran dry: it would be stopped with
        // audio in hand, and the frames it had heard of that chunk discounted as silence, leaving
        // every later position short by that much.
        let context = makePlayer(alsoOnProcessing: packetProcessed.record)
        let player = context.player
        defer { player.stop() }
        let generation = startBufferedStream(in: context)
        packetProcessed.waitForPacket() // the two seconds the stream opened with

        player.play()
        context.renderedPosition.sampleTime = 4_800 // 0.2 second, well inside the buffer
        context.progressTimer.fireTick()
        XCTAssertTrue(player.isPlaying)

        // Hold the main queue until the audio queue has put the next chunk on the node, so the tick
        // below runs before the duration that chunk publishes can land.
        let publishedDuration = context.stateUpdates.expectNextUpdate()
        player.scheduleAudio(data: halfSecondOfPCM, streamGeneration: generation)
        packetProcessed.waitForPacket()
        XCTAssertEqual(player.bufferDuration, 2.0, accuracy: 0.000_001)

        context.renderedPosition.sampleTime = 50_400 // 2.1 seconds: inside the chunk just scheduled
        context.progressTimer.fireTick()

        XCTAssertTrue(player.isPlaying)
        XCTAssertTrue(context.progressTimer.isRunning)

        wait(for: [publishedDuration], timeout: 1.0)
        XCTAssertEqual(player.bufferDuration, 2.5, accuracy: 0.000_001)
        context.progressTimer.fireTick()

        XCTAssertEqual(player.playbackProgress, 2.1, accuracy: 0.000_001)
        XCTAssertTrue(player.isPlaying)
    }

    func testUnderrunAnchorsToThePCMTheNodeHoldsNotTheDurationTheMenuHasBeenTold() {
        // WHY: A stream can run dry while a chunk it already holds is still waiting to publish its
        // duration. Anchoring the resumed position to what the menu had been told would discount
        // that whole chunk as silence, so every position after the underrun would report short by
        // its length rather than by the moment of dry rendering.
        let context = makePlayer(alsoOnProcessing: packetProcessed.record)
        let player = context.player
        defer { player.stop() }
        let generation = startBufferedStream(in: context)
        packetProcessed.waitForPacket() // the two seconds the stream opened with

        player.play()
        context.renderedPosition.sampleTime = 4_800 // 0.2 second, well inside the buffer
        context.progressTimer.fireTick()
        XCTAssertTrue(player.isPlaying)

        let publishedDuration = context.stateUpdates.expectNextUpdate()
        player.scheduleAudio(data: halfSecondOfPCM, streamGeneration: generation)
        packetProcessed.waitForPacket()
        XCTAssertEqual(player.bufferDuration, 2.0, accuracy: 0.000_001)

        context.renderedPosition.sampleTime = 62_400 // 2.6 seconds: past all 2.5 the node holds
        context.progressTimer.fireTick()
        XCTAssertFalse(player.isPlaying)

        wait(for: [publishedDuration], timeout: 1.0)
        XCTAssertEqual(player.bufferDuration, 2.5, accuracy: 0.000_001)
        XCTAssertTrue(player.isPlaying)

        let furtherDuration = context.stateUpdates.expectNextUpdate()
        player.scheduleAudio(data: halfSecondOfPCM, streamGeneration: generation)
        wait(for: [furtherDuration], timeout: 1.0)
        XCTAssertEqual(player.bufferDuration, 3.0, accuracy: 0.000_001)

        context.renderedPosition.sampleTime = 64_800 // 0.1 second of the resumed PCM rendered
        context.progressTimer.fireTick()

        XCTAssertEqual(player.playbackProgress, 2.6, accuracy: 0.000_001)
        XCTAssertTrue(player.isPlaying)
    }

    func testStreamStartedAfterAnUnderrunWaitsForItsOwnPrebuffer() {
        // WHY: The suspension belongs to the one stream that ran dry. A replacement stream must
        // open its own 0.1-second prebuffer window rather than inherit the previous stream's claim
        // on the next chunk, which would start speaking the moment the first bytes arrived.
        let context = makePlayer()
        let player = context.player
        defer { player.stop() }
        _ = startBufferedStream(in: context)

        player.play()
        context.renderedPosition.sampleTime = 50_400 // 2.1 seconds
        context.progressTimer.fireTick()
        XCTAssertFalse(player.isPlaying)

        let replacement = player.startNewStream()
        let firstPCMOfTheReplacement = context.stateUpdates.expectNextUpdate()
        player.scheduleAudio(data: halfSecondOfPCM, streamGeneration: replacement)
        wait(for: [firstPCMOfTheReplacement], timeout: 1.0)

        XCTAssertEqual(player.bufferDuration, 0.5, accuracy: 0.000_001)
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(context.progressTimer.isRunning)
        XCTAssertEqual(context.heldAutomaticStart.scheduledDelays, [0.1, 0.1])
    }

    /// The manager and the doubles one of these tests drives it through.
    private struct PlayerContext {
        let player: AudioPlayerManager
        let renderedPosition: RenderedPositionSource
        let progressTimer: ProgressTimerSpy
        let heldAutomaticStart: ManualAutomaticPlaybackScheduler
        let scheduledBuffers: ScheduledPCMBufferRecorder
        let stateUpdates: AudioStateUpdateRecorder
        let processedPackets: AudioDataProcessingRecorder
    }

    private func makePlayer(alsoOnProcessing: @escaping () -> Void = {}) -> PlayerContext {
        let renderedPosition = RenderedPositionSource(sampleTime: nil)
        let progressTimer = ProgressTimerSpy()
        let heldAutomaticStart = ManualAutomaticPlaybackScheduler()
        let scheduledBuffers = ScheduledPCMBufferRecorder()
        let stateUpdates = AudioStateUpdateRecorder()
        let processedPackets = AudioDataProcessingRecorder()
        let player = AudioPlayerManager(
            scheduledBufferObserver: scheduledBuffers.record,
            automaticPlaybackScheduler: heldAutomaticStart.schedule,
            renderedSampleTimeReader: renderedPosition.read,
            progressTimerScheduler: progressTimer.schedule,
            audioDataProcessingObserver: {
                processedPackets.record()
                alsoOnProcessing()
            },
            audioStateObserver: stateUpdates.record
        )
        return PlayerContext(
            player: player,
            renderedPosition: renderedPosition,
            progressTimer: progressTimer,
            heldAutomaticStart: heldAutomaticStart,
            scheduledBuffers: scheduledBuffers,
            stateUpdates: stateUpdates,
            processedPackets: processedPackets
        )
    }

    /// Opens a stream holding two seconds of PCM, with its prebuffer start still held by the test.
    private func startBufferedStream(in context: PlayerContext) -> Int {
        let bufferPublished = context.stateUpdates.expectNextUpdate()
        let generation = context.player.startNewStream()
        context.player.scheduleAudio(data: twoSecondsOfPCM, streamGeneration: generation)
        wait(for: [bufferPublished], timeout: 1.0)
        XCTAssertEqual(context.player.bufferDuration, 2.0, accuracy: 0.000_001)
        XCTAssertNil(context.player.streamTermination)
        return generation
    }
}

/// Releases a test that is holding the main queue as soon as the audio queue has finished handling
/// one packet. A test that waited on an `XCTestExpectation` instead would run the main run loop and
/// let the state that packet publishes land, which is exactly the window it needs to observe.
private final class ProcessedPacketSignal: Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func record() {
        semaphore.signal()
    }

    func waitForPacket(file: StaticString = #filePath, line: UInt = #line) {
        if semaphore.wait(timeout: .now() + 2.0) == .timedOut {
            XCTFail("The audio queue did not finish handling a packet.", file: file, line: line)
        }
    }
}
