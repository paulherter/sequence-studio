import Foundation
import Synchronization

/// Runs blocking, long work (a synchronous media read loop) off Swift's cooperative thread pool, at most `width` jobs at
/// a time. The pool has one thread per core: a few blocking jobs on it starve every other `await` in the app (2026-10-03:
/// waveform builds of 10+ long clips froze the second Premiere import, and can deadlock media readers that need the pool).
/// Waiting for a free slot suspends instead of blocking a thread.
public final class BlockingLane: Sendable {
    /// Waveform peaks and similar whole-file reads; 2 (fewer on <= 3 cores, 3 on 16+ core Macs; `WorkLimits.waveformReads`).
    public static let media = BlockingLane(label: "sq.lane.media", width: WorkLimits.current.waveformReads)
    /// Picture analyzes (Stabilizer); `WorkLimits.pictureAnalyzes` wide.
    public static let analysis = BlockingLane(label: "sq.lane.analysis", width: WorkLimits.current.pictureAnalyses)

    private let queue: DispatchQueue
    private let slots: Mutex<Slots>

    private struct Slots: ~Copyable {
        var free: Int
        var waiters: [Waiter] = []
    /// Urgent waiters are served before every normal one (in their own arrival order).
        var urgent: [Waiter] = []
        var nextID: UInt64 = 0
    }

    /// A job waiting for a slot; resumed with true when it got one, false when it was canceled while waiting.
    private struct Waiter { let id: UInt64; let resume: CheckedContinuation<Bool, Never> }

    /// Jobs started while this is true go ahead of every waiting normal job (what the user is looking at right now,
    /// e.g. the Source monitor's audio view, should not wait behind a whole import's waveforms).
    @TaskLocal public static var urgent = false

    /// Jobs waiting for a slot (tests).
    var waitingCount: Int { slots.withLock { $0.waiters.count + $0.urgent.count } }

    public init(label: String, width: Int, qos: DispatchQoS = .utility) {
        precondition(width > 0)
        queue = DispatchQueue(label: label, qos: qos, attributes: .concurrent)
        slots = Mutex(Slots(free: width))
    }

    /// Runs `body` on the lane's own threads. `body` gets an `isCanceled` check (the calling task's cancellation);
    /// a job canceled before it started throws `CancellationError` without running.
    public func run<T: Sendable>(_ body: @escaping @Sendable (_ isCancelled: @escaping @Sendable () -> Bool) throws -> T) async throws -> T {
        let cancelled = Atomic(false)
        let id = slots.withLock { s -> UInt64 in s.nextID &+= 1; return s.nextID }
        return try await withTaskCancellationHandler {
            // A job canceled while it waits for a slot ends at once (Cancel must not wait for the busy job).
            guard await acquire(id: id, isCancelled: { cancelled.load(ordering: .relaxed) }) else { throw CancellationError() }
            defer { release() }
            if cancelled.load(ordering: .relaxed) || Task.isCancelled { throw CancellationError() }
            return try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
                queue.async {
                    c.resume(with: Result { try body { cancelled.load(ordering: .relaxed) } })
                }
            }
        } onCancel: {
            cancelled.store(true, ordering: .relaxed)
            let waiter = slots.withLock { s -> Waiter? in
                if let i = s.waiters.firstIndex(where: { $0.id == id }) { return s.waiters.remove(at: i) }
                if let i = s.urgent.firstIndex(where: { $0.id == id }) { return s.urgent.remove(at: i) }
                return nil
            }
            waiter?.resume.resume(returning: false)
        }
    }

    /// The job gave no sign of life for its deadline (`run(stallAfter:)`).
    public struct Stalled: Error, Equatable, LocalizedError {
        public init() {}
        /// Its own wording: a hung read is not an unreadable file (the file may be fine, the decoder did not answer).
        public var errorDescription: String? { "The read stopped answering and was given up." }
    }

    /// Like `run`, for work that calls `beat` as it goes (once per frame): a job without a beat for `stallAfter` seconds
    /// counts as hung (a system call that never returns; a thread cannot be killed). The caller then gets `Stalled`
    /// and the slot goes to the next job; the thread stays with its call, `isCancelled` is true for it and whatever
    /// it returns later is dropped. So a call that hangs costs one thread, never a slot of the lane. The time waiting
    /// for a slot does not count, a sleeping Mac neither.
    public func run<T: Sendable>(stallAfter: Double,
                                 _ body: @escaping @Sendable (_ isCancelled: @escaping @Sendable () -> Bool,
                                                              _ beat: @escaping @Sendable () -> Void) throws -> T) async throws -> T {
        let cancelled = Atomic(false)
        let id = slots.withLock { s -> UInt64 in s.nextID &+= 1; return s.nextID }
        return try await withTaskCancellationHandler {
            guard await acquire(id: id, isCancelled: { cancelled.load(ordering: .relaxed) }) else { throw CancellationError() }
            defer { release() }
            if cancelled.load(ordering: .relaxed) || Task.isCancelled { throw CancellationError() }
            let watch = StallWatch<T>(limit: stallAfter)
            return try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
                watch.begin(c)
                queue.async {
                    watch.beat()
                    watch.finish(Result { try body({ cancelled.load(ordering: .relaxed) }, { watch.beat() }) })
                }
                watch.arm { cancelled.store(true, ordering: .relaxed) }
            }
        } onCancel: {
            cancelled.store(true, ordering: .relaxed)
            let waiter = slots.withLock { s -> Waiter? in
                if let i = s.waiters.firstIndex(where: { $0.id == id }) { return s.waiters.remove(at: i) }
                if let i = s.urgent.firstIndex(where: { $0.id == id }) { return s.urgent.remove(at: i) }
                return nil
            }
            waiter?.resume.resume(returning: false)
        }
    }

    /// Waits for a slot. False = canceled while waiting (no slot taken).
    private func acquire(id: UInt64, isCancelled: () -> Bool) async -> Bool {
        let urgent = Self.urgent
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            let go = slots.withLock { s -> Bool? in
                // The cancel handler sets the flag before it takes the lock: either it is seen here, or the waiter is
                // already queued and the handler removes it.
                if isCancelled() { return false }
                if s.free > 0 { s.free -= 1; return true }
                let w = Waiter(id: id, resume: c)
                if urgent { s.urgent.append(w) } else { s.waiters.append(w) }
                return nil
            }
            if let go { c.resume(returning: go) }
        }
    }

    private func release() {
        let next = slots.withLock { s -> Waiter? in
            if !s.urgent.isEmpty { return s.urgent.removeFirst() }
            if s.waiters.isEmpty { s.free += 1; return nil }
            return s.waiters.removeFirst()
        }
        next?.resume.resume(returning: true)
    }
}

/// The deadline of one `BlockingLane.run(stallAfter:)` job: whoever comes first, the job's result or the missing beat,
/// answers the caller.
private final class StallWatch<T: Sendable>: Sendable {
    private struct State {
        var last = DispatchTime.now().uptimeNanoseconds
        var waiting: CheckedContinuation<T, Error>?
    }
    private let state = Mutex(State())
    private let limit: Double

    init(limit: Double) { self.limit = max(limit, 0.001) }

    func begin(_ c: CheckedContinuation<T, Error>) { state.withLock { $0.waiting = c; $0.last = DispatchTime.now().uptimeNanoseconds } }
    func beat() { state.withLock { $0.last = DispatchTime.now().uptimeNanoseconds } }

    func finish(_ r: Result<T, Error>) {
        let c = state.withLock { s in defer { s.waiting = nil }; return s.waiting }
        c?.resume(with: r)
    }

    /// Looks every quarter of the limit until the job answered or is given up (`onStall` runs first then).
    func arm(onStall: @escaping @Sendable () -> Void) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + limit / 4) { [self] in
            let now = DispatchTime.now().uptimeNanoseconds
            let (c, done) = state.withLock { s -> (CheckedContinuation<T, Error>?, Bool) in
                guard s.waiting != nil else { return (nil, true) }
                guard now > s.last, Double(now - s.last) / 1e9 >= limit else { return (nil, false) }
                defer { s.waiting = nil }
                return (s.waiting, true)
            }
            if let c { onStall(); c.resume(throwing: BlockingLane.Stalled()) }
            if !done { arm(onStall: onStall) }
        }
    }
}
