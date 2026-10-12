import Foundation
import XCTest

extension XCTestCase {
    /// Sends one request through a session built from `configuration`, waits up to `timeout` for it
    /// to complete, and returns the error it completed with: nil if it succeeded, or if it had not
    /// started completing by the barrier below; an expired wait records a failure of its own.
    ///
    /// WHY: a test that sends a request is calling code that answers on another queue, so it must
    /// own that queue and establish quiescence after its bounded wait whatever the wait's outcome.
    /// Only a session's creator chooses the queue its completion runs on, so this builds a session
    /// of its own rather than borrowing the caller's; the configuration carries the caller's routing.
    func completionError(of request: URLRequest,
                         configuration: URLSessionConfiguration,
                         description: String,
                         timeout: TimeInterval) -> Error? {
        let completion = expectation(description: description)
        let callbackQueue = DispatchQueue(label: "com.clipboardtts.tests.quiescentrequest")
        let delegateQueue = OperationQueue()
        delegateQueue.underlyingQueue = callbackQueue
        delegateQueue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: nil, delegateQueue: delegateQueue)
        let state = LockedValue<(isOpen: Bool, error: Error?)>((isOpen: true, error: nil))
        session.dataTask(with: request) { _, _, error in
            let recorded = state.withValue { state in
                guard state.isOpen else { return false }
                state.error = error
                return true
            }
            if recorded { completion.fulfill() }
        }.resume()
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
