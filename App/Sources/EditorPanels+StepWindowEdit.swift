import AppKit
import SQCore
import SQEditorUI

/// Step window editor state (extensions cannot add stored properties).
@MainActor private enum StepWindowRun {
    static var view: StepWindowOverlayView?
}

/// Color page, Pro grade: the window of the selected Step as handles over the Program monitor (move, resize, rotate).
/// Each drag is one "Color Graph" undo step; the panel's sliders show the same values. The overlay lives while the
/// panel reports a target and the monitor shows that clip.
extension EditorPanels {
    /// Follows the panel's target, the selection, the playhead and edits (called from `updateOverlay` and when the
    /// panel's target changes).
    func refreshStepWindowEdit() {
        guard let t = colorView.windowEdit, let target = overlayTarget, target.clip == t.clip, !target.isText,
              !target.isGraphics, !surface.isEditingText else {
            StepWindowRun.view?.removeFromSuperview()
            StepWindowRun.view = nil
            return
        }
        let v = StepWindowRun.view ?? makeStepWindowOverlay()
        if v.superview !== surface { surface.addSubview(v) }
        v.frame = surface.bounds
        let size = target.size
        v.geometry = StepWindowEditGeometry(layer: ZoomEditGeometry(layer: TransformOverlayGeometry(
            sequenceSize: surface.sequenceSize, viewRect: surface.mapping.canvasRect,
            mediaAspect: size.height > 0 ? Double(size.width / size.height) : 16.0 / 9,
            transform: target.displayTransform, mediaPixelSize: size)))
        if !v.isDragging, v.stepWindow != t.window { v.stepWindow = t.window }
    }

    private func makeStepWindowOverlay() -> StepWindowOverlayView {
        let v = StepWindowOverlayView(frame: surface.bounds)
        v.autoresizingMask = [.width, .height]
        v.onChange = { [weak self] phase, w in
            guard let self else { return }
            switch phase {
            case .began:
                self.session.stopPlayback()
                self.colorView.beginWindowEdit()
            case .changed:
                self.colorView.changeWindowEdit(w)
            case .ended:
                self.colorView.changeWindowEdit(w)
                self.colorView.endWindowEdit()
            }
        }
        StepWindowRun.view = v
        return v
    }
}
