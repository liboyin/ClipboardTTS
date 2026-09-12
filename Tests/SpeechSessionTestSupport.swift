import AVFoundation
import Combine
import Foundation
import XCTest
@testable import ClipboardTTSApp

// Test doubles shared by the suites that observe a speech session's handoff. They live here
// rather than beside one suite because the session owner's tests and the network manager's
// termination tests both watch the same two things: what a client was handed, and whether a
// revocation genuinely had to wait for an authorized callback.

/// Records what one session's client received, in the order it received it.
///
/// Both halves of the handoff arrive on the manager's audio-delivery queue and are read on the test
/// thread, so the log owns its value rather than leaving a `var` for a `@Sendable` client to mutate.
final class SessionEventLog: @unchecked Sendable {
    /// What a client was handed, reduced to what order assertions need to distinguish.
    enum Event: Equatable {
        case audio(Data)
        case terminated(SpeechStreamTermination)
    }

    private let lock = NSLock()
    private var events: [Event] = []

    func record(_ event: Event) {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
    }

    var recorded: [Event] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

/// Carries a main-confined action across the `@Sendable` boundary of a request observer.
///
/// Unchecked because the confinement is what makes it safe rather than the action's type: the test
/// builds the action on the main queue, where the audio graph it touches lives, and the observer
/// runs it only there.
struct MainQueueSessionAction: @unchecked Sendable {
    let run: () -> Void
}

/// A recursive callback authority that runs one test-supplied action the next time it is acquired.
///
/// The action runs on the acquiring thread before the lock is taken, which is the only point a test
/// can occupy between a caller deciding to revoke a request and the revocation itself: every
/// revocation crosses this boundary, and nothing else on that path offers a seam. It is armed for
/// one acquisition at a time, so an unrelated later acquisition cannot run a test's action twice.
final class LockObservingCallbackAuthority: CallbackAuthorityLocking, @unchecked Sendable {
    private let recursiveLock = NSRecursiveLock()
    private let pendingAction = LockedValue<(@Sendable () -> Void)?>(nil)

    /// Runs `body` on whichever thread next acquires authority, once.
    func runOnNextAcquisition(_ body: @escaping @Sendable () -> Void) {
        pendingAction.withValue { $0 = body }
    }

    func lock() {
        let action = pendingAction.withValue { pending -> (@Sendable () -> Void)? in
            defer { pending = nil }
            return pending
        }
        action?()
        recursiveLock.lock()
    }

    func unlock() {
        recursiveLock.unlock()
    }
}

/// A recursive callback authority that reports when a caller has to wait for authority somebody
/// else holds.
///
/// `RecursiveCallbackAuthority` cannot distinguish a revocation that returned because it waited
/// from one that returned because there was nothing to wait for, and that difference is the whole
/// guarantee. Trying the lock first separates them: only a failed attempt means another thread is
/// inside an authorized callback. The observer is armed for one wait at a time, so an unrelated
/// uncontended acquisition earlier in a test cannot satisfy the wait a test is watching for.
final class WaitObservingCallbackAuthority: CallbackAuthorityLocking, @unchecked Sendable {
    private let recursiveLock = NSRecursiveLock()
    private let pendingObserver = LockedValue<(@Sendable () -> Void)?>(nil)

    /// Reports the next contended acquisition, once.
    func observeNextWait(_ body: @escaping @Sendable () -> Void) {
        pendingObserver.withValue { $0 = body }
    }

    func lock() {
        if recursiveLock.`try`() { return }
        let observer = pendingObserver.withValue { pending -> (@Sendable () -> Void)? in
            defer { pending = nil }
            return pending
        }
        observer?()
        recursiveLock.lock()
    }

    func unlock() {
        recursiveLock.unlock()
    }
}

/// One speech session's managers and the teardown that accounts for everything they queued.
///
/// The session owner's own suite and the audio-format suite both build the same pair and both have
/// to release it the same way, so the shape lives here rather than beside either of them.
@MainActor
extension MockURLProtocolTestCase {
    struct OwnedSpeechSession {
        /// The deferred automatic start this session's player was built with, kept alive beside it.
        let heldAutomaticPlayback: ManualAutomaticPlaybackScheduler
        let audioPlayer: AudioPlayerManager
        let networkManager: TTSNetworkManager
        let session: SpeechSessionCoordinator
    }

    /// The deferred automatic start, kept rather than run.
    ///
    /// These tests observe what a session routes, not what it plays. Under the production scheduler
    /// the 0.1-second prebuffer deadline outlives a test that only waited for its PCM to buffer,
    /// and it starts a real engine and a repeating progress timer that nothing in the test owns.
    /// Holding the action leaves this suite with no work scheduled beyond its own teardown.
    func makeOwnedSpeechSession(
        sampleRate: Double = AudioPlayerManager.defaultSampleRate,
        callbackAuthority: CallbackAuthorityLocking = RecursiveCallbackAuthority(),
        revocationTransactionObserver: @escaping @Sendable () -> Void = {},
        retryInstallationObserver: @escaping @Sendable () -> Void = {},
        engineStarter: @escaping (AVAudioEngine) throws -> Void = { try $0.start() }
    ) -> OwnedSpeechSession {
        let heldAutomaticPlayback = ManualAutomaticPlaybackScheduler()
        let audioPlayer = AudioPlayerManager(
            sampleRate: sampleRate,
            engineStarter: engineStarter,
            automaticPlaybackScheduler: heldAutomaticPlayback.schedule
        )
        let networkManager = TestNetworkFactory.makeManager(
            callbackAuthority: callbackAuthority,
            revocationTransactionObserver: revocationTransactionObserver,
            retryInstallationObserver: retryInstallationObserver
        )
        networkManager.updateSettings(
            baseURL: "https://mock.api/v1/audio/speech",
            apiKey: "test",
            model: "test",
            voice: "test",
            selectedProvider: "OpenAI"
        )
        return OwnedSpeechSession(
            heldAutomaticPlayback: heldAutomaticPlayback,
            audioPlayer: audioPlayer,
            networkManager: networkManager,
            session: SpeechSessionCoordinator(audioPlayer: audioPlayer, networkManager: networkManager)
        )
    }

    /// Releases the session and accounts for the work it queued, whatever the test asserted.
    ///
    /// Cancelling revokes the request and stops the player, so no delivery can still be authorized
    /// and no progress timer can survive. Draining both queues afterwards is what makes any client
    /// callback already in flight land inside the test that caused it.
    func finishSpeechSession(_ owned: OwnedSpeechSession) {
        owned.session.cancel()
        drainSpeechDelivery(of: owned.networkManager)
        drainSpeechMainQueueTurn()
    }

    func drainSpeechDelivery(of manager: TTSNetworkManager) {
        let drained = expectation(description: "Queued session callbacks have run")
        manager.audioDeliveryQueue.async { drained.fulfill() }
        wait(for: [drained], timeout: 2.0)
    }

    func drainSpeechMainQueueTurn() {
        let drained = expectation(description: "The main queue completed a turn")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2.0)
    }

    /// Starts a session whose request stays in flight until `releaseResponse`, and returns its task.
    ///
    /// No PCM is delivered, so nothing has taken callback authority by the time the caller arms a
    /// hook on it: the next acquisition is the one the test is there to observe.
    func startHeldRequest(_ owned: OwnedSpeechSession,
                          releasedBy releaseResponse: DispatchSemaphore,
                          file: StaticString = #filePath,
                          line: UInt = #line) -> URLSessionDataTask {
        let requestStarted = expectation(description: "The session's request reaches the provider")
        MockURLProtocol.installRequestHandler { request in
            requestStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 2.0)
            return (mockHTTPResponse(for: request, statusCode: 200), nil)
        }

        owned.session.start(text: "Speak me")
        wait(for: [requestStarted], timeout: 2.0)
        guard let task = owned.networkManager.activeTaskForTesting else {
            preconditionFailure("A started session must retain the task it began.")
        }
        return task
    }

    /// A session whose request is still in flight, and the observation reporting its buffered PCM.
    struct HeldSpeechSession {
        let audioBuffered: XCTestExpectation
        let observation: AnyCancellable
    }

    /// Starts a session whose request stays in flight, and reports when its PCM is buffered.
    ///
    /// The response is held until `releaseResponse` is signalled and its PCM is handed to the
    /// delegate by hand, so the session owns both halves — a running request and buffered audio —
    /// when the test changes the format. A response that had already completed would leave the
    /// request assertions passing for a reason the format change had nothing to do with.
    func startHeldSpeechSession(_ owned: OwnedSpeechSession, releasedBy releaseResponse: DispatchSemaphore) -> HeldSpeechSession {
        let requestStarted = expectation(description: "The session's request reaches the provider")
        MockURLProtocol.installRequestHandler { request in
            requestStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 2.0)
            return (mockHTTPResponse(for: request, statusCode: 200), nil)
        }
        let audioBuffered = expectation(description: "The session buffers PCM before the format changes")
        audioBuffered.assertForOverFulfill = false
        let observation = owned.audioPlayer.$hasAudio.sink { if $0 { audioBuffered.fulfill() } }
        let held = HeldSpeechSession(audioBuffered: audioBuffered, observation: observation)

        owned.session.start(text: "Speak me")
        wait(for: [requestStarted], timeout: 2.0)
        guard let task = owned.networkManager.activeTaskForTesting else {
            XCTFail("Expected the session to retain the task it started.")
            return held
        }
        owned.networkManager.urlSession(
            owned.networkManager.session,
            dataTask: task,
            didReceive: Data(repeating: 0, count: 2_048)
        )
        return held
    }

}
