import Foundation
import SQAnalysis
import SQCore

/// The Stabilizer's Analyze row in Effect Controls (shared window): analyzes chosen clips, queues a second request while a run
/// goes, and re-plans from the cached analysis when an option changed (the AppKit window does the same in
/// App/Sources/AppController+Stabilize).
/// shortcut: no Gyroflow method and no automatic re-analysis of trimmed clips here; upgrade with a portable Gyroflow engine.
extension AnalysisFlows {
    /// The cached analysis a re-plan reads (no new Stabilize run).
    public static let stabilizationLookup: EditorSession.StabilizationLookup = { media, range, w, h in
        #if os(macOS)
        await Task.detached(priority: .userInitiated) {
            StabilizationCache().cached(url: URL(fileURLWithPath: media.path), range: range, pictureWidth: w, pictureHeight: h)
        }.value
        #else
        nil // shortcut: StabilizationCache is Apple-only (Vision analyzer); upgrade with a portable analyzer.
        #endif
    }

    /// Analyzes these clips' Standard Stabilizers. While another run goes they wait in the session's queue and follow when it
    /// ends. Progress goes to `onStabilizeProgress`.
    public func analyzeStabilizers(_ ids: Set<Clip.ID>, in timeline: Timeline.ID? = nil) {
        let tid = timeline ?? session.activeTimelineID
        if stabilizeJob.isRunning { session.queueStabilizerAnalysis(ids, in: tid); return }
        guard let backend, backend.offersStabilize else { ui.flash(Self.unavailable("Stabilize"), 5); return }
        let ui = ui, shown = ids
        ui.setJob("Stabilize: analyzing…")
        onStabilizeProgress?(shown, 0)
        stabilizeJob.start({ [weak self] progress in
            guard let self else { throw CancellationError() }
            return try await session.stabilize(only: ids, in: tid, progress: progress) { backend.stabilizationAnalyzer(for: $0) }
        }, progress: { [weak self] p in
            self?.onStabilizeProgress?(shown, p)
            ui.setJob("Stabilize: analyzing… \(Int((p * 100).rounded())) %")
        }, ended: { [weak self] ending in
            ui.setJob(nil)
            self?.onStabilizeProgress?(shown, nil)
            switch ending {
            case .done(let out): ui.flash(Self.stabilizeMessage(out), 5)
            case .cancelled: ui.flash("Stabilize canceled.", 3)
            case .failed(let why): ui.flash(SQL10n.format("Stabilize failed: %@", why), 8)
            }
            guard let self else { return }
            if case .cancelled = ending { session.dropQueuedStabilizerAnalysis(); return }
            if case .failed = ending { session.withdrawRollingShutterRequests(clips: shown) }
            if let next = session.takeNextQueuedStabilizerAnalysis() { analyzeStabilizers(next.clips, in: next.timeline) }
        })
    }

    public func cancelStabilizerRun() { stabilizeJob.cancel() }
}
