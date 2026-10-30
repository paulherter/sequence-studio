import AppKit
import SQCore
import SQEditorUI

/// Dynamic Zoom editor state (extensions cannot add stored properties).
@MainActor private enum ZoomEditRun {
    static var view: ZoomEditOverlayView?
    static var clip: Clip.ID?
    static var ease = ZoomEase.easeInOut
    /// A drag is running: the overlay keeps its own windows, the clip is only written.
    static var dragging = false
    static var wrote = false
}

/// "Edit Dynamic Zoom": the Start and End windows of the selected clip on the Program monitor, dragged live (the monitor
/// shows the zoom while you drag; one undo step per drag). Reads and writes the clip's Dynamic Zoom stage, so Effect
/// Controls shows the same Scale / Position keys.
extension EditorPanels {
    var isEditingDynamicZoom: Bool { ZoomEditRun.view != nil }

    /// Starts (or, when already running, ends) the editor. False when no single picture clip is under the playhead.
    @discardableResult
    func toggleDynamicZoomEdit() -> Bool {
        if isEditingDynamicZoom { endDynamicZoomEdit(); return true }
        guard let target = overlayTarget, !target.isText, !target.isGraphics,
              let clip = session.displayedSelectedClip, clip.id == target.clip,
              let w = session.dynamicZoomWindows(for: clip) else { return false }
        let v = ZoomEditOverlayView(frame: surface.bounds)
        v.autoresizingMask = [.width, .height]
        v.onDone = { [weak self] in self?.endDynamicZoomEdit() }
        v.onChange = { [weak self] phase, s, e in self?.zoomEditChanged(phase, s, e) }
        surface.addSubview(v)
        ZoomEditRun.view = v
        ZoomEditRun.clip = clip.id
        ZoomEditRun.ease = w.ease
        v.start = w.start; v.end = w.end
        refreshDynamicZoomEdit()
        return true
    }

    func endDynamicZoomEdit() {
        ZoomEditRun.view?.removeFromSuperview()
        ZoomEditRun.view = nil; ZoomEditRun.clip = nil; ZoomEditRun.dragging = false
    }

    /// Follows selection, playhead and edits (called from `updateOverlay`): the editor closes when its clip is no longer
    /// the one shown; otherwise it takes the clip's windows and layer geometry.
    func refreshDynamicZoomEdit() {
        guard let v = ZoomEditRun.view else { return }
        guard let target = overlayTarget, target.clip == ZoomEditRun.clip, !target.isText,
              let clip = session.displayedSelectedClip, clip.id == target.clip else { endDynamicZoomEdit(); return }
        v.frame = surface.bounds
        let size = target.size
        v.layerGeometry = ZoomEditGeometry(layer: TransformOverlayGeometry(
            sequenceSize: surface.sequenceSize, viewRect: surface.mapping.canvasRect,
            mediaAspect: size.height > 0 ? Double(size.width / size.height) : 16.0 / 9,
            transform: target.displayTransform, mediaPixelSize: size))
        if !ZoomEditRun.dragging, let w = session.dynamicZoomWindows(for: clip) {
            if v.start != w.start { v.start = w.start }
            if v.end != w.end { v.end = w.end }
            ZoomEditRun.ease = w.ease
        }
    }

    private func zoomEditChanged(_ phase: ZoomEditOverlayView.Phase, _ start: ZoomRect, _ end: ZoomRect) {
        guard let id = ZoomEditRun.clip else { return }
        switch phase {
        case .began:
            session.stopPlayback()
            ZoomEditRun.dragging = true; ZoomEditRun.wrote = false
        case .changed, .ended:
            if session.setDynamicZoomWindows(clip: id, start: start, end: end, ease: ZoomEditRun.ease,
                                             continuesGesture: ZoomEditRun.wrote) { ZoomEditRun.wrote = true }
            if phase == .ended { ZoomEditRun.dragging = false; refreshDynamicZoomEdit() }
        }
    }
}
