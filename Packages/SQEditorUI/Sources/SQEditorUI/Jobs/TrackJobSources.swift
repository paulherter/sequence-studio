import Foundation
import SQAnalysis
import SQCore

/// The running mask track (path or Magic) as a background job: progress from `MaskTrackActivity`, Cancel stops it.
@MainActor
public final class MaskTrackJobSource: BackgroundJobSource {
    private let activity: MaskTrackActivity
    private let cancel: @MainActor @Sendable () -> Void
    public init(activity: MaskTrackActivity = .shared, cancel: @escaping @MainActor @Sendable () -> Void) {
        self.activity = activity; self.cancel = cancel
    }

    public func currentJobs() async -> [BackgroundJob] {
        guard let r = activity.run else { return [] }
        return [BackgroundJob(id: "mask-track", kind: .other, title: SQL10n.string(r.forward ? "Tracking mask forward" : "Tracking mask backward"),
                              progress: r.percent < 0 ? nil : Double(r.percent) / 100, cancel: cancel)]
    }
}

/// The running Stabilizer analysis as a background job: progress from `EffectControlsModel.stabilizeRun`.
@MainActor
public final class StabilizeJobSource: BackgroundJobSource {
    private weak var model: EffectControlsModel?
    public init(model: EffectControlsModel) { self.model = model }

    public func currentJobs() async -> [BackgroundJob] {
        guard let m = model, let r = m.stabilizeRun else { return [] }
        let n = r.clips.count
        return [BackgroundJob(id: "stabilize", kind: .other, title: SQL10n.plural(n, one: "Analyzing for Stabilizer", other: "Analyzing %@ clips for Stabilizer"),
                              progress: r.progress, cancel: { [weak m] in m?.onStabilizeCancel?() })]
    }
}

/// Running Gyroflow analyses (one job per file and options): progress from the engine, Cancel stops that analysis.
@MainActor
public final class GyroflowJobSource: BackgroundJobSource {
    private let engine: any GyroStabilizationEngine
    private let cancel: @MainActor @Sendable (GyroRunningAnalysis) -> Void
    public init(engine: any GyroStabilizationEngine, cancel: @escaping @MainActor @Sendable (GyroRunningAnalysis) -> Void) {
        self.engine = engine; self.cancel = cancel
    }

    public func currentJobs() async -> [BackgroundJob] {
        let cancel = cancel
        return engine.runningAnalyses().map { r in
            let name = URL(fileURLWithPath: r.path).lastPathComponent
            return BackgroundJob(id: "gyroflow-\(r.path)-\(r.options.hashValue)", kind: .other,
                                 title: SQL10n.format("Gyroflow analysis: %@", name), progress: r.progress, cancel: { cancel(r) })
        }
    }
}
