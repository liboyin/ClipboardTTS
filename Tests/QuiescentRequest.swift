import Foundation
import XCTest

/// What `sendOneRoutedRequestLeavingNoCompletion` accepts as a routed configuration, and the
/// observation points its own tests use.
enum RoutedRequest {
    /// The failure the helper records, in place of sending anything, for a configuration that is not routed.
    static let unroutedConfigurationFailure =
        "Refused to send: the configuration's first protocol class must be a test-owned protocol that claims the request."

    /// Whether a session built from `configuration` would offer `request` first to a test-owned
    /// protocol that claims it.
    ///
    /// WHY: installing protocol classes does not remove the system's own loaders, so a request the
    /// first class declines falls through to them, and a configuration that starts with one of them
    /// is not routed at all. The system's classes are those of a fresh ephemeral configuration,
    /// compared by identity before `canInit(with:)` is asked, so no system protocol is consulted.
    static func isRouted(_ request: URLRequest, through configuration: URLSessionConfiguration) -> Bool {
        guard let first = configuration.protocolClasses?.first as? URLProtocol.Type else { return false }
        let systemProtocols = (URLSessionConfiguration.ephemeral.protocolClasses ?? []).map(ObjectIdentifier.init)
        return !systemProtocols.contains(ObjectIdentifier(first)) && first.canInit(with: request)
    }

    /// Test-only observation points of `sendOneRoutedRequestLeavingNoCompletion`, for the tests
    /// that prove its guarantees; every other caller omits them.
    struct Observer {
        /// Runs on the calling thread once the helper has built its session, before any task
        /// exists. A test may suspend the session's delegate queue here to hold every delivery.
        var sessionCreated: (URLSession) -> Void = { _ in }
        /// Runs on the session's delegate queue in every completion, once the gate has decided
        /// whether the completion records its outcome and before it fulfils the expectation.
        var completionDecided: @Sendable (_ recorded: Bool) -> Void = { _ in }
        /// Runs on the calling thread once the task has started and before the bounded wait begins,
        /// so a test can make sure its completion is already in flight when that wait starts.
        var beforeWait: () -> Void = {}
    }
}

extension XCTestCase {
    /// Sends one request through a session built from `configuration`, waits up to `timeout` for it
    /// to complete, and returns the error it completed with: nil if it succeeded, or if it had not
    /// started completing by the barrier below; an expired wait records a failure of its own. Once
    /// it returns, no completion of that request can write the outcome or fulfil the expectation.
    ///
    /// It sends nothing, creating no session or task, and records
    /// `RoutedRequest.unroutedConfigurationFailure` when `configuration` is not routed
    /// (`RoutedRequest.isRouted`): this session is not one `TestNetworkFactory` built, so nothing
    /// else keeps its request on the machine.
    ///
    /// WHY: a test that sends a request is calling code that answers on another queue, so it must
    /// own that queue and establish quiescence after its bounded wait whatever the wait's outcome.
    /// Only a session's creator chooses the queue its completion runs on, so this builds a session
    /// of its own rather than borrowing the caller's; the configuration carries the caller's routing.
    func sendOneRoutedRequestLeavingNoCompletion(_ request: URLRequest,
                                                 configuration: URLSessionConfiguration,
                                                 description: String,
                                                 timeout: TimeInterval,
                                                 observer: RoutedRequest.Observer = .init()) -> Error? {
        guard RoutedRequest.isRouted(request, through: configuration) else {
            XCTFail("\(RoutedRequest.unroutedConfigurationFailure) (\(description))")
            return nil
        }
        let completion = expectation(description: description)
        let callbackQueue = DispatchQueue(label: "com.clipboardtts.tests.quiescentrequest")
        let delegateQueue = OperationQueue()
        delegateQueue.underlyingQueue = callbackQueue
        delegateQueue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: nil, delegateQueue: delegateQueue)
        observer.sessionCreated(session)
        let completionDecided = observer.completionDecided
        let state = LockedValue<(isOpen: Bool, error: Error?)>((isOpen: true, error: nil))
        session.dataTask(with: request) { _, _, error in
            let recorded = state.withValue { state in
                guard state.isOpen else { return false }
                state.error = error
                return true
            }
            completionDecided(recorded)
            if recorded { completion.fulfill() }
        }.resume()
        observer.beforeWait()
        wait(for: [completion], timeout: timeout)
        session.invalidateAndCancel()
        // WHY: fulfilment is not quiescence. An expired wait leaves the completion runnable, and
        // cancelling its task delivers it later still, after a barrier issued at once. Every
        // completion runs on `callbackQueue`, so this barrier waits out one already running and
        // closes the gate on any yet to start, which then neither writes the outcome nor fulfils
        // the expectation after this returns.
        return callbackQueue.sync {
            state.withValue { state in
                state.isOpen = false
                return state.error
            }
        }
    }
}
