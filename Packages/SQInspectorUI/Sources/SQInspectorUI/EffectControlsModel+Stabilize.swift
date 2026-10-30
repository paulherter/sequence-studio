import Foundation
import SQAnalysis
import SQCore

/// A Stabilize analysis in flight (the host runs it; one at a time).
public struct StabilizeRunState: Equatable, Sendable {
    public var clips: Set<Clip.ID>
    /// 0...1 over the whole run.
    public var progress: Double
    public init(clips: Set<Clip.ID>, progress: Double) { self.clips = clips; self.progress = progress }
}

/// What the Stabilizer's Analyze row shows.
public enum StabilizeRowStatus: Equatable, Sendable {
    case notAnalysed
    case analysing(Double)
    /// Running without a measurable share yet (starting, reading gyro data, smoothing): the text says which step.
    case working(String)
    case analysed
    /// Analyzed, but the clip now shows frames beyond the analyzed range; Start Again measures the whole range.
    case needsAnalysis
    /// The chosen method cannot run here (Gyroflow: no gyro data, engine not built); the reason is shown.
    case blocked(String)
    /// The last analysis failed (the reason is shown); Analyze tries again.
    case failed(String)

    public var isRunning: Bool {
        switch self {
        case .analysing, .working: true
        default: false
        }
    }
}

/// Stabilize as an effect (DECISIONS 2026-10-06): Method, then Analyze (progress + cancel), then the method's parameters.
extension EffectControlsModel {
    /// Method of every Stabilizer on the shown clip (the layout shows only that method's rows).
    public var stabilizerMethods: [ClipEffect.ID: StabilizerMethod] {
        Dictionary((clip?.effects ?? []).filter { $0.kind == ClipEffect.stabilizeKind }.map { ($0.id, $0.stabilizeMethod) },
                   uniquingKeysWith: { a, _ in a })
    }

    /// Why Gyroflow cannot stabilize the shown clip (nil = it can, or the host did not say).
    public var gyroflowBlock: String? { clip.flatMap { gyroflowBlockOf?($0) } }

    /// Gyroflow's engine reports only its steps (reading the gyro data until 0.6, then smoothing).
    static let gyroReadingText = "Reading gyro data…"
    static let gyroSmoothingText = "Smoothing the motion…"
    static let startingText = "Starting…"

    public func stabilizeStatus(_ effect: ClipEffect.ID) -> StabilizeRowStatus {
        guard let c = clip, let e = c.effects.first(where: { $0.id == effect }) else { return .notAnalysed }
        if e.stabilizeMethod == .gyroflow {
            // A picture analysis still running on this clip (started before the method changed) is not this method's.
            if let why = gyroflowBlock { return .blocked(why) }
            _ = gyroflowRevision        // the host bumps it when an analysis moved on (tracked via `observeStabilize`)
            switch gyroflowStateOf?(c, GyroflowOptions(effect: e)) ?? .idle {
            case .idle: return .notAnalysed
            case .analysing(let p): return .working(p < 0.6 ? Self.gyroReadingText : Self.gyroSmoothingText)
            case .ready: return .analysed
            case .failed(let why): return .failed(why)
            }
        }
        if let run = stabilizeRun, run.clips.contains(c.id) {
            // Before the first frame is measured (opening the file, waiting for another analysis) there is no share yet.
            return run.progress > 0 ? .analysing(run.progress) : .working(Self.startingText)
        }
        if e.stabilizeIsAnalysed { return stabilizeStaleOf?(c) == true ? .needsAnalysis : .analysed }
        return .notAnalysed
    }

    /// Everything the Analyze rows read that changes outside the clip: the view tracks this (a Gyroflow analysis only
    /// bumps `gyroflowRevision`; without tracking it the row stayed at its first state, the 2026-10-07 "0 %" bug).
    public func observeStabilize() {
        _ = stabilizeRun
        _ = gyroflowRevision
    }

    /// Analyze (or Cancel while the shown clip is analyzed). Nothing while the method is blocked.
    public func analyzeOrCancelStabilizer(_ effect: ClipEffect.ID) {
        guard let c = clip, let e = c.effects.first(where: { $0.id == effect }) else { return }
        let status = stabilizeStatus(effect)
        switch status {
        case .analysing, .working:
            if e.stabilizeMethod == .gyroflow {
                onGyroflowCancel?(c, GyroflowOptions(effect: e))
                gyroflowRevision &+= 1      // the row reads the engine again now
            } else {
                onStabilizeCancel?()
            }
        case .blocked: break
        case .notAnalysed, .analysed, .needsAnalysis, .failed:
            onStabilizeAnalyze?(c.id)
            if e.stabilizeMethod == .gyroflow { gyroflowRevision &+= 1 }   // shows the started analysis at once
        }
    }

    /// Choice items shown but not selectable (index -> reason): Gyroflow while it cannot run on the shown clip.
    public func disabledChoices(_ p: EffectProperty) -> [Int: String] {
        guard case .fx(_, let kind, let key) = p, kind == ClipEffect.stabilizeKind, key == ClipEffect.stabilizeMethodKey,
              let why = gyroflowBlock else { return [:] }
        return [StabilizerMethod.gyroflow.rawValue: why]
    }
}
