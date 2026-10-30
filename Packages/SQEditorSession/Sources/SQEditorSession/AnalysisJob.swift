import Foundation
import SQUIKit

/// How a background analysis run (Stabilize, Auto Reframe) ended. Reported exactly once per run.
public enum AnalysisJobEnding<Outcome: Sendable>: Sendable {
    case done(Outcome)
    /// Cancel was pressed: reported at once, whatever the work still does (its result is dropped).
    case cancelled
    /// The work threw something other than `CancellationError`: the message to show.
    case failed(String)
}

/// One background analysis at a time, with the UI-facing lifecycle the Stabilizer bug (2026-10-07) lacked: Cancel ends
/// the run for the UI immediately (even when the work only notices cancellation later), a late result or progress tick
/// of a canceled run never reaches a newer run, failures are reported as failures (not "canceled"), and progress is
/// passed on only when the whole percent changes (each tick refreshes Effect Controls).
@MainActor public final class AnalysisJob<Outcome: Sendable> {
    public typealias Work = @MainActor (_ progress: @escaping @Sendable (Double) -> Void) async throws -> Outcome

    private var task: Task<Void, Never>?
    private var generation = 0
    private var lastPercent = -1
    private var progressHandler: (@MainActor (Double) -> Void)?
    private var endHandler: (@MainActor (AnalysisJobEnding<Outcome>) -> Void)?

    public init() {}

    public var isRunning: Bool { task != nil }

    /// Starts `work`. False (nothing started) while a run is going. `progress` gets 0...1 on the main actor (whole
    /// percent steps); `ended` is called once.
    @discardableResult
    public func start(_ work: @escaping Work, progress: @escaping @MainActor (Double) -> Void,
                      ended: @escaping @MainActor (AnalysisJobEnding<Outcome>) -> Void) -> Bool {
        guard task == nil else { return false }
        generation &+= 1
        let g = generation
        lastPercent = -1
        progressHandler = progress
        endHandler = ended
        let report: @Sendable (Double) -> Void = { [weak self] p in
            Task { @MainActor [weak self] in self?.tick(p, generation: g) }
        }
        task = Task { @MainActor [weak self] in
            let ending: AnalysisJobEnding<Outcome>
            do {
                ending = .done(try await work(report))
            } catch is CancellationError {
                ending = .cancelled
            } catch {
                ending = .failed(Self.message(for: error))
            }
            self?.end(ending, generation: g)
        }
        return true
    }

    /// Cancels the running work and reports `.canceled` now. No-op when idle.
    public func cancel() {
        guard let t = task else { return }
        t.cancel()
        end(.cancelled, generation: generation)
    }

    private func tick(_ p: Double, generation g: Int) {
        guard g == generation, task != nil else { return }
        let pct = Int((min(max(p, 0), 1) * 100).rounded(.down))
        guard pct != lastPercent else { return }
        lastPercent = pct
        progressHandler?(Double(pct) / 100)
    }

    private func end(_ ending: AnalysisJobEnding<Outcome>, generation g: Int) {
        guard g == generation, task != nil else { return }     // a canceled run's late end
        task = nil
        generation &+= 1
        let ended = endHandler
        progressHandler = nil
        endHandler = nil
        ended?(ending)
    }

    public static func message(for error: any Error) -> String {
        let text = SQL10n.errorText(error)
        return text.isEmpty ? SQL10n.string("Unknown error.") : text
    }
}
