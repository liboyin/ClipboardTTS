import XCTest
import AVFoundation
@testable import ClipboardTTSApp

// Shared by the suites that simulate an audio configuration change. A real change needs a physical
// device switch, so each test stops the engine its player owns and posts the notification
// AVFoundation would post for it, through a notification center the test owns.

enum ConfigurationChangePCM {
    static let oneSecond = Data(repeating: 0, count: 48_000) // 24,000 frames at 24 kHz
    static let halfSecond = Data(repeating: 0, count: 24_000)
}

/// A player built for configuration-change tests, with every seam its tests drive.
struct ConfigurationChangePlayerContext {
    let player: AudioPlayerManager
    let engine: AVAudioEngine
    let starter: SwitchableAudioEngineStarter
    let center: NotificationCenter
    let renderedPosition: RenderedPositionSource
    let progressTimer: ProgressTimerSpy
    let heldAutomaticStart: ManualAutomaticPlaybackScheduler
    let scheduledBuffers: ScheduledPCMBufferRecorder
    let stateUpdates: AudioStateUpdateRecorder
    let processedPacket: ArmedPacketSignal
    /// The recoveries a held-recovery player has scheduled, or nil when recovery hops as in production.
    let heldRecoveries: HeldRecoveryScheduler?
}

/// Keeps each configuration change's recovery instead of queuing it, so a test decides when it runs.
///
/// Holding a recovery is how a test reaches the interval in which a change has been counted but its
/// recovery is not yet on the main queue. Main-thread confined, like the recoveries it runs.
final class HeldRecoveryScheduler {
    private var actions: [() -> Void] = []

    var heldCount: Int {
        actions.count
    }

    func schedule(_ action: @escaping @Sendable () -> Void) {
        actions.append(action)
    }

    func runNextRecovery() {
        actions.removeFirst()()
    }
}

/// Lets a test block the main thread, without running its run loop, until the audio queue finishes
/// the next packet. Waiting on an `XCTestExpectation` would run the main queue and let that packet's
/// publication land, and holding that publication back is the ordering these tests need.
final class ArmedPacketSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var armed: DispatchSemaphore?

    /// Arms the signal for the next packet; call it before handing that packet to the player.
    func armForNextPacket() {
        lock.lock()
        armed = DispatchSemaphore(value: 0)
        lock.unlock()
    }

    func record() {
        lock.lock()
        let semaphore = armed
        lock.unlock()
        semaphore?.signal()
    }

    /// Blocks the calling thread until the armed packet has been handled, then disarms.
    func waitForArmedPacket(file: StaticString = #filePath, line: UInt = #line) {
        lock.lock()
        let semaphore = armed
        lock.unlock()
        defer {
            lock.lock()
            armed = nil
            lock.unlock()
        }
        guard let semaphore, semaphore.wait(timeout: .now() + 2.0) == .success else {
            XCTFail("The audio queue did not finish handling the armed packet.", file: file, line: line)
            return
        }
    }
}

extension XCTestCase {
    func makeConfigurationChangePlayer(holdingRecoveries: Bool = false) -> ConfigurationChangePlayerContext {
        let starter = SwitchableAudioEngineStarter()
        let engineCapture = EngineCapture()
        let center = NotificationCenter()
        let renderedPosition = RenderedPositionSource(sampleTime: nil)
        let progressTimer = ProgressTimerSpy()
        let heldAutomaticStart = ManualAutomaticPlaybackScheduler()
        let scheduledBuffers = ScheduledPCMBufferRecorder()
        let stateUpdates = AudioStateUpdateRecorder()
        let processedPacket = ArmedPacketSignal()
        let heldRecoveries = holdingRecoveries ? HeldRecoveryScheduler() : nil
        let player = AudioPlayerManager(
            scheduledBufferObserver: scheduledBuffers.record,
            engineStarter: { engine in
                engineCapture.engine = engine
                try starter.start(engine)
            },
            automaticPlaybackScheduler: heldAutomaticStart.schedule,
            renderedSampleTimeReader: renderedPosition.read,
            progressTimerScheduler: progressTimer.schedule,
            audioDataProcessingObserver: processedPacket.record,
            audioStateObserver: stateUpdates.record,
            notificationCenter: center,
            configurationChangeRecoveryScheduler: heldRecoveries.map { held in held.schedule }
                ?? AudioPlayerManager.mainQueueRecoveryScheduler
        )
        return ConfigurationChangePlayerContext(
            player: player,
            engine: engineCapture.engine!,
            starter: starter,
            center: center,
            renderedPosition: renderedPosition,
            progressTimer: progressTimer,
            heldAutomaticStart: heldAutomaticStart,
            scheduledBuffers: scheduledBuffers,
            stateUpdates: stateUpdates,
            processedPacket: processedPacket,
            heldRecoveries: heldRecoveries
        )
    }

    func bufferStream(_ pcm: Data, in context: ConfigurationChangePlayerContext) {
        let buffered = context.stateUpdates.expectNextUpdate()
        let generation = context.player.startNewStream()
        context.player.scheduleAudio(data: pcm, streamGeneration: generation)
        wait(for: [buffered], timeout: 1.0)
    }

    /// Opens a stream holding one second of PCM and lets its automatic start play it.
    @discardableResult
    func startPlayingStream(in context: ConfigurationChangePlayerContext) -> Int {
        let buffered = context.stateUpdates.expectNextUpdate()
        let generation = context.player.startNewStream()
        context.player.scheduleAudio(data: ConfigurationChangePCM.oneSecond, streamGeneration: generation)
        wait(for: [buffered], timeout: 1.0)
        runAutomaticStart(in: context)
        XCTAssertTrue(context.player.isPlaying, "Precondition: the stream is playing.")
        return generation
    }

    func runAutomaticStart(in context: ConfigurationChangePlayerContext) {
        context.heldAutomaticStart.runNextAction()
        drainConfigurationChangeMainQueue()
    }

    /// Stops the engine as AVFoundation does, posts its change, and lets the main queue run.
    ///
    /// The post is made on the main thread, so a player that handled the change synchronously in its
    /// observer has already changed its state when the post returns; the assertion there catches it.
    /// Only then does the main queue run what was queued, in queue order. A held-recovery player's
    /// recovery is not run here; the test releases it. `restartingEngineBeforeRecovery` starts the
    /// engine again before the queue runs, as any other start could before the recovery is reached.
    func postConfigurationChange(in context: ConfigurationChangePlayerContext,
                                 object: AVAudioEngine? = nil,
                                 restartingEngineBeforeRecovery: Bool = false,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) {
        let isPlayingBeforePost = context.player.isPlaying
        if object == nil {
            context.engine.stop()
        }
        context.center.post(name: .AVAudioEngineConfigurationChange, object: object ?? context.engine)
        XCTAssertEqual(
            context.player.isPlaying,
            isPlayingBeforePost,
            "A configuration change must be recovered later on the main queue, not inside the post.",
            file: file,
            line: line
        )
        if restartingEngineBeforeRecovery {
            XCTAssertNoThrow(try context.engine.start(), file: file, line: line)
        }
        drainConfigurationChangeMainQueue()
    }

    func drainConfigurationChangeMainQueue() {
        let drained = expectation(description: "The main queue completed a turn")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1.0)
    }
}

/// Records the engine a player hands its starter, so a test can stop and name that engine.
final class EngineCapture {
    var engine: AVAudioEngine?
}

/// Records the configuration-change registrations it hands out and the registrations removed from it.
///
/// Registrations are compared by identity, because a token is only meaningful as the object the
/// center returned.
final class RegistrationTrackingNotificationCenter: NotificationCenter, @unchecked Sendable {
    private let lock = NSLock()
    private var added: [ObjectIdentifier] = []
    private var removed: [ObjectIdentifier] = []

    var configurationChangeRegistrations: [ObjectIdentifier] {
        lock.lock()
        defer { lock.unlock() }
        return added
    }

    var removedRegistrations: [ObjectIdentifier] {
        lock.lock()
        defer { lock.unlock() }
        return removed
    }

    override func addObserver(forName name: NSNotification.Name?,
                              object obj: Any?,
                              queue: OperationQueue?,
                              using block: @escaping @Sendable (Notification) -> Void) -> NSObjectProtocol {
        let registration = super.addObserver(forName: name, object: obj, queue: queue, using: block)
        if name == .AVAudioEngineConfigurationChange {
            lock.lock()
            added.append(ObjectIdentifier(registration))
            lock.unlock()
        }
        return registration
    }

    override func removeObserver(_ observer: Any) {
        lock.lock()
        removed.append(ObjectIdentifier(observer as AnyObject))
        lock.unlock()
        super.removeObserver(observer)
    }
}
