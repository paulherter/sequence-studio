import Foundation
import Synchronization

/// One analysis at a time, first come first served: a holder runs its whole job, the next one waits suspended (no thread).
/// A WebM analysis hands the lane one frame per job; two of them on a 1-wide lane (`WorkLimits.pictureAnalyses`) would
/// alternate frame by frame, both decoders and both frame states alive, both finishing late. Holding the turn for the whole
/// analysis makes the second one start when the first is done, as two native analyses do (one lane job each).
final class AnalysisTurn: Sendable {
    private struct Waiter { let id: UInt64; let resume: CheckedContinuation<Bool, Never> }
    private struct State { var held = false; var waiters: [Waiter] = []; var nextID: UInt64 = 0 }
    private let state = Mutex(State())

    /// Jobs waiting for the turn (tests).
    var waitingCount: Int { state.withLock { $0.waiters.count } }

    /// Waits for the turn, runs `body`, passes the turn on. Canceled while waiting: throws `CancellationError`, nothing ran.
    func run<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        let id = state.withLock { s -> UInt64 in s.nextID &+= 1; return s.nextID }
        let got = await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                let now = state.withLock { s -> Bool? in
                    if Task.isCancelled { return false }
                    if !s.held { s.held = true; return true }
                    s.waiters.append(Waiter(id: id, resume: c))
                    return nil
                }
                if let now { c.resume(returning: now) }
            }
        } onCancel: {
            let w = state.withLock { s -> Waiter? in
                s.waiters.firstIndex { $0.id == id }.map { s.waiters.remove(at: $0) }
            }
            w?.resume.resume(returning: false)
        }
        guard got else { throw CancellationError() }
        defer { pass() }
        return try await body()
    }

    private func pass() {
        let next = state.withLock { s -> Waiter? in
            if s.waiters.isEmpty { s.held = false; return nil }
            return s.waiters.removeFirst()      // the turn stays held, now by that waiter
        }
        next?.resume.resume(returning: true)
    }
}
