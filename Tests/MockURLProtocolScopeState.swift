import Foundation

// What one `MockURLProtocol` test scope owns, and the rule that decides when it has finished
// everything it owed. `MockURLProtocolScope.swift` owns the storage that holds these values and
// every operation that mutates them; this file is only the shape of a scope, split out under the
// repository's file-length rule. These types are internal rather than file-private solely because
// that split crosses a file boundary.

/// Everything one test scope owns while it is open, plus the accounting its shutdown reads.
struct TestState: Sendable {
    var requestHandler: MockURLProtocol.RequestHandler?
    var expectedUnhandledRequestCount = 0
    var unhandledRequestCount = 0
    var activeLoadCount = 0
    var activeManagerConstructionCount = 0
    var audioDeliveryScopes: [AudioDeliveryScope] = []
    var hasStartedAudioDeliveryRelease = false
    var hasReleasedAudioDelivery = false
    var hasRevokedAudioDelivery = false
    var pendingAudioDeliveryDrainCount = 0
    var hasScheduledAudioDeliveryDrains = false
    var isClosing = false
    var sessionRegistrations: [SessionRegistration] = []
}

struct SessionRegistration: Sendable {
    let session: URLSession
    /// Retained only to keep a session's delegate alive for as long as its registration; nothing
    /// reads it back, so `any Sendable` is enough to carry it across the threads that tear a scope
    /// down.
    let delegate: (any Sendable)?
}

struct AudioDeliveryScope: Sendable {
    let queue: DispatchQueue
    let releasePendingDelivery: @Sendable () -> Void
    let finishRevocation: @Sendable () -> Void
}

/// Every scope the process currently has open, plus which one new work joins by default.
struct ScopeRegistry: Sendable {
    var testStates: [String: TestState] = [:]
    var activeTestIdentifier: String?
}

/// Returns whether a closing scope has finished every shutdown step it owes.
func isQuiescent(_ state: TestState) -> Bool {
    !hasUndrainedSessionWork(state) &&
        state.hasRevokedAudioDelivery &&
        state.hasScheduledAudioDeliveryDrains &&
        state.pendingAudioDeliveryDrainCount == 0
}

/// Returns whether session, protocol-load, or manager-initialization work can still enqueue delivery.
func hasUndrainedSessionWork(_ state: TestState) -> Bool {
    state.activeLoadCount > 0 ||
        state.activeManagerConstructionCount > 0 ||
        !state.sessionRegistrations.isEmpty
}
