import Foundation

/// Synchronizes callback delivery authority with generation revocation.
protocol CallbackAuthorityLocking: AnyObject {
    /// Acquires callback authority for either delivery or revocation.
    func lock()

    /// Releases previously acquired callback authority.
    func unlock()
}

/// Production callback-authority lock that permits a handler to revoke its own stream directly.
final class RecursiveCallbackAuthority: CallbackAuthorityLocking, @unchecked Sendable {
    private let recursiveLock = NSRecursiveLock()

    func lock() {
        recursiveLock.lock()
    }

    func unlock() {
        recursiveLock.unlock()
    }
}
