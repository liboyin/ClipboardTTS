import Foundation

/// Owns the menu's pending deferred clipboard action so only its newest attempt can execute.
///
/// The menu defers its clipboard read so the dropdown can close first, and anything may claim the
/// playback pipeline inside that window: a Services request, or a second Speak click that queued
/// its own action. An attempt that a later attempt superseded must therefore never reach its
/// action, otherwise one burst of clicks would read the clipboard and request speech more than
/// once. The caller stays responsible for revalidating pipeline readiness inside the action, which
/// this type deliberately knows nothing about.
///
/// One instance must live for the app's lifetime: a per-view instance cannot see the attempt an
/// earlier view value scheduled, which is exactly the case the token exists to drop.
///
/// State is confined to the main queue. `MenuBarView` schedules from a SwiftUI button action and
/// the production scheduler runs the deferred action back on the main queue; a test scheduler must
/// preserve that confinement.
final class DeferredClipboardAction: ObservableObject {
    /// Runs the supplied action after the delay, standing in for the main queue in tests.
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> Void

    /// Carries a main-queue-confined action across `asyncAfter`'s `@Sendable` requirement.
    ///
    /// Unchecked because the confinement, not the action's type, is what makes this safe: the menu
    /// creates the action on the main queue and this scheduler runs it only there, so no second
    /// thread ever touches what it captured.
    private struct MainQueueDeferredAction: @unchecked Sendable {
        let run: () -> Void
    }

    private let scheduler: Scheduler
    /// Identifies the most recently scheduled attempt; every older attempt is stale.
    private var latestAttempt: UInt64 = 0

    /// Creates the production owner, which defers each action to the main queue.
    convenience init() {
        self.init(scheduler: { delay, action in
            let deferred = MainQueueDeferredAction(run: action)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { deferred.run() }
        })
    }

    init(scheduler: @escaping Scheduler) {
        self.scheduler = scheduler
    }

    /// Defers `action` by `delay`, dropping it if another attempt is scheduled before it runs.
    func schedule(after delay: TimeInterval, perform action: @escaping () -> Void) {
        latestAttempt &+= 1
        let attempt = latestAttempt
        scheduler(delay) { [weak self] in
            guard let self, self.latestAttempt == attempt else { return }
            action()
        }
    }
}
