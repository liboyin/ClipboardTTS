import AVFoundation
import Foundation
import XCTest
@testable import ClipboardTTSApp

/// The test-owned lifecycle of one `AudioPlayerManager`.
///
/// Every player a test builds comes from `makeOwnedAudioPlayer`, or from `makeAudioPlayerOwner` when
/// the test needs the owner itself; the `test_owned_audio_player` lint rule refuses any other
/// construction in `Tests/`. The owner's teardown is registered as the player is built, so it runs
/// however the test ends: after an expired wait, a failed assertion, or an early throw.
///
/// Each seam a suite injects stays that suite's; the owner wraps it rather than replacing it.
/// - The automatic-playback start is held by `heldAutomaticStarts` unless the test supplies a
///   scheduler. Whichever scheduler holds it is handed a stand-in, so teardown can drop the start
///   without running it wherever it is held.
/// - The progress timer is kept by `progressTimer`, off every run loop, unless the test supplies a
///   scheduler; teardown invalidates every timer the player built either way.
/// - The scheduled-buffer, processing and publication observers are forwarded while the owner is
///   open. Once it has closed, each call is counted in `ledger` and does nothing else.
/// - Configuration changes are observed on a notification center of the owner's, unless the test
///   supplies one, so no device change outside the test can queue a recovery.
///
/// The owner holds the player weakly. Queued audio work retains the player strongly, so a player
/// that has deallocated has nothing left queued to account for, and a test can still prove that a
/// player is released.
///
/// Unchecked `Sendable` because XCTest's teardown block is `@Sendable`. Everything the owner shares
/// across threads sits in `state`; the held scheduler synchronizes itself, and `timers` and
/// `progressTimer` are touched only on the main queue, where the player confines its timer.
final class AudioPlayerOwner: @unchecked Sendable {
    /// Work that reached the owner after teardown dropped the held starts or closed it.
    struct Ledger: Equatable, Sendable {
        /// Automatic starts still held when teardown dropped them. None of them ran.
        var droppedAutomaticStarts = 0
        /// Automatic starts scheduled after that drop, or a dropped one invoked later. None ran.
        var refusedAutomaticStarts = 0
        /// Buffers the player handed its node after the owner closed.
        var lateScheduledBuffers = 0
        /// Audio-queue processing the player completed after the owner closed.
        var lateProcessing = 0
        /// State publications the player applied after the owner closed.
        var latePublications = 0
    }

    private enum LateObservation: Sendable {
        case scheduledBuffer, processing, publication
    }

    private struct State: Sendable {
        var hasBegunTeardown = false
        var automaticStartsDropped = false
        var isClosed = false
        var lastAutomaticStart = 0
        /// Each start the player scheduled and nothing has run or dropped yet, keyed by stand-in.
        var heldAutomaticStarts: [Int: @Sendable () -> Void] = [:]
        var automaticStartsRun = 0
        var ledger = Ledger()
    }

    /// Holds the player's automatic starts when the test supplies no scheduler of its own.
    let heldAutomaticStarts = ManualAutomaticPlaybackScheduler()
    /// Holds the player's progress timer when the test supplies no timer scheduler of its own.
    let progressTimer = ProgressTimerSpy()
    private(set) weak var player: AudioPlayerManager?
    private let state = LockedValue(State())
    /// Every progress timer the player built. Main-queue confined, like the timer itself.
    private var timers: [Timer] = []

    var ledger: Ledger {
        state.value.ledger
    }

    /// How many scheduled automatic starts reached the player.
    var automaticStartsRun: Int {
        state.value.automaticStartsRun
    }

    var isClosed: Bool {
        state.value.isClosed
    }

    fileprivate func adopt(_ player: AudioPlayerManager) {
        self.player = player
    }

    /// The scheduler the player is built with: `inner` holds a stand-in for each start, and the
    /// start itself stays with the owner until it is run or dropped.
    fileprivate func automaticPlaybackScheduler(
        forwardingTo inner: @escaping (TimeInterval, @escaping @Sendable () -> Void) -> Void
    ) -> (TimeInterval, @escaping @Sendable () -> Void) -> Void {
        { [self] delay, start in
            // The count travels with the start, so any path that runs it is counted.
            let countedStart: @Sendable () -> Void = { [state] in
                state.withValue { $0.automaticStartsRun += 1 }
                start()
            }
            let standIn = state.withValue { state -> Int? in
                guard !state.automaticStartsDropped else {
                    state.ledger.refusedAutomaticStarts += 1
                    return nil
                }
                state.lastAutomaticStart += 1
                state.heldAutomaticStarts[state.lastAutomaticStart] = countedStart
                return state.lastAutomaticStart
            }
            guard let standIn else { return }
            inner(delay) { [self] in runAutomaticStart(standIn) }
        }
    }

    private func runAutomaticStart(_ standIn: Int) {
        let start = state.withValue { state -> (@Sendable () -> Void)? in
            guard let start = state.heldAutomaticStarts.removeValue(forKey: standIn) else {
                if state.automaticStartsDropped { state.ledger.refusedAutomaticStarts += 1 }
                return nil
            }
            return start
        }
        start?()
    }

    fileprivate func progressTimerScheduler(forwardingTo inner: @escaping (Timer) -> Void) -> (Timer) -> Void {
        { [self] timer in
            dispatchPrecondition(condition: .onQueue(.main))
            timers.append(timer)
            inner(timer)
        }
    }

    /// Runs `observer` while the owner is open; afterwards counts the call and does nothing else.
    private func forward(_ observation: LateObservation, to observer: () -> Void) {
        let isOpen = state.withValue { state -> Bool in
            guard state.isClosed else { return true }
            switch observation {
            case .scheduledBuffer: state.ledger.lateScheduledBuffers += 1
            case .processing: state.ledger.lateProcessing += 1
            case .publication: state.ledger.latePublications += 1
            }
            return false
        }
        if isOpen { observer() }
    }

    fileprivate func scheduledBufferObserver(
        forwardingTo inner: @escaping (AVAudioPCMBuffer) -> Void
    ) -> (AVAudioPCMBuffer) -> Void {
        { [self] buffer in forward(.scheduledBuffer) { inner(buffer) } }
    }

    fileprivate func processingObserver(forwardingTo inner: @escaping () -> Void) -> () -> Void {
        { [self] in forward(.processing, to: inner) }
    }

    fileprivate func publicationObserver(forwardingTo inner: @escaping () -> Void) -> () -> Void {
        { [self] in forward(.publication, to: inner) }
    }

    /// Ends the player's test-owned lifecycle. XCTest runs it from the teardown block registered
    /// when the player was built; a test may run it earlier to inspect what follows. Calling it again
    /// does nothing.
    ///
    /// The order is the guarantee. Stopping the player retires its stream and its timer, and the
    /// `bufferQueue.sync` inside `stop()` is the audio-queue barrier: every packet and ending queued
    /// before it has been processed, so every publication and automatic start they create already
    /// exists. Dropping the held starts then means none of them, nor any scheduled later, can run.
    /// Draining the main queue runs every publication queued before the barrier, which also releases
    /// the player those publications retain. Only then does the owner close, so later observer calls
    /// are counted rather than forwarded, and a final audio-queue barrier waits out any forward that
    /// passed the gate on that queue just before it closed.
    @MainActor
    func tearDown(file: StaticString = #filePath, line: UInt = #line) {
        let isFirstTeardown = state.withValue { state -> Bool in
            defer { state.hasBegunTeardown = true }
            return !state.hasBegunTeardown
        }
        guard isFirstTeardown else { return }
        let player = player
        player?.stop()
        dropAutomaticStarts()
        timers.forEach { $0.invalidate() }
        drainMainQueue(file: file, line: line)
        state.withValue { $0.isClosed = true }
        _ = player?.changesAudioFormat(to: AudioPlayerManager.defaultSampleRate)
    }

    private func dropAutomaticStarts() {
        state.withValue { state in
            state.automaticStartsDropped = true
            state.ledger.droppedAutomaticStarts += state.heldAutomaticStarts.count
            state.heldAutomaticStarts.removeAll()
        }
        heldAutomaticStarts.discardHeldActions()
    }

    @MainActor
    private func drainMainQueue(file: StaticString, line: UInt) {
        let drained = XCTestExpectation(description: "The owned player's queued publications have run")
        DispatchQueue.main.async { drained.fulfill() }
        guard XCTWaiter().wait(for: [drained], timeout: 2.0) == .completed else {
            XCTFail("The main queue did not complete a turn while tearing down an owned audio player.", file: file, line: line)
            return
        }
    }
}

/// A player and the owner of its test lifecycle, for tests that need to reach the owner.
struct OwnedAudioPlayer {
    let player: AudioPlayerManager
    let owner: AudioPlayerOwner
}

extension XCTestCase {
    /// Builds a test-owned `AudioPlayerManager`; see `AudioPlayerOwner`. Each argument is the
    /// production initializer's, and an omitted scheduler, timer scheduler, rendered-position reader
    /// or notification center is the owner's rather than production's.
    func makeOwnedAudioPlayer(
        sampleRate: Double = AudioPlayerManager.defaultSampleRate,
        scheduledBufferObserver: @escaping (AVAudioPCMBuffer) -> Void = { _ in },
        engineStarter: @escaping (AVAudioEngine) throws -> Void = { try $0.start() },
        automaticPlaybackScheduler: ((TimeInterval, @escaping @Sendable () -> Void) -> Void)? = nil,
        renderedSampleTimeReader: @escaping (AVAudioPlayerNode) -> AVAudioFramePosition? = { _ in nil },
        progressTimerScheduler: ((Timer) -> Void)? = nil,
        audioDataProcessingObserver: @escaping () -> Void = {},
        audioStateObserver: @escaping () -> Void = {},
        notificationCenter: NotificationCenter? = nil,
        configurationChangeRecoveryScheduler: @escaping (@escaping @Sendable () -> Void) -> Void
            = AudioPlayerManager.mainQueueRecoveryScheduler,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> AudioPlayerManager {
        makeAudioPlayerOwner(
            sampleRate: sampleRate,
            scheduledBufferObserver: scheduledBufferObserver,
            engineStarter: engineStarter,
            automaticPlaybackScheduler: automaticPlaybackScheduler,
            renderedSampleTimeReader: renderedSampleTimeReader,
            progressTimerScheduler: progressTimerScheduler,
            audioDataProcessingObserver: audioDataProcessingObserver,
            audioStateObserver: audioStateObserver,
            notificationCenter: notificationCenter,
            configurationChangeRecoveryScheduler: configurationChangeRecoveryScheduler,
            file: file,
            line: line
        ).player
    }

    /// Builds a test-owned player and returns its owner beside it; see `makeOwnedAudioPlayer`.
    func makeAudioPlayerOwner(
        sampleRate: Double = AudioPlayerManager.defaultSampleRate,
        scheduledBufferObserver: @escaping (AVAudioPCMBuffer) -> Void = { _ in },
        engineStarter: @escaping (AVAudioEngine) throws -> Void = { try $0.start() },
        automaticPlaybackScheduler: ((TimeInterval, @escaping @Sendable () -> Void) -> Void)? = nil,
        renderedSampleTimeReader: @escaping (AVAudioPlayerNode) -> AVAudioFramePosition? = { _ in nil },
        progressTimerScheduler: ((Timer) -> Void)? = nil,
        audioDataProcessingObserver: @escaping () -> Void = {},
        audioStateObserver: @escaping () -> Void = {},
        notificationCenter: NotificationCenter? = nil,
        configurationChangeRecoveryScheduler: @escaping (@escaping @Sendable () -> Void) -> Void
            = AudioPlayerManager.mainQueueRecoveryScheduler,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> OwnedAudioPlayer {
        let owner = AudioPlayerOwner()
        let player = AudioPlayerManager(
            sampleRate: sampleRate,
            scheduledBufferObserver: owner.scheduledBufferObserver(forwardingTo: scheduledBufferObserver),
            engineStarter: engineStarter,
            automaticPlaybackScheduler: owner.automaticPlaybackScheduler(
                forwardingTo: automaticPlaybackScheduler ?? owner.heldAutomaticStarts.schedule
            ),
            renderedSampleTimeReader: renderedSampleTimeReader,
            progressTimerScheduler: owner.progressTimerScheduler(
                forwardingTo: progressTimerScheduler ?? owner.progressTimer.schedule
            ),
            audioDataProcessingObserver: owner.processingObserver(forwardingTo: audioDataProcessingObserver),
            audioStateObserver: owner.publicationObserver(forwardingTo: audioStateObserver),
            notificationCenter: notificationCenter ?? NotificationCenter(),
            configurationChangeRecoveryScheduler: configurationChangeRecoveryScheduler
        )
        owner.adopt(player)
        addTeardownBlock {
            owner.tearDown(file: file, line: line)
        }
        return OwnedAudioPlayer(player: player, owner: owner)
    }
}
