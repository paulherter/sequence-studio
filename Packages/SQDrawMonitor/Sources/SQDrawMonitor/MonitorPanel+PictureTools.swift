import Foundation
import SQCore
import SQDrawKit
import SQEditorSession

/// Tools on the Program / Source picture, translated from the Mac ProgramSurfaceView, ZoomEditOverlayView,
/// StepWindowOverlayView and AnglesGridView: the Dynamic Zoom and Color Step window editors, the multi-angle tiles, the
/// Create tool drag (shapes, lines, freehand strokes) and the caption press (drag moves it with snapping, double-click
/// edits it). The host owns the model edits; the panel reports positions in sequence px from the canvas center.
extension MonitorPanel {
    /// Smallest drag (view points) that moves a caption; a click on the text only selects it (ProgramSurfaceView).
    static let minCaptionDrag: CGFloat = 3

    var pictureToolDragging: Bool {
        createDrag != nil || captionPress != nil || zoomEdit?.isDragging == true || stepWindowEdit?.isDragging == true
    }

    /// The press on the picture for one of the tools here; false lets it go on (guides, transform box, pick).
    func beginPictureToolPress(at p: CGPoint, modifiers: InputModifiers) -> Bool {
        if showsAnglesGrid {
            if let i = AnglesGridLayout.index(at: p, cells: angleCells) { model.onPickAngle?(i) }
            return true
        }
        guard model.mode == .program else { return false }
        if let z = zoomEdit {
            let now = clock()
            let double = lastPress.map { now - $0.time <= Self.doubleClickInterval && hypot(p.x - $0.p.x, p.y - $0.p.y) <= 4 } ?? false
            lastPress = (now, p)
            z.layout(slot: slot)
            _ = z.mouseDown(p, clickCount: double ? 2 : 1, scale: scale)
            return true   // the Mac editor view covers the picture: a press outside its windows reaches nothing else
        }
        if let s = stepWindowEdit, s.mouseDown(p) { return true }
        if let mode = createModeNow(), mode != .text, onCreateShape != nil || onCreateStroke != nil {
            lastPress = nil
            createDrag = CreateToolDrag(mode: mode, start: CGPoint(x: p.x - slot.minX, y: p.y - slot.minY))
            return true
        }
        return beginCaptionPress(at: p)
    }

    func pictureToolDragged(_ p: CGPoint) {
        let mods = overlay.modifiersNow?() ?? []
        if let z = zoomEdit, z.isDragging { z.mouseDragged(p, modifiers: mods, scale: scale); return }
        if let s = stepWindowEdit, s.isDragging { s.mouseDragged(p); return }
        if createDrag != nil {
            createDrag?.move(to: CGPoint(x: p.x - slot.minX, y: p.y - slot.minY), constrain: mods.contains(.shift),
                             fromCenter: mods.contains(.option))
            return
        }
        guard var press = captionPress else { return }
        if !press.moved, abs(p.x - press.start.x) < Self.minCaptionDrag, abs(p.y - press.start.y) < Self.minCaptionDrag { return }
        press.moved = true
        let k = viewPointsPerPixel
        let snap = mods.contains(.option) ? 0 : TransformOverlay.snapDistance / k
        let delta = Vec2(Double(p.x - press.start.x) / k, Double(p.y - press.start.y) / k)
        press.guides = onCaptionDragMoved?(delta, snap) ?? .none
        captionPress = press
    }

    func pictureToolEnded(_ p: CGPoint) {
        if let z = zoomEdit, z.isDragging { z.mouseUp(p); return }
        if let s = stepWindowEdit, s.isDragging { s.mouseUp(p); return }
        if var d = createDrag {
            let mods = overlay.modifiersNow?() ?? []
            d.move(to: CGPoint(x: p.x - slot.minX, y: p.y - slot.minY), constrain: mods.contains(.shift), fromCenter: mods.contains(.option))
            createDrag = nil
            finishCreateDrag(d)
            return
        }
        if let press = captionPress {
            captionPress = nil
            if press.moved { onCaptionDragEnded?() }
        }
    }

    /// Esc ends a Create drag without making anything, puts a dragged Step window back, closes the Dynamic Zoom editor.
    func pictureToolKey(_ key: InputKey, modifiers: InputModifiers) -> Bool {
        if let z = zoomEdit, z.key(key, modifiers: modifiers, now: clock()) { return true }
        guard key == .escape else { return false }
        if createDrag != nil { createDrag = nil; return true }
        if let s = stepWindowEdit, s.cancelDrag() { return true }
        return false
    }

    /// View points per sequence px.
    var viewPointsPerPixel: Double { max(Double(mapping.scale / mapping.backingScale), 1e-6) }

    // MARK: Create tool

    private func finishCreateDrag(_ d: CreateToolDrag) {
        guard d.isDrag(minimum: CreateToolDrag.minDrag) else { return }
        let m = mapping
        func seq(_ p: Vec2) -> Vec2 { m.sequenceOffset(fromView: CGPoint(x: p.x, y: p.y)) }
        switch d.outline {
        case .box(let r, let ellipse):
            onCreateShape?(ellipse ? .ellipse : .rectangle, seq(Vec2(r.minX, r.minY)), seq(Vec2(r.maxX, r.maxY)))
        case .line(let a, let b): onCreateShape?(.line, seq(a), seq(b))
        case .stroke(let pts): onCreateStroke?(pts.map(seq), CreateToolDrag.strokeTolerance / viewPointsPerPixel)
        }
    }

    // MARK: Captions

    /// Select tool press on a caption's text: the second press of a double-click edits it, a press selects it and a drag
    /// moves it. Only when no Type or Create tool is on (the host's hit test answers false for the Mask tool).
    private func beginCaptionPress(at p: CGPoint) -> Bool {
        guard !typeToolOn(), createModeNow() == nil, let hit = captionHitTest,
              let pos = mapping.clickPosition(CGPoint(x: p.x - slot.minX, y: p.y - slot.minY)), hit(pos) else { return false }
        let now = clock()
        if let last = lastPress, now - last.time <= Self.doubleClickInterval,
           hypot(p.x - last.p.x, p.y - last.p.y) <= Self.typeDragThreshold {
            lastPress = nil
            onCaptionDoubleClick?(pos)
            return true
        }
        lastPress = (now, p)
        if onCaptionDragBegan?(pos) == true { captionPress = (p, false, .none) }
        return true
    }

    // MARK: Angles

    /// Source monitor: every angle of the Angles clip under the playhead side by side (`model.angleTiles`).
    var showsAnglesGrid: Bool { model.mode == .source && model.angleTiles != nil }

    var angleCells: [CGRect] {
        let gap = CGFloat(DrawTheme.Spacing.sm)
        let aspect = sequenceSize.height > 0 ? sequenceSize.width / sequenceSize.height : 16.0 / 9
        return AnglesGridLayout.cells(count: model.angleTiles?.count ?? 0, in: slot.insetBy(dx: gap, dy: gap), aspect: aspect, gap: gap)
    }

    func drawAnglesGrid(_ c: inout Canvas) {
        let t = theme
        guard let tiles = model.angleTiles else { return }
        for (i, r) in angleCells.enumerated() where i < tiles.count {
            let tile = tiles[i]
            c.fill(r, t.lane)
            if let pic = tile.picture { c.draw(imageSlot: pic.slot, in: r, source: (pic.u0, pic.v0, pic.u1, pic.v1)) }
            let s = DrawTheme.Spacing.self
            c.draw("\(i + 1)  \(tile.name)", at: CGPoint(x: r.minX + CGFloat(s.sm), y: r.minY + CGFloat(s.xs)),
                   fontSize: CGFloat(DrawTheme.TypeSize.caption), t.label)
            if tile.isActive || angleHover == i {
                c.stroke(polygon: r.insetBy(dx: 1, dy: 1).cornerPoints, width: tile.isActive ? 2 : 1, tile.isActive ? t.accent : t.label3)
            }
        }
    }

    // MARK: Drawing

    func drawPictureTools(_ c: inout Canvas) {
        let t = theme
        if let d = createDrag, d.isDrag(minimum: CreateToolDrag.minDrag) { drawCreateDrag(&c, d, t) }
        if let press = captionPress, press.moved { drawCaptionGuides(&c, press.guides, t) }
        if let s = stepWindowEdit { s.draw(&c, theme: t) }
        if let z = zoomEdit { z.layout(slot: slot); z.draw(&c, theme: t) }
    }

    /// ProgramSurfaceView's CreateToolPreviewView: the outline on a shadow, the size in a pill under it.
    private func drawCreateDrag(_ c: inout Canvas, _ d: CreateToolDrag, _ t: DrawTheme) {
        let o = CGPoint(x: slot.minX, y: slot.minY)
        func v(_ p: Vec2) -> CGPoint { CGPoint(x: o.x + p.x, y: o.y + p.y) }
        switch d.outline {
        case .box(let r, let ellipse):
            let rect = CGRect(x: o.x + r.minX, y: o.y + r.minY, width: r.width, height: r.height)
            if ellipse {
                c.stroke(ellipseIn: rect, width: 3, t.onPictureShadow)
                c.stroke(ellipseIn: rect, width: 1.5, t.onPictureStroke)
            } else {
                c.stroke(polygon: rect.cornerPoints, width: 3, t.onPictureShadow)
                c.stroke(polygon: rect.cornerPoints, width: 1.5, t.onPictureStroke)
            }
        case .line(let a, let b):
            c.strokeLine(from: v(a), to: v(b), width: 3, t.onPictureShadow)
            c.strokeLine(from: v(a), to: v(b), width: 1.5, t.onPictureStroke)
        case .stroke(let pts):
            let vp = pts.map(v)
            c.strokePolyline(vp, width: 3, t.onPictureShadow)
            c.strokePolyline(vp, width: 1.5, t.onPictureStroke)
        }
        guard let label = d.sizeLabel(viewPointsPerPixel: viewPointsPerPixel) else { return }
        let b = d.bounds.offsetBy(dx: o.x, dy: o.y)
        let w = c.size(of: label, fontSize: CGFloat(DrawTheme.TypeSize.caption)).width + 12, h: CGFloat = 16
        let pill = CGRect(x: (b.midX - w / 2).rounded(), y: b.maxY + CGFloat(DrawTheme.Spacing.xs), width: w, height: h)
        c.fill(roundedRect: pill, radius: h / 2, t.viewerHUD)
        c.draw(label, in: pill, fontSize: CGFloat(DrawTheme.TypeSize.caption), t.label, align: .center)
    }

    /// The center / safe-zone lines a caption drag snapped to (GuideLinesView on the Mac).
    private func drawCaptionGuides(_ c: inout Canvas, _ g: SnapGuides.Result, _ t: DrawTheme) {
        let r = canvasRect, k = CGFloat(viewPointsPerPixel)
        for x in g.verticalLines {
            let vx = r.midX + CGFloat(x) * k
            c.strokeLine(from: CGPoint(x: vx, y: r.minY), to: CGPoint(x: vx, y: r.maxY), width: 1, t.guideSnap)
        }
        for y in g.horizontalLines {
            let vy = r.midY + CGFloat(y) * k
            c.strokeLine(from: CGPoint(x: r.minX, y: vy), to: CGPoint(x: r.maxX, y: vy), width: 1, t.guideSnap)
        }
    }
}

extension CGRect {
    /// The four corners clockwise from the top-left (for `Canvas.stroke(polygon:)`).
    var cornerPoints: [CGPoint] {
        [CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: minY), CGPoint(x: maxX, y: maxY), CGPoint(x: minX, y: maxY)]
    }
}
