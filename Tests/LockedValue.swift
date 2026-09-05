import Foundation
import os

/// Test-owned state that a callback on another thread writes and the test body reads.
///
/// The suite's established shape for this is an `NSLock` declared beside a `var`. That is correct,
/// but a manual lock is invisible to strict concurrency: the compiler sees only a mutable variable
/// captured by a `@Sendable` closure and cannot tell a guarded write from a race. Holding the value
/// *inside* the lock makes the same ownership checked rather than asserted, which is why this type
/// replaces that pair rather than wrapping it.
///
/// `withValue` is the only way in, so a read-modify-write a caller must not interleave — a counter
/// whose new total decides what the callback does next — stays one critical section instead of two.
final class LockedValue<Value: Sendable>: Sendable {
    private let storage: OSAllocatedUnfairLock<Value>

    init(_ initialValue: Value) {
        storage = OSAllocatedUnfairLock(initialState: initialValue)
    }

    /// The current value. Use `withValue` instead when the next value depends on this one.
    var value: Value {
        storage.withLock { $0 }
    }

    /// Runs `body` against the value under the lock and returns whatever it produces.
    @discardableResult
    func withValue<Result: Sendable>(_ body: @Sendable (inout Value) -> Result) -> Result {
        storage.withLock(body)
    }
}
