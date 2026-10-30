import Foundation
import SQCore
import SQEditorSession
import SQLibrary
import SQUIKit

/// Window > Quick Apply (Option+Space) and Go to Next Weak Tracking on the shared shell; the Mac AppKit window runs the same
/// session code (`EditorSession.applyQuickApply`, `MagicTrackHealthCache`).
extension ShellHost {
    var quickApplyOpen: Bool { quickApply != nil }

    func toggleQuickApply() {
        if quickApply != nil { closeQuickApply(); return }
        guard let rows = quickApplyItems else { flash(AnalysisFlows.unavailable("Quick Apply")); return }
        quickApplyModel.setItems(rows())
        let popup = QuickApplyPopup(model: quickApplyModel)
        popup.measure = measure
        popup.canChooseTransitionEnd = { [weak self] in
            guard let self else { return false }
            return !session.quickApplyTransitionClips(for: quickApplyModel.selected).isEmpty
        }
        popup.onClose = { [weak self] in self?.closeQuickApply() }
        popup.onChoose = { [weak self] item, end in self?.applyQuickApply(item, end: end) }
        quickApply = popup
        popup.open(in: CGRect(origin: .zero, size: size))
    }

    func closeQuickApply() { quickApply = nil }

    /// What Return applies to the current selection (the Mac `AppController.applyQuickApply`).
    func applyQuickApply(_ item: QuickApplyItem, end: TransitionEnd? = nil) {
        let outcome = session.applyQuickApply(item, end: end, presets: libraryPresets?() ?? [], timelineEdges: edgeSelection?())
        switch outcome {
        case .status(let line, _): if let line, !line.isEmpty { flash(line) }
        case .command(let c): _ = execute(c)
        case .saveStackAsPreset: if let save = saveStackAsPreset { save() } else { flash(AnalysisFlows.unavailable("Save Effect Stack as Preset")) }
        case .macro(let macro): runQuickApplyMacro(macro)
        }
    }

    /// A palette macro: its steps run in order and the undo steps they leave fold into one named step. Voice Chain is a toggle,
    /// so a step that would switch it off is skipped; Match Loudness is awaited so its result lands inside the fold.
    func runQuickApplyMacro(_ macro: QuickApplyMacro) {
        let rows = Dictionary(quickApplyModel.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let steps = macro.steps.compactMap { rows[$0] }
        let depth = session.undoStepDepth
        spawn { [weak self] in
            guard let self else { return }
            for step in steps {
                switch step.action {
                case .command(.voiceChain) where session.voiceChainActive: continue
                case .command(.matchLoudness): await matchLoudness()
                default: applyQuickApply(step)
                }
            }
            if session.undoStepDepth > depth + 1 { session.foldUndo(fromDepth: depth, name: macro.name) }
        }
    }

    /// Markers > Go to Next Weak Tracking: the next weak stretch of a tracked Magic mask after the playhead.
    func goToNextWeakTracking() {
        guard let cache = magicHealth else { flash(MagicTrackHealthCache.message(for: .noTrackedMask) ?? ""); return }
        let jump = cache.nextWeakStart(after: session.playhead, in: session.activeTimeline)
        if case .found(let t) = jump { session.seek(to: t); return }
        if let line = MagicTrackHealthCache.message(for: jump) { flash(line) }
    }
}
