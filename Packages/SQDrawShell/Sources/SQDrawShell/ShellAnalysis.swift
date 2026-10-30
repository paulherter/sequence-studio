import Foundation
import SQCore
import SQEditorSession
import SQUIKit

/// The analysis commands (Find Scene Changes, Stabilize, Auto Reframe) on the shared shell: the session side is
/// `AnalysisFlows` (also used by the AppKit window); the platform sets `analysisBackend` and `onJob`.
extension ShellHost {
    static let analysisCommands: Set<EditorCommand> = [.findSceneChanges, .stabilize, .autoReframe]

    /// Runs one of the analysis commands; false for any other.
    func runAnalysisCommand(_ c: EditorCommand) -> Bool {
        switch c {
        case .findSceneChanges: analysis.requestFindSceneChanges()
        case .stabilize: analysis.requestStabilize()
        case .autoReframe:
            guard let what = analysis.reframeSubject() else { return true }
            spawn { [weak self] in
                guard let self, let pick = await self.askReframe(subject: what) else { return }
                self.analysis.runAutoReframe(options: AnalysisFlows.reframeOptions(motion: pick.motion, framing: pick.framing), what: what)
            }
        case .matchColorToClip: analysis.requestColorMatchToClip()
        case .nextWeakTracking: goToNextWeakTracking()
        case .quickApply: toggleQuickApply()
        default: return false
        }
        return true
    }

    /// Menu rule of the analysis commands (nil = not one of them): a running job keeps its command enabled to cancel it.
    func analysisEnabled(_ c: EditorCommand) -> Bool? {
        switch c {
        case .findSceneChanges: return analysis.isFindingSceneChanges || !session.sceneChangeTargets.isEmpty
        case .stabilize: return analysis.isStabilizing || !session.stabilizeTargets.isEmpty
        case .autoReframe: return analysis.isReframing || !session.reframeTargets.isEmpty
        case .matchColorToClip: return session.hasColorMatchTarget
        default: return nil
        }
    }

    func analysisTitles(into s: inout ShellMenuState) {
        if analysis.isFindingSceneChanges { s.titles[.findSceneChanges] = "Cancel Find Scene Changes" }
        if analysis.isStabilizing { s.titles[.stabilize] = "Cancel Stabilize" }
        if analysis.isReframing { s.titles[.autoReframe] = "Cancel Auto Reframe" }
    }

    /// The Auto Reframe sheet (the AppKit `ReframeOptionsDialog`): Motion and Framing, the last pick remembered. Nil on Cancel.
    func askReframe(subject: String) async -> (motion: Int, framing: Int)? {
        let start = AnalysisFlows.rememberedReframePick()
        let d = ShellDialog("Auto Reframe", informative: subject + "\nKeeps the subject in the frame with Position keys you can edit in Effect Controls.")
        d.width = ShellDialog.M.widthS
        d.form = ShellForm([
            .segmented(id: "motion", label: "Motion", options: AnalysisFlows.reframeMotionTitles, selected: start.motion, segmentWidth: 0),
            .segmented(id: "framing", label: "Framing", options: AnalysisFlows.reframeFramingTitles, selected: start.framing, segmentWidth: 0),
            .text("Quick follows every move. Smooth holds the frame calmer but can trail a fast subject. Closer and Tight zoom in on the subject."),
        ])
        d.addButton("Reframe")
        d.addButton("Cancel", role: .cancel)
        guard await ask(d) == .first, let f = d.form else { return nil }
        return (f.index("motion") ?? start.motion, f.index("framing") ?? start.framing)
    }
}
