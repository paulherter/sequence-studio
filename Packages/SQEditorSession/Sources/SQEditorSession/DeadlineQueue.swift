import Foundation
import Synchronization

/// A serial queue whose every job is answered by a deadline: the caller goes on with nil when its job has not finished
/// (or not even started, behind a job that hangs) in time, and the late result is dropped. While a job is overdue the
/// queue is `stuck`: new jobs are answered with nil at once instead of lining up behind it, until the overdue job comes
/// back. `restart` (a click) moves on to a fresh queue instead, so one call that never returns cannot switch the queue
/// off for the rest of the app run; it costs the one thread that call holds.
final class DeadlineQueue: Sendable {
    private struct State {
        var queue: DispatchQueue
        var generation = 0
        /// Jobs of this generation that passed their deadline and have not come back.
        var overdue = 0
    }

    private final class Once: Sendable {
        private let taken = Mutex(false)
        /// True for the first caller only.
        func take() -> Bool { taken.withLock { t in defer { t = true }; return !t } }
    }

    private let label: String
    private let state: Mutex<State>

    init(label: String) {
        self.label = label
        state = Mutex(State(queue: DispatchQueue(label: label, qos: .userInitiated)))
    }

    var isStuck: Bool { state.withLock { $0.overdue > 0 } }

    /// Runs `work` on the queue and returns its result, or nil when `deadline` seconds passed first or the queue is stuck.
    public func run<T: Sendable>(deadline: Double, restart: Bool = false, _ work: @escaping @Sendable () -> T?) async -> T? {
        let name = label
        let slot: (queue: DispatchQueue, generation: Int)? = state.withLock { s in
            if s.overdue > 0 {
                guard restart else { return nil }
                s.generation += 1
                s.overdue = 0
                s.queue = DispatchQueue(label: name, qos: .userInitiated)
                NSLog("[Magic] %@: a job never came back, going on with a fresh queue", name)
            }
            return (s.queue, s.generation)
        }
        guard let slot else { return nil }
        let once = Once()
        return await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
            slot.queue.async { [self] in
                let r = work()
                if once.take() { c.resume(returning: r); return }
                // Answered after its deadline: the queue works again.
                state.withLock { if $0.generation == slot.generation { $0.overdue = max($0.overdue - 1, 0) } }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + deadline) { [self] in
                guard once.take() else { return }
                state.withLock { if $0.generation == slot.generation { $0.overdue += 1 } }
                NSLog("[Magic] %@: no answer within %.1f s, given up", name, deadline)
                c.resume(returning: nil)
            }
        }
    }
}
