import Foundation
import SQCore
import SQDrawKit
import SQDrawMonitor
import SQEditorSession
import SQInspectorUI
import SQText
import SQTimelineUI
import SQUIKit

/// The Program monitor's picture tools in the shared shell, wired as the Mac host wires them:
/// App/Sources/EditorPanels+CreateTool.swift (Create tool items), +Captions.swift (caption drag and double-click editing)
/// and +DynamicZoomEdit.swift (the Start / End window editor).
extension MonitorHost {
    public func attachPictureTools(graphics: @escaping () -> GraphicsEditor?) {
        panel.onCreateShape = { [weak self] kind, a, b in
            self?.createItem(named: "Add \(kind.title)", graphics()) { map, canvas in
                GraphicsEditor.createdShape(kind, from: a, to: b, mapping: map, canvas: canvas)
            }
        }
        panel.onCreateStroke = { [weak self] points, tolerance in
            self?.createItem(named: "Draw", graphics()) { map, _ in
                let scale = max(abs(map.transform.scale.x), 1e-6)
                return GraphicsEditor.strokeLayer(points.map(map.canvasPoint(fromSequence:)), tolerance: tolerance / scale)
            }
        }
        panel.captionHitTest = { [weak self] p in self?.captionHit(p) ?? false }
        panel.onCaptionDragBegan = { [weak self] p in self?.beginCaptionDrag(at: p) ?? false }
        panel.onCaptionDragMoved = { [weak self] d, snap in self?.moveCaptionDrag(by: d, snap: snap) ?? .none }
        panel.onCaptionDragEnded = { [weak self] in self?.captionDrag = nil }
        panel.onCaptionDoubleClick = { [weak self] p in self?.text.beginCaptionEditing(at: p) }
    }

    // MARK: Create tool

    /// Sequence > New Shape: the Create tool's item for a centered default drag (`GraphicsEditor.menuShapeDrag`, the Mac
    /// `EditorPanels.createShapeAtCenter`): a layer of the selected or targeted Graphic, else a new Graphic clip.
    public func createShapeAtCenter(_ kind: ShapeKind, graphics g: GraphicsEditor?) {
        createItem(named: "Add \(kind.title)", g) { map, canvas in
            let drag = GraphicsEditor.menuShapeDrag(kind, canvas: canvas)
            return GraphicsEditor.createdShape(kind, from: drag.from, to: drag.to, mapping: map, canvas: canvas)
        }
    }

    /// Adds the item `make` builds as one undo step: into the selected or targeted Graphic, else a new Graphic clip at
    /// the playhead on the first free video track (never over footage).
    private func createItem(named name: String, _ g: GraphicsEditor?, _ make: (GraphicsCanvasMapping, Vec2) -> GraphicsLayer?) {
        session.stopPlayback()
        if let g, g.addCreatedItem(named: name, make) { session.seek(to: session.playhead); return }
        guard let tl = session.activeTimeline,
              let layer = make(GraphicsCanvasMapping(transform: ClipTransform()),
                               g?.canvas ?? Vec2(Double(tl.format.width), Double(tl.format.height))) else { return }
        let seconds = Int64(AppSettings.load().defaultTextSeconds)
        guard session.addGraphicsClip(duration: Time(seconds, 1), layers: [layer], neverOverwrite: true) != nil else {
            onStatus?(session.lastError ?? "Could not add the graphic.")
            return
        }
        session.seek(to: session.playhead)
        g?.sync()
        g?.select([layer.id])
    }

    // MARK: Captions

    private var captionLibrary: CaptionPresetLibrary { CaptionLookRegistry.shared.library(for: session.project) }

    private func captionHit(_ p: Vec2) -> Bool {
        guard maskToolNow() == nil, session.engine.showsCaptions, let tl = session.displayTimeline else { return false }
        return CaptionMonitorHit.caption(at: p, in: tl, time: session.playhead, library: captionLibrary) != nil
    }

    private func beginCaptionDrag(at p: Vec2) -> Bool {
        guard session.engine.showsCaptions, let tl = session.displayTimeline,
              let id = CaptionMonitorHit.caption(at: p, in: tl, time: session.playhead, library: captionLibrary),
              let item = session.captionItem(id) else { return false }
        session.select(clips: [], captions: [id])
        captionDrag = (id, session.effectiveCaptionPosition(item),
                       CaptionMonitorHit.textRect(of: item, canvas: tl.format, library: captionLibrary), false)
        return true
    }

    /// One drag = one undo step; snaps to the center, the safe areas and the platform zone.
    private func moveCaptionDrag(by delta: Vec2, snap: Double) -> SnapGuides.Result {
        guard var d = captionDrag, let tl = session.displayTimeline else { return .none }
        let w = Double(tl.format.displayWidth), h = Double(tl.format.height)
        let r = CaptionDrag.moved(start: d.start, textRect: d.textRect, delta: delta, canvas: CGSize(width: w, height: h),
                                  threshold: snap, zone: model.safeZone.offsetRect(canvasWidth: w, canvasHeight: h))
        session.stopPlayback()
        _ = session.setCaptionItemPosition([d.id], r.position, continuesGesture: d.started)
        d.started = true
        captionDrag = d
        return r.guides
    }

    // MARK: Dynamic Zoom

    /// Sequence > Video Options > Edit Dynamic Zoom: starts the editor on the selected picture clip under the playhead,
    /// or ends it when it runs. False when there is no such clip.
    @discardableResult
    public func toggleDynamicZoomEdit() -> Bool {
        if zoomEditRun != nil { endDynamicZoomEdit(); return true }
        guard let (clip, _) = zoomEditTarget(), let w = session.dynamicZoomWindows(for: clip) else { return false }
        let z = ZoomEditOverlay()
        z.onDone = { [weak self] in self?.endDynamicZoomEdit() }
        z.onChange = { [weak self] phase, s, e in self?.zoomEditChanged(phase, s, e) }
        z.start = w.start; z.end = w.end
        panel.zoomEdit = z
        zoomEditRun = (clip.id, w.ease, false, false)
        refreshDynamicZoomEdit()
        return true
    }

    public func endDynamicZoomEdit() {
        panel.zoomEdit = nil
        zoomEditRun = nil
    }

    /// The selected, shown picture clip (not text, not a graphic) and its overlay target.
    private func zoomEditTarget() -> (Clip, OverlayTarget)? {
        guard let tl = session.displayTimeline, let clip = session.displayedSelectedClip,
              let t = OverlayTarget.make(clip: clip, project: session.project, timeline: tl, at: session.playhead,
                                         variant: session.activeVariantID), !t.isText, !t.isGraphics else { return nil }
        return (clip, t)
    }

    /// Per frame: the editor closes when its clip is no longer the one shown; otherwise it takes the clip's windows and
    /// the layer geometry (EditorPanels.refreshDynamicZoomEdit).
    func refreshDynamicZoomEdit() {
        guard let run = zoomEditRun, let z = panel.zoomEdit else { return }
        guard let (clip, target) = zoomEditTarget(), clip.id == run.clip else { endDynamicZoomEdit(); return }
        let size = target.size
        z.geometry = ZoomEditGeometry(layer: TransformOverlayGeometry(
            sequenceSize: panel.sequenceSize, viewRect: panel.canvasRect,
            mediaAspect: size.height > 0 ? Double(size.width / size.height) : 16.0 / 9,
            transform: target.displayTransform, mediaPixelSize: size))
        if !run.dragging, let w = session.dynamicZoomWindows(for: clip) {
            if z.start != w.start { z.start = w.start }
            if z.end != w.end { z.end = w.end }
            zoomEditRun?.ease = w.ease
        }
    }

    private func zoomEditChanged(_ phase: ZoomEditOverlay.Phase, _ start: ZoomRect, _ end: ZoomRect) {
        guard let run = zoomEditRun else { return }
        switch phase {
        case .began:
            session.stopPlayback()
            zoomEditRun?.dragging = true; zoomEditRun?.wrote = false
        case .changed, .ended:
            if session.setDynamicZoomWindows(clip: run.clip, start: start, end: end, ease: run.ease, continuesGesture: run.wrote) {
                zoomEditRun?.wrote = true
            }
            if phase == .ended { zoomEditRun?.dragging = false; refreshDynamicZoomEdit() }
        }
    }
}
