import Synchronization

/// A closure that may be replaced and called from any thread.
///
/// Do not keep a closure in `Mutex<(@Sendable () -> Void)?>` and read it with `withLock { $0 }`: the generic lock stores
/// closures in their most general form, so every read converts the value to the concrete form and writes it back
/// wrapped in another thunk. The chain grows by two thunks per call, and after ~8k calls the call itself overflows
/// the stack. Here the closure lives in a plain struct field, which never gets converted.
public final class CallbackSlot: Sendable {
    private struct Box: Sendable { let call: @Sendable () -> Void }
    private let box = Mutex<Box?>(nil)

    public init() {}

    public func set(_ f: (@Sendable () -> Void)?) { box.withLock { $0 = f.map(Box.init) } }

    /// Calls the current closure outside the lock; does nothing when none is set.
    public func call() { box.withLock { $0 }?.call() }

    /// Removes and returns the closure (one-shot use).
    public func take() -> (@Sendable () -> Void)? { box.withLock { b in let o = b; b = nil; return o }?.call }
}
