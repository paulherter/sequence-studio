import Foundation
import SQCore
import SQDrawKit
import SQEditorSession
import SQUIKit

/// Masks on the canvas overlay: the mask parts of the Mac `TransformOverlayView` translated (hit order, pen handles,
/// Mask tool presses, shape rubber band, drawing). Math: the shared `MaskOverlayGeometry`, `MaskPath`, `MaskShapeDrag`.
extension TransformOverlay {
    enum MaskHit: Equatable { case tangent(Int, Int, Bool), vertex(Int, Int), segment(Int, Int, Double), inside(Int) }

    func maskGeometry(in r: CGRect) -> MaskOverlayGeometry { MaskOverlayGeometry(quad: geometry(in: r).quad) }

    /// Where the Mask Tint lands: the layer quad as an image rect with its source (mirrored layers flip the source).
    /// shortcut: nil on a rotated or skewed layer, the image quad is axis-aligned (the Mac stretches the tint over the
    /// turned quad); upgrade when the draw list gets a textured quad with four corners.
    func maskTintPlacement(in r: CGRect) -> (rect: CGRect, source: (Float, Float, Float, Float))? {
        let g = maskGeometry(in: r)
        guard abs(g.xAxis.dy) < 0.01, abs(g.yAxis.dx) < 0.01, abs(g.xAxis.dx) >= 0.5, abs(g.yAxis.dy) >= 0.5 else { return nil }
        let x1 = g.origin.x + g.xAxis.dx, y1 = g.origin.y + g.yAxis.dy
        let rect = CGRect(x: min(g.origin.x, x1), y: min(g.origin.y, y1), width: abs(g.xAxis.dx), height: abs(g.yAxis.dy))
        let (u0, u1): (Float, Float) = g.xAxis.dx >= 0 ? (0, 1) : (1, 0)
        let (v0, v1): (Float, Float) = g.yAxis.dy >= 0 ? (0, 1) : (1, 0)
        return (rect, (u0, v0, u1, v1))
    }

    /// The tint in the Mac color: `Theme.Colors.yellow`, the 30 % already in the coverage's alpha.
    func drawMaskTint(_ c: inout Canvas, in r: CGRect, theme t: DrawTheme) {
        guard let slot = maskTintSlot, let p = maskTintPlacement(in: r) else { return }
        c.draw(imageSlot: slot, in: p.rect, source: p.source, tint: t.yellow.alpha(1))
    }

    /// The Add | Remove switch: two segments top left of the picture area.
    func magicSwitchRects(in r: CGRect) -> (add: CGRect, remove: CGRect) {
        let inset = CGFloat(DrawTheme.Spacing.sm), w: CGFloat = 64, h: CGFloat = 22
        let add = CGRect(x: r.minX + inset, y: r.minY + inset, width: w, height: h)
        return (add, add.offsetBy(dx: w, dy: 0))
    }

    /// Which segment `p` is on: false = Add, true = Remove, nil = not on the switch.
    func magicSwitchHit(_ p: CGPoint, in r: CGRect) -> Bool? {
        guard !r.isEmpty else { return nil }
        let s = magicSwitchRects(in: r)
        if s.add.contains(p) { return false }
        if s.remove.contains(p) { return true }
        return nil
    }

    func drawMagicSwitch(_ c: inout Canvas, in r: CGRect, theme t: DrawTheme) {
        guard !r.isEmpty else { return }
        let s = magicSwitchRects(in: r), radius = CGFloat(DrawTheme.Radius.control)
        let size = CGFloat(DrawTheme.TypeSize.caption)
        c.fill(roundedRect: s.add.union(s.remove), radius: radius, t.viewerHUD)
        let on = magicSubtract ? s.remove : s.add
        c.fill(roundedRect: on.insetBy(dx: 2, dy: 2), radius: radius - 1, t.accentFill)
        c.draw("Add", in: s.add, fontSize: size, t.label, align: .center)
        c.draw("Remove", in: s.remove, fontSize: size, t.label, align: .center)
    }

    /// The frame fraction under `p` when it lies on the layer.
    func maskFramePoint(_ p: CGPoint, in r: CGRect) -> Vec2? {
        guard let n = maskGeometry(in: r).framePoint(p), (0...1).contains(n.x), (0...1).contains(n.y) else { return nil }
        return n
    }

    /// The pointer at `p` (view point): with the Magic tool the host hears where it rests on the layer (`onMaskToolHover`).
    public func pointerMoved(_ p: CGPoint, canvasRect r: CGRect) {
        var n: Vec2?
        if isShown, maskTool == .magic, !r.isEmpty { n = maskFramePoint(p, in: r) }
        guard n != magicHoverPoint else { return }
        magicHoverPoint = n
        if maskTool == .magic || n == nil { onMaskToolHover?(n) }
    }

    /// Mask handles under `p`, nearest kind first: tangent handles and vertices, then the active outline, then its inside.
    func maskHit(_ p: CGPoint, in r: CGRect) -> MaskHit? {
        guard !masks.isEmpty else { return nil }
        let g = maskGeometry(in: r)
        if let h = g.hitTangent(p, masks: masks) { return .tangent(h.mask, h.vertex, h.out) }
        if let h = g.hitVertex(p, masks: masks) { return .vertex(h.mask, h.vertex) }
        if let h = g.hitSegment(p, masks: masks) { return .segment(h.mask, h.segment, h.t) }
        if let i = g.hitInside(p, masks: masks) { return .inside(i) }
        return nil
    }

    /// Selection tool press on the masks' handles; true when they took it.
    func maskHandlesDown(_ p: CGPoint, modifiers: InputModifiers) -> Bool {
        guard let hit = maskHit(p, in: canvasRect) else { return false }
        return pressMask(hit, at: p, modifiers: modifiers)
    }

    /// Mask tool press: Pen and shapes keep the masks' own handles (shapes: not the outline), anything else on the layer
    /// is a tool press; Magic only reports the click (the host says when it cannot pick).
    func maskToolDown(_ p: CGPoint, modifiers: InputModifiers) -> Bool {
        guard let mode = maskTool else { return false }
        if mode != .magic, let hit = maskHit(p, in: canvasRect) {
            var usable = true
            if mode != .pen, case .segment = hit { usable = false }
            if usable, pressMask(hit, at: p, modifiers: modifiers) { return true }
        }
        guard let n = maskFramePoint(p, in: canvasRect) else { return false }
        if mode == .magic { onMaskToolClick?(n, modifiers); return true }
        drag = .maskTool(mode, start: n, startView: p, modifiers: modifiers, moved: false)
        return true
    }

    /// A press on mask handles: a vertex selects its mask; Cmd / Ctrl removes it, Option / Alt toggles smooth, else it
    /// drags. Tangents, the outline (pen) and the inside (move) start their drags.
    private func pressMask(_ hit: MaskHit, at p: CGPoint, modifiers: InputModifiers) -> Bool {
        switch hit {
        case .tangent(let mi, let vi, let isOut):
            let m = masks[mi], v = m.path.vertices[vi]
            let offset = isOut ? v.outTangent : v.inTangent, independent = modifiers.contains(.option)
            drag = .maskTangent(m.id, vi, out: isOut, last: offset, independent: independent)
            onMaskEdit?(.began, .tangent(m.id, vertex: vi, out: isOut, offset: offset, independent: independent))
        case .vertex(let mi, let vi):
            let m = masks[mi]
            onMaskSelect?(m.id)
            if modifiers.contains(.command) { click(.remove(m.id, vertex: vi)) }
            else if modifiers.contains(.option) { click(.toggleSmooth(m.id, vertex: vi)) }
            else {
                drag = .maskVertex(m.id, vi)
                onMaskVertex?(.began, m.id, vi, m.path.vertices[vi].point)
            }
        case .segment(let mi, let seg, let t):
            let id = masks[mi].id
            drag = .maskPen(id, segment: seg, t: t, base: masks[mi].path, last: .zero, independent: false)
            onMaskEdit?(.began, .pen(id, segment: seg, t: t, handle: .zero, independent: false))
            onMaskEdit?(.changed, .pen(id, segment: seg, t: t, handle: .zero, independent: false))
            masks[mi].path = masks[mi].path.splitting(segment: seg, at: t)
        case .inside(let mi):
            guard let n = maskGeometry(in: canvasRect).framePoint(p) else { return true }
            drag = .maskMove(masks[mi].id, start: n, base: masks[mi].path, last: .zero)
            onMaskEdit?(.began, .move(masks[mi].id, delta: .zero))
        }
        return true
    }

    private func click(_ e: MaskHandleEdit) {
        onMaskEdit?(.began, e)
        onMaskEdit?(.ended, e)
    }

    func maskDragged(_ d: Drag, to p: CGPoint, shift: Bool, option: Bool) {
        let g = maskGeometry(in: canvasRect)
        switch d {
        case .maskVertex(let id, let i):
            guard let n = g.framePoint(p) else { return }
            if let mi = masks.firstIndex(where: { $0.id == id }) { masks[mi].path.moveVertex(i, to: n) }
            onMaskVertex?(.changed, id, i, n)
        case .maskTangent(let id, let i, let isOut, _, _):
            guard let n = g.framePoint(p), let mi = masks.firstIndex(where: { $0.id == id }),
                  masks[mi].path.vertices.indices.contains(i) else { return }
            let offset = n - masks[mi].path.vertices[i].point
            masks[mi].path.setTangent(i, out: isOut, to: offset, independent: option)
            drag = .maskTangent(id, i, out: isOut, last: offset, independent: option)
            onMaskEdit?(.changed, .tangent(id, vertex: i, out: isOut, offset: offset, independent: option))
        case .maskPen(let id, let seg, let t, let base, _, _):
            guard let n = g.framePoint(p), let mi = masks.firstIndex(where: { $0.id == id }),
                  base.vertices.indices.contains(seg) else { return }
            let handle = n - base.splitting(segment: seg, at: t).vertices[seg + 1].point
            masks[mi].path = base.placingVertex(segment: seg, at: t, handle: handle, independent: option)
            drag = .maskPen(id, segment: seg, t: t, base: base, last: handle, independent: option)
            onMaskEdit?(.changed, .pen(id, segment: seg, t: t, handle: handle, independent: option))
        case .maskMove(let id, let start, let base, _):
            guard let n = g.framePoint(p) else { return }
            var delta = n - start
            if shift { if abs(delta.x) >= abs(delta.y) { delta.y = 0 } else { delta.x = 0 } }   // Shift: one axis
            if let mi = masks.firstIndex(where: { $0.id == id }) { masks[mi].path = base.translated(by: delta) }
            drag = .maskMove(id, start: start, base: base, last: delta)
            onMaskEdit?(.changed, .move(id, delta: delta))
        case .maskTool(let mode, let start, let sv, let mods, let moved):
            let far = !MaskShapeDrag.isClick(viewDistance: Double(hypot(p.x - sv.x, p.y - sv.y)))
            guard moved || far else { return }
            if !moved { drag = .maskTool(mode, start: start, startView: sv, modifiers: mods, moved: true) }
            guard let kind = mode.shapeKind, let n = g.framePoint(p) else { return }
            drawPreview = MaskShapeDrag(kind: kind, start: start).path(to: n, square: shift, fromCenter: option,
                                                                      frame: g.frameExtent)
        default: break
        }
    }

    func maskUp(_ d: Drag, at p: CGPoint) {
        masksAtPress = nil
        let g = maskGeometry(in: canvasRect)
        switch d {
        case .maskVertex(let id, let i):
            let n = g.framePoint(p) ?? masks.first(where: { $0.id == id })?.path.vertices[i].point ?? .zero
            onMaskVertex?(.ended, id, i, n)
        case .maskTangent(let id, let i, let isOut, let last, let independent):
            onMaskEdit?(.ended, .tangent(id, vertex: i, out: isOut, offset: last, independent: independent))
        case .maskPen(let id, let seg, let t, _, let last, let independent):
            onMaskEdit?(.ended, .pen(id, segment: seg, t: t, handle: last, independent: independent))
        case .maskMove(let id, _, _, let last):
            onMaskEdit?(.ended, .move(id, delta: last))
        case .maskTool(let mode, let start, let sv, let mods, let moved):
            let shape = drawPreview
            drawPreview = nil
            if moved, let kind = mode.shapeKind {
                if let shape { onMaskShapeDrawn?(kind, shape) }
                return
            }
            // A click: inside another mask with a shape mode selects that mask, else the tool's click (Pen point,
            // default-size shape centered there).
            if mode != .pen, let mi = g.hitAnyInside(sv, masks: masks) { onMaskSelect?(masks[mi].id); return }
            onMaskToolClick?(start, mods)
        default: break
        }
    }

    // MARK: Drawing (TransformOverlayView.drawMasks / drawShapePreview / drawTangentHandles)

    /// Mask outlines (flattened paths) and their vertices, on the layer: the active mask with filled squares and its
    /// Bezier handles, the others hollow.
    func drawMasks(_ c: inout Canvas, in r: CGRect, theme t: DrawTheme) {
        guard !masks.isEmpty else { return }
        let g = maskGeometry(in: r), shadow = t.onPictureShadow
        for m in masks {
            let pts = g.outline(m.path)
            guard pts.count > 1 else { continue }
            c.stroke(polygon: pts, width: 3, shadow)
            c.stroke(polygon: pts, width: 1, t.yellow)
            if m.active { drawTangentHandles(&c, m.path, g, theme: t) }
            for v in m.path.vertices {
                let p = g.viewPoint(v.point)
                let sq = CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)
                c.fill(sq, m.active ? t.yellow : shadow)
                c.stroke(polygon: Self.corners(sq), width: 1, shadow)
                if !m.active { c.stroke(polygon: Self.corners(sq.insetBy(dx: 1, dy: 1)), width: 1, t.yellow) }
            }
        }
    }

    /// The Rectangle / Ellipse being dragged out, as the committed mask will look.
    func drawShapePreview(_ c: inout Canvas, in r: CGRect, theme t: DrawTheme) {
        guard let path = drawPreview else { return }
        let pts = maskGeometry(in: r).outline(path)
        guard pts.count > 1 else { return }
        c.stroke(polygon: pts, width: 3, t.onPictureShadow)
        c.stroke(polygon: pts, width: 1, t.yellow)
    }

    private func drawTangentHandles(_ c: inout Canvas, _ path: MaskPath, _ g: MaskOverlayGeometry, theme t: DrawTheme) {
        var dots: [CGPoint] = []
        for v in path.vertices {
            let p = g.viewPoint(v.point)
            for tan in [v.inTangent, v.outTangent] where tan != .zero {
                let h = g.viewPoint(v.point + tan)
                c.strokeLine(from: p, to: h, width: 1, t.label2)
                dots.append(h)
            }
        }
        for h in dots {
            let dot = CGRect(x: h.x - 3.5, y: h.y - 3.5, width: 7, height: 7)
            c.fill(ellipseIn: dot, t.yellow)
            c.stroke(ellipseIn: dot, width: 1, t.onPictureShadow)
        }
    }
}
