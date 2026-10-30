import AppKit
import SQCore

/// Program monitor layer handles of the selected graphics clip (GFX): every layer's outline, the selected layers'
/// boxes with corner handles. Click selects a layer (Shift toggles, Cmd selects through to the one below), drag moves the selection, a corner handle
/// resizes (Shift keeps the aspect), the Draw tool records a freeform stroke. Clicks beside the layers fall through
/// to the clip's own transform overlay underneath.
@MainActor
public final class GraphicsOverlayView: NSView {
    public let editor: GraphicsEditor
    /// The monitor's view mapping (canvas placement, zoom).
    public var viewMapping: (() -> MonitorViewMapping)?

    /// Drawn only (Type tool, or while a text field is open): never takes the mouse, sets no cursor.
    public var isInteractive = true { didSet { if isInteractive != oldValue { window?.invalidateCursorRects(for: self) } } }
    /// Double-click on a text layer (Select tool): the host opens the in-monitor text field on it.
    public var onEditText: ((UUID) -> Void)?

    private enum Drag {
        case move(GraphicsMoveSnapper), resize(UUID, GraphicsCorner), draw([Vec2])
        /// Empty canvas: a click clears the layers, a drag draws a marquee (start and current point, canvas px).
        case marquee(Vec2, Vec2, extend: Set<UUID>)
    }
    private var drag: Drag?
    /// Snap lines of the running drag (canvas space), drawn as accent guide lines.
    private var guides = SnapGuides.Result.none
    static let handleSize: CGFloat = 8

    public override var isFlipped: Bool { true }

    public init(editor: GraphicsEditor) {
        self.editor = editor
        super.init(frame: .zero)
    }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }

    // MARK: Mapping

    private func canvasPoint(_ p: CGPoint) -> Vec2? {
        guard let m = viewMapping?(), let g = editor.mapping else { return nil }
        return g.canvasPoint(fromSequence: m.sequenceOffset(fromView: p))
    }

    private func viewPoint(_ q: Vec2) -> CGPoint? {
        guard let m = viewMapping?(), let g = editor.mapping else { return nil }
        let s = g.sequenceOffset(fromCanvas: q)
        let r = m.canvasRect
        let k = Double(m.scale / m.backingScale)
        return CGPoint(x: Double(r.midX) + s.x * k, y: Double(r.midY) + s.y * k)
    }

    private func corners(_ l: GraphicsLayer) -> [CGPoint]? {
        guard let cs = l.corners(atLocal: editor.localTime, text: editor.textMeasure) else { return nil }
        let v = cs.compactMap(viewPoint)
        return v.count == 4 ? v : nil
    }

    /// The corner handle under `p` of the single selected, unlocked layer.
    private func handle(at p: CGPoint) -> (UUID, GraphicsCorner)? {
        guard let l = editor.handledLayer, !l.isLocked, let cs = corners(l) else { return nil }
        for k in GraphicsCorner.allCases where hypot(cs[k.rawValue].x - p.x, cs[k.rawValue].y - p.y) <= Self.handleSize {
            return (l.id, k)
        }
        return nil
    }

    private func layer(at p: CGPoint) -> UUID? {
        guard let q = canvasPoint(p) else { return nil }
        return editor.shownDocument?.hitTest(q, atLocal: editor.localTime, text: editor.textMeasure)
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, isInteractive, let sv = superview else { return nil }
        let p = convert(point, from: sv)
        guard bounds.contains(p) else { return nil }
        if editor.isDrawing { return self }
        if handle(at: p) != nil || layer(at: p) != nil { return self }
        // Empty canvas belongs to the layers while some are selected (click clears, drag is a marquee), or when Option
        // is held; otherwise the clip's own transform overlay underneath keeps it.
        let optionHeld = NSEvent.modifierFlags.contains(.option)
        return (!editor.selectedLayers.isEmpty || optionHeld) && canvasPoint(p) != nil ? self : nil
    }

    // MARK: Mouse

    public override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let q = canvasPoint(p) else { return }
        if editor.isDrawing { drag = .draw([q]); return }
        if let (id, corner) = handle(at: p) {
            editor.beginGesture()
            drag = .resize(id, corner)
            return
        }
        guard let id = layer(at: p) else {
            let keep = event.modifierFlags.contains(.shift) ? editor.selectedLayers : []
            drag = .marquee(q, q, extend: keep)
            return
        }
        if event.clickCount == 2, let l = editor.document?.layer(id), !l.isLocked, case .text = l.content {
            editor.select([id])
            drag = nil
            onEditText?(id)
            return
        }
        // Command-click selects through to the layer underneath (deep select); Shift toggles.
        if event.modifierFlags.contains(.command), !event.modifierFlags.contains(.shift) {
            let current = editor.selectedLayers.count == 1 ? editor.selectedLayers.first : nil
            if let deeper = editor.shownDocument?.hitBelow(current, at: q, atLocal: editor.localTime, text: editor.textMeasure) {
                editor.select([deeper])
            }
            drag = nil
            return
        }
        if event.modifierFlags.contains(.shift) {
            var s = editor.selectedLayers
            if s.contains(id) { s.remove(id) } else { s.insert(id) }
            editor.select(s)
            drag = nil
            return
        }
        if !editor.selectedLayers.contains(id) { editor.select([id]) }
        editor.beginGesture()
        drag = .move(moveSnapper(from: q))
    }

    /// Snap lines for this drag: frame edges, center and safe margins in canvas space (none while the graphic is rotated).
    private func snapTargets() -> SnapGuides.Targets? {
        guard let g = editor.mapping else { return nil }
        return GraphicsSnap.targets(canvas: editor.canvas, mapping: g)
    }

    private func snapThreshold() -> Double {
        guard let m = viewMapping?(), let g = editor.mapping else { return 0 }
        return GraphicsSnap.threshold(viewPoints: TransformOverlayView.snapDistance, viewScale: Double(m.scale / m.backingScale), mapping: g)
    }

    private func moveSnapper(from q: Vec2) -> GraphicsMoveSnapper {
        let shown = editor.shownDocument
        let box = editor.selectedLayers.compactMap { shown?.bounds(of: $0, atLocal: editor.localTime, text: editor.textMeasure) }
            .reduce(nil as GraphicsRect?) { acc, r in acc.map { $0.union(r) } ?? r }
        return GraphicsMoveSnapper(startBox: box ?? GraphicsRect(minX: q.x, minY: q.y, maxX: q.x, maxY: q.y), start: q,
                                   targets: snapTargets(), threshold: snapThreshold())
    }

    public override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let q = canvasPoint(p), let d = drag else { return }
        switch d {
        case .move(var snapper):
            // Shift (or Option) switches snapping off.
            let snapping = event.modifierFlags.intersection([.shift, .option]).isEmpty
            let r = snapper.step(to: q, snapping: snapping)
            editor.translateSelected(by: r.delta)
            guides = r.guides
            drag = .move(snapper)
            needsDisplay = true
        case .resize(let id, let corner):
            // Shift keeps the aspect, which moves the edge away from the snapped point: no snapping (and no guide)
            // then. Option switches snapping off too.
            var target = q
            guides = .none
            if event.modifierFlags.intersection([.shift, .option]).isEmpty, let t = snapTargets() {
                let r = GraphicsSnap.snapPoint(q, targets: t, threshold: snapThreshold())
                target = r.point; guides = r.guides
            }
            editor.resize(id, corner: corner, to: target, keepAspect: event.modifierFlags.contains(.shift))
            needsDisplay = true
        case .marquee(let a, _, let keep):
            drag = .marquee(a, q, extend: keep)
            let r = GraphicsRect(minX: min(a.x, q.x), minY: min(a.y, q.y), maxX: max(a.x, q.x), maxY: max(a.y, q.y))
            let hit = editor.shownDocument?.layers(touching: r, atLocal: editor.localTime, text: editor.textMeasure) ?? []
            editor.select(keep.union(hit))
            needsDisplay = true
        case .draw(var pts):
            if let l = pts.last, hypot(l.x - q.x, l.y - q.y) < 2 { return }
            pts.append(q)
            drag = .draw(pts)
            needsDisplay = true
        }
    }

    public override func mouseUp(with event: NSEvent) {
        if case .draw(let pts) = drag { editor.addPath(pts) }
        // A click on empty canvas (no movement) clears the layers and keeps the clip: back to clip level.
        if case .marquee(let a, let b, let keep) = drag, a == b, keep.isEmpty { editor.select([]) }
        drag = nil
        guides = .none
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    /// Crosshair while drawing; otherwise the move cursor only over the selected layer (and nothing when drawn only).
    public override func resetCursorRects() {
        guard isInteractive else { return }
        if editor.isDrawing { addCursorRect(bounds, cursor: .crosshair); return }
        if let l = editor.handledLayer, !l.isLocked, let cs = corners(l) {
            let xs = cs.map(\.x), ys = cs.map(\.y)
            let r = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!).intersection(bounds)
            if !r.isNull { addCursorRect(r, cursor: OverlayCursors.move) }
        }
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        // Follow resolved: the boxes sit where the layers are drawn. An item outside its range has no box and no handles.
        guard editor.document != nil, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let sel = editor.selectedLayers
        for l in editor.outlinedLayers {
            guard let cs = corners(l) else { continue }
            let on = sel.contains(l.id)
            ctx.setStrokeColor((on ? Theme.Colors.accent : Theme.OnPicture.stroke.withAlphaComponent(0.25)).cgColor)
            ctx.setLineWidth(on ? 1.5 : 1)
            ctx.setLineDash(phase: 0, lengths: on ? [] : [3, 3])
            ctx.addLines(between: cs + [cs[0]])
            ctx.strokePath()
        }
        ctx.setLineDash(phase: 0, lengths: [])
        if let l = editor.handledLayer, !l.isLocked, let cs = corners(l) {
            let s = Self.handleSize
            for c in cs {
                let r = CGRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s)
                ctx.setFillColor(Theme.OnPicture.stroke.cgColor)
                ctx.fill(r)
                ctx.setStrokeColor(Theme.Colors.accent.cgColor)
                ctx.setLineWidth(1)
                ctx.stroke(r)
            }
        }
        drawGuides(ctx)
        if case .marquee(let a, let b, _) = drag, let va = viewPoint(a), let vb = viewPoint(b) {
            let r = CGRect(x: min(va.x, vb.x), y: min(va.y, vb.y), width: abs(va.x - vb.x), height: abs(va.y - vb.y))
            ctx.setFillColor(Theme.Colors.accent.withAlphaComponent(0.15).cgColor)
            ctx.fill(r)
            ctx.setStrokeColor(Theme.Colors.accent.cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(r)
        }
        if case .draw(let pts) = drag, pts.count >= 2 {
            let v = pts.compactMap(viewPoint)
            ctx.setStrokeColor(Theme.OnPicture.stroke.cgColor)
            ctx.setLineWidth(2)
            ctx.setLineJoin(.round); ctx.setLineCap(.round)
            ctx.addLines(between: v)
            ctx.strokePath()
        }
    }

    /// The snap lines of the running drag, across the whole view.
    private func drawGuides(_ ctx: CGContext) {
        guard !guides.verticalLines.isEmpty || !guides.horizontalLines.isEmpty else { return }
        ctx.setStrokeColor(Theme.Colors.accent.cgColor)
        ctx.setLineWidth(1)
        for x in guides.verticalLines {
            guard let a = viewPoint(Vec2(x, 0)) else { continue }
            ctx.move(to: CGPoint(x: a.x, y: 0)); ctx.addLine(to: CGPoint(x: a.x, y: bounds.height))
        }
        for y in guides.horizontalLines {
            guard let a = viewPoint(Vec2(0, y)) else { continue }
            ctx.move(to: CGPoint(x: 0, y: a.y)); ctx.addLine(to: CGPoint(x: bounds.width, y: a.y))
        }
        ctx.strokePath()
    }
}
