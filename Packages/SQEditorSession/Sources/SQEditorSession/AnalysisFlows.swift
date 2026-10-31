import Foundation
import SQAnalysis
import SQCore
import SQUIKit

/// What a platform offers for the background analysis commands (Find Scene Changes, Auto Reframe, Stabilize). The Mac
/// implements all three with AVFoundation + Vision (App/Sources/MacAnalysisBackend); Windows implements what it can
/// (scene changes through FFmpeg). A nil answer means "this platform cannot": the command says so in the status line.
public protocol AnalysisBackend: Sendable {
    /// Media-time shot changes of `url` inside `range` (cancel with the task); nil = this platform has no scene detector.
    func sceneChanges(url: URL, range: TimeRange, progress: @escaping @Sendable (Double) -> Void) async throws -> [Time]?
    /// Whether `subjectDetector` / `stabilizationAnalyzer` work here (checked before the command asks anything).
    var offersReframe: Bool { get }
    var offersStabilize: Bool { get }
    /// The subject finder for Auto Reframe; nil = not available.
    func subjectDetector(for media: MediaRef) -> (any SubjectDetecting)?
    /// The camera-shake analyzer for Stabilize; nil = not available.
    func stabilizationAnalyzer(for media: MediaRef) -> (any StabilizationAnalyzing)?
}

extension AnalysisBackend {
    public var offersReframe: Bool { false }
    public var offersStabilize: Bool { false }
    public func sceneChanges(url: URL, range: TimeRange, progress: @escaping @Sendable (Double) -> Void) async throws -> [Time]? { nil }
    public func subjectDetector(for media: MediaRef) -> (any SubjectDetecting)? { nil }
    public func stabilizationAnalyzer(for media: MediaRef) -> (any StabilizationAnalyzing)? { nil }
}

/// The status line a host shows for a running analysis.
public struct AnalysisFlowUI {
    /// The running job's line ("Find Scene Changes: reading 3 clips… 42 %"); nil clears it.
    public var setJob: @MainActor (String?) -> Void
    /// A message that fades after `seconds`.
    public var flash: @MainActor (String, Double) -> Void
    public init(setJob: @escaping @MainActor (String?) -> Void, flash: @escaping @MainActor (String, Double) -> Void) {
        self.setJob = setJob
        self.flash = flash
    }
}

/// The session side of the analysis commands, shared by the AppKit window and the shared window (Mac and Windows): target
/// checks, one job at a time with Cancel on the second request, progress and ending lines. The platform only supplies the
/// `AnalysisBackend` and the status line.
@MainActor public final class AnalysisFlows {
    public let session: EditorSession
    public var backend: (any AnalysisBackend)?
    /// Reads the Program picture back for Match Color to Clip; nil = this host cannot.
    public var frameSampler: (any ProgramFrameSampling)?
    public let ui: AnalysisFlowUI

    public let sceneJob = AnalysisJob<Int?>()
    public let reframeJob = AnalysisJob<ReframeOutcome>()
    public let stabilizeJob = AnalysisJob<StabilizeOutcome>()
    /// A Stabilizer analysis started from an Effect Controls Analyze row: the clips it covers and its progress 0...1;
    /// nil when it ended. The Controls panel shows it on the rows (`StabilizeRunState`).
    public var onStabilizeProgress: (@MainActor (Set<Clip.ID>, Double?) -> Void)?
    /// Match Color to Clip: set while the Program engine shows a solo view (a second request waits for it); `colorMatchRun`
    /// counts runs so a late capture of a timed-out run is ignored.
    var colorMatchBusy = false
    var colorMatchRun = 0
    /// How long a Match Color run may wait for its captures before the monitor goes back to the sequence.
    public var colorMatchTimeout = Duration.seconds(5)

    public init(session: EditorSession, backend: (any AnalysisBackend)?, ui: AnalysisFlowUI) {
        self.session = session
        self.backend = backend
        self.ui = ui
    }

    public var isFindingSceneChanges: Bool { sceneJob.isRunning }
    public var isReframing: Bool { reframeJob.isRunning }
    public var isStabilizing: Bool { stabilizeJob.isRunning }

    public static func unavailable(_ title: String) -> String { "\(title) is not available on this computer yet." }

    /// “Clip” for one clip, "3 clips" for several.
    static func subject(_ clips: [Clip]) -> String { clips.count == 1 ? "“\(clips[0].name)”" : "\(clips.count) clips" }

    // MARK: Find Scene Changes

    /// Clip > Video Options > Find Scene Changes. Running it again while it reads cancels it.
    public func requestFindSceneChanges() {
        if sceneJob.isRunning { sceneJob.cancel(); return }
        let clips = session.sceneChangeTargets
        guard !clips.isEmpty else { ui.flash("Select a video clip to look through.", 5); return }
        guard let backend else { ui.flash(Self.unavailable("Find Scene Changes"), 5); return }
        let what = Self.subject(clips)
        let total = clips.count
        let ui = ui
        ui.setJob("Find Scene Changes: reading \(what)…")
        var done = 0
        var supported = true
        sceneJob.start({ [weak self] progress in
            guard let self else { throw CancellationError() }
            let n = await session.findSceneChanges(in: clips) { clip in
                guard let path = self.session.project.media(clip.media)?.path else { return [] }
                let base = Double(done) / Double(total)
                defer { done += 1 }
                guard let times = try await backend.sceneChanges(url: URL(fileURLWithPath: path), range: clip.source, progress: { p in
                    progress(base + p / Double(total))
                }) else { supported = false; throw CancellationError() }
                return times
            }
            try Task.checkCancellation()
            return n
        }, progress: { p in
            ui.setJob("Find Scene Changes: reading \(what)… \(Int((p * 100).rounded())) %")
        }, ended: { ending in
            ui.setJob(nil)
            switch ending {
            case .done(let n):
                switch n {
                case .some(0): ui.flash("No scene changes found.", 4)
                case .some(let c):
                    ui.flash(SQL10n.plural(c, one: "%@ scene change marked. Clip > Audio Options > Accept All Proposed Cuts cuts the clips there, or reject.", other: "%@ scene changes marked. Clip > Audio Options > Accept All Proposed Cuts cuts the clips there, or reject."), 6)
                case .none: ui.flash(supported ? "Find Scene Changes failed." : Self.unavailable("Find Scene Changes"), supported ? 6 : 5)
                }
            case .cancelled: ui.flash(supported ? "Find Scene Changes canceled." : Self.unavailable("Find Scene Changes"), supported ? 3 : 5)
            case .failed(let why): ui.flash(SQL10n.format("Find Scene Changes failed: %@", why), 8)
            }
        })
    }

    // MARK: Auto Reframe

    /// The targets' name for the options dialog, nil (after saying why) when there is nothing to reframe. Cancels a running
    /// analysis and returns nil instead.
    public func reframeSubject() -> String? {
        if reframeJob.isRunning { reframeJob.cancel(); return nil }
        let targets = session.reframeTargets
        guard !targets.isEmpty else { ui.flash("Select a video clip to reframe.", 5); return nil }
        guard backend?.offersReframe == true else { ui.flash(Self.unavailable("Auto Reframe"), 5); return nil }
        return Self.subject(targets)
    }

    public func runAutoReframe(options: ReframeOptions, what: String) {
        guard !reframeJob.isRunning, let backend else { return }
        let ui = ui
        ui.setJob("Auto Reframe: analyzing \(what)…")
        reframeJob.start({ [weak self] progress in
            guard let self else { throw CancellationError() }
            return try await session.autoReframe(options: options, progress: progress) { backend.subjectDetector(for: $0) }
        }, progress: { p in
            ui.setJob("Auto Reframe: analyzing \(what)… \(Int((p * 100).rounded())) %")
        }, ended: { ending in
            ui.setJob(nil)
            switch ending {
            case .done(let out): ui.flash(Self.reframeMessage(out), 5)
            case .cancelled: ui.flash("Auto Reframe canceled.", 3)
            case .failed(let why): ui.flash(SQL10n.format("Auto Reframe failed: %@", why), 8)
            }
        })
    }

    /// The Auto Reframe sheet's two choices (Motion, Framing) as row titles, the remembered picks (`sq.reframe.*`, shared with
    /// the AppKit sheet) and the options of a pick, which is remembered too.
    public static let reframeMotionTitles = ReframeSmoothness.allCases.map(\.title)
    public static let reframeFramingTitles = ReframeTightness.allCases.map(\.title)

    public static func rememberedReframePick(_ d: UserDefaults = .standard) -> (motion: Int, framing: Int) {
        let m = d.string(forKey: "sq.reframe.smoothness").flatMap(ReframeSmoothness.init(rawValue:)) ?? .steady
        let f = d.string(forKey: "sq.reframe.tightness").flatMap(ReframeTightness.init(rawValue:)) ?? .fill
        return (ReframeSmoothness.allCases.firstIndex(of: m) ?? 1, ReframeTightness.allCases.firstIndex(of: f) ?? 0)
    }

    public static func reframeOptions(motion: Int, framing: Int, remember d: UserDefaults = .standard) -> ReframeOptions {
        let s = ReframeSmoothness.allCases[min(max(motion, 0), ReframeSmoothness.allCases.count - 1)]
        let t = ReframeTightness.allCases[min(max(framing, 0), ReframeTightness.allCases.count - 1)]
        d.set(s.rawValue, forKey: "sq.reframe.smoothness")
        d.set(t.rawValue, forKey: "sq.reframe.tightness")
        return ReframeOptions(smoothness: s, tightness: t)
    }

    public static func reframeMessage(_ o: ReframeOutcome) -> String {
        var parts: [String] = []
        if o.reframed > 0 { parts.append("Reframed \(o.reframed) clip(s); the Position keys are in Effect Controls.") }
        if o.alreadyFramed > 0 { parts.append("\(o.alreadyFramed) clip(s) already fill the frame.") }
        if o.noSubject > 0 { parts.append("No subject found in \(o.noSubject) clip(s).") }
        if o.failed > 0 { parts.append("\(o.failed) clip(s) could not be read.") }
        if o.stalled > 0 { parts.append("\(o.stalled) clip(s) stopped answering and were skipped; try them again.") }
        return parts.isEmpty ? "Nothing to reframe." : parts.joined(separator: " ")
    }

    // MARK: Stabilize

    /// Clip > Video Options > Stabilize on the picture analysis (the shared window; the AppKit window adds its Effect
    /// Controls rows and Gyroflow choice around `stabilizeMessage`). Running it again while it analyzes cancels it.
    /// shortcut: no Gyroflow offer and no stale re-run on the shared window; upgrade with the shared Effect Controls Analyze row.
    public func requestStabilize() {
        if stabilizeJob.isRunning { stabilizeJob.cancel(); return }
        let targets = session.stabilizeTargets
        guard !targets.isEmpty else { ui.flash("Select a video clip to stabilize.", 5); return }
        guard let backend, backend.offersStabilize else { ui.flash(Self.unavailable("Stabilize"), 5); return }
        let what = Self.subject(targets)
        let ui = ui
        ui.setJob("Stabilize: analyzing \(what)…")
        stabilizeJob.start({ [weak self] progress in
            guard let self else { throw CancellationError() }
            return try await session.stabilize(progress: progress) { backend.stabilizationAnalyzer(for: $0) }
        }, progress: { p in
            ui.setJob("Stabilize: analyzing \(what)… \(Int((p * 100).rounded())) %")
        }, ended: { ending in
            ui.setJob(nil)
            switch ending {
            case .done(let out): ui.flash(Self.stabilizeMessage(out), 5)
            case .cancelled: ui.flash("Stabilize canceled.", 3)
            case .failed(let why): ui.flash(SQL10n.format("Stabilize failed: %@", why), 8)
            }
        })
    }

    public static func stabilizeMessage(_ o: StabilizeOutcome) -> String {
        var parts: [String] = []
        if o.stabilized > 0 {
            parts.append("Stabilized \(o.stabilized) clip(s), scaled up \(Int((1 / (1 - o.maxCrop) * 100 - 100).rounded())) %.")
        }
        if o.uncovered > 0 { parts.append("\(o.uncovered) clip(s) move too much to hold still; edges show.") }
        if o.leftAsShot > 0 { parts.append("\(o.leftAsShot) clip(s) left as shot: too little detail to measure the shake reliably.") }
        if o.partly > 0 { parts.append("\(o.partly) clip(s) steadied only in parts (too little detail elsewhere).") }
        if o.failed > 0 { parts.append("\(o.failed) clip(s) could not be read.") }
        if o.gyroflow > 0 { parts.append("\(o.gyroflow) clip(s) use the Gyroflow method and were left as they are.") }
        return parts.isEmpty ? "Nothing to stabilize." : parts.joined(separator: " ")
    }
}
