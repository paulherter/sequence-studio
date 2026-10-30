import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import SQAudioFX
import SQCore
import SQUIKit
import SQDrawKit

/// The drawn editors of Effect Controls rows (curves, EQ curve, speed graph), translated from their Mac views.
extension EffectControlsDrawPanel {
    func rowSurfaceWidgets(_ r: EffectRow) -> [Widget]? {
        let key = Self.rowKey(r.kind)
        switch r.kind {
        case .curves(let effect):
            // ColorCurvesRow.layout: the channel dots in one row on top, the plot from the label column to the trailing inset.
            return [Widget(key: key + ".curves", frame: CGRect(x: 0, y: 0, width: size.width, height: r.height),
                           kind: .surface({ [model] in ColorCurvesSurface(effect: effect, model: model) }))]
        case .eqCurve(let effect):
            // EQCurveRow.layout: label column to the trailing inset, 4 pt above and below.
            let f = CGRect(x: ControlsGrid.labelX, y: 4, width: max(size.width - ControlsGrid.labelX - ControlsGrid.trailing, 40),
                           height: max(r.height - 8, 40))
            return [Widget(key: key + ".curve", frame: f, kind: .surface({ [model] in EQCurveSurface(effect: effect, model: model) }),
                           help: "Drag a point: frequency and gain. Scroll or Option-drag: Q. Double-click: reset the band.")]
        default:
            return nil
        }
    }
}

/// ColorCurvesRow (ChannelDots + CurveEditorView) on the canvas: pick a channel, click to add a point, drag to move,
/// double-click or Cmd-click to remove it, Shift locks x. One drag = one gesture on the model.
@MainActor final class ColorCurvesSurface: DrawSurface {
    let effect: ClipEffect.ID
    let model: EffectControlsModel
    private(set) var channel = 0
    private var dragIndex: Int?
    private var hoverIndex: Int?
    /// The points shown: an edit shows at once (CurveEditorView.edit), the model write follows.
    private var shown: [CurvePoint]?

    static let dot: CGFloat = 9, dotGap: CGFloat = 10
    static let names = ["Master", "Red", "Green", "Blue"]

    init(effect: ClipEffect.ID, model: EffectControlsModel) { self.effect = effect; self.model = model }

    private var points: [CurvePoint] {
        if let shown { return shown }
        let c = model.colorCurves(effect)
        return switch channel { case 1: c.red; case 2: c.green; case 3: c.blue; default: c.master }
    }

    // MARK: Layout (ColorCurvesRow.layout, ChannelDots.rect, CurveEditorView.plot)

    func dotsFrame(_ rect: CGRect) -> CGRect {
        let dw = 4 * Self.dot + 3 * Self.dotGap + 10
        return CGRect(x: rect.minX + max((rect.width - dw) / 2, ControlsGrid.toggleX), y: rect.minY, width: dw, height: ControlsGrid.rowHeight)
    }

    func dotRect(_ i: Int, _ rect: CGRect) -> CGRect {
        let f = dotsFrame(rect)
        let total = 4 * Self.dot + 3 * Self.dotGap
        let x0 = (f.minX + (f.width - total) / 2).rounded()
        return CGRect(x: x0 + CGFloat(i) * (Self.dot + Self.dotGap), y: f.minY + 6, width: Self.dot, height: Self.dot)
    }

    func plot(_ rect: CGRect) -> CGRect {
        let top = ControlsGrid.rowHeight
        let editor = CGRect(x: rect.minX + ControlsGrid.labelX, y: rect.minY + top,
                            width: max(rect.width - ControlsGrid.labelX - ControlsGrid.trailing, 40),
                            height: max(rect.height - top - ControlsGrid.gap, 40))
        return editor.insetBy(dx: 6, dy: 6)
    }

    private func toData(_ p: CGPoint, _ r: CGRect) -> (Float, Float) {
        (Float((p.x - r.minX) / max(r.width, 1)), Float(1 - (p.y - r.minY) / max(r.height, 1)))
    }

    private func toView(_ q: CurvePoint, _ r: CGRect) -> CGPoint {
        CGPoint(x: r.minX + CGFloat(q.x) * r.width, y: r.minY + (1 - CGFloat(q.y)) * r.height)
    }

    private func pointIndex(_ p: CGPoint, _ r: CGRect) -> Int? {
        CurveEditing.hit(points, x: p.x - r.minX, y: p.y - r.minY, size: r.size)
    }

    // MARK: Drawing

    func draw(_ c: inout Canvas, in rect: CGRect, theme t: DrawTheme, panel: EffectControlsDrawPanel) {
        let colors = t.channelDots
        for i in 0..<4 {
            let d = dotRect(i, rect)
            c.fill(ellipseIn: d, colors[i])
            if i == channel { c.stroke(ellipseIn: d.insetBy(dx: -2.5, dy: -2.5), width: 1, t.label) }
        }
        let r = plot(rect)
        c.fill(roundedRect: r, radius: 4, t.field)
        for i in 1..<4 {
            let f = CGFloat(i) / 4
            c.strokeLine(from: CGPoint(x: r.minX + f * r.width, y: r.minY), to: CGPoint(x: r.minX + f * r.width, y: r.maxY), width: 0.5, t.fieldEdge)
            c.strokeLine(from: CGPoint(x: r.minX, y: r.minY + f * r.height), to: CGPoint(x: r.maxX, y: r.minY + f * r.height), width: 0.5, t.fieldEdge)
        }
        c.strokeLine(from: CGPoint(x: r.minX, y: r.maxY), to: CGPoint(x: r.maxX, y: r.minY), width: 0.5, t.fieldEdge)
        let pts = points
        let spline = CurveMath.Spline(CurveMath.normalized(pts))
        let n = 96
        let line = (0...n).map { i -> CGPoint in
            let x = Float(i) / Float(n)
            return toView(CurvePoint(x, spline.value(x)), r)
        }
        let lineColor: DrawColor = switch channel { case 1: t.red; case 2: t.green; case 3: t.channelBlue; default: t.label }
        c.strokePolyline(line, width: 1.5, lineColor)
        for (i, q) in pts.enumerated() {
            let p = toView(q, r)
            let dot = CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)
            c.fill(ellipseIn: dot, i == dragIndex ? t.accent : i == hoverIndex ? t.accentFill : t.label)
            c.stroke(ellipseIn: dot, width: 1, t.handleShadow)
        }
    }

    // MARK: Pointer (ChannelDots.mouseDown, CurveEditorView mouse handling)

    func mouseDown(at p: CGPoint, in rect: CGRect, clickCount: Int, modifiers: InputModifiers) {
        if let i = (0..<4).first(where: { dotRect($0, rect).insetBy(dx: -Self.dotGap / 2, dy: -6).contains(p) }) {
            channel = i; shown = nil
            return
        }
        let r = plot(rect)
        guard r.insetBy(dx: -6, dy: -6).contains(p) else { return }
        let hit = pointIndex(p, r)
        if clickCount == 2 || (modifiers.contains(.command) && hit != nil) {
            model.beginGesture()
            if let hit { edit(CurveEditing.remove(points, index: hit)) }
            model.endGesture()
            shown = nil
            return
        }
        model.beginGesture()
        let (x, y) = toData(p, r)
        if let hit { dragIndex = hit } else {
            let added = CurveEditing.add(points, x: x, y: y)
            dragIndex = added.index
            edit(added.points)
        }
    }

    func mouseDragged(to p: CGPoint, in rect: CGRect, modifiers: InputModifiers) {
        guard let i = dragIndex else { return }
        var (x, y) = toData(p, plot(rect))
        let pts = points
        if modifiers.contains(.shift), pts.indices.contains(i) { x = pts[i].x }   // Shift locks x
        edit(CurveEditing.move(pts, index: i, to: x, y))
    }

    func mouseUp(at p: CGPoint, in rect: CGRect) {
        if dragIndex != nil { dragIndex = nil; model.endGesture() }
        shown = nil
        hoverIndex = pointIndex(p, plot(rect))
    }

    func mouseMoved(to p: CGPoint?, in rect: CGRect) { hoverIndex = p.flatMap { pointIndex($0, plot(rect)) } }

    func help(at p: CGPoint, in rect: CGRect) -> String? {
        if let i = (0..<4).first(where: { dotRect($0, rect).insetBy(dx: -Self.dotGap / 2, dy: -6).contains(p) }) {
            return SQL10n.string(Self.names[i])
        }
        return nil
    }

    private func edit(_ new: [CurvePoint]) {
        shown = new
        var c = model.colorCurves(effect)
        switch channel { case 1: c.red = new; case 2: c.green = new; case 3: c.blue = new; default: c.master = new }
        model.setColorCurves(effect, c)
    }
}

/// EQCurveView on the canvas: the combined response of the Parametric EQ with one point per band. Drag = frequency and
/// gain, Option-drag or scroll = Q, double-click resets the band; one drag or scroll = one gesture on the model.
@MainActor final class EQCurveSurface: DrawSurface {
    let effect: ClipEffect.ID
    let model: EffectControlsModel
    private(set) var dragFilter: Int?
    private var dragStart: (point: CGPoint, q: Double)?
    private var qDrag = false
    private var scrolling: (filter: Int, startQ: Double, dy: CGFloat)?

    static let handleRadius: CGFloat = 6, hitRadius: CGFloat = 12, labelBand: CGFloat = 16

    init(effect: ClipEffect.ID, model: EffectControlsModel) { self.effect = effect; self.model = model }

    func geometry(_ rect: CGRect) -> EQCurveGeometry {
        EQCurveGeometry(plot: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(rect.height - Self.labelBand, 1)))
    }

    func pointPosition(_ i: Int, _ v: AudioParametricEQValues, _ g: EQCurveGeometry) -> CGPoint {
        let b = v[i]
        let db = (i == 0 || i == 8) ? ParametricEQResponse.totalDB(v, hz: b.hz) : b.gainDB
        return CGPoint(x: g.x(hz: b.hz), y: g.y(db: db))
    }

    func filter(at p: CGPoint, _ rect: CGRect) -> Int? {
        guard let v = model.eqValues(effect) else { return nil }
        let g = geometry(rect)
        var best: (Int, CGFloat)?
        for i in 0..<AudioParametricEQValues.bandCount where v[i].on {
            let c = pointPosition(i, v, g)
            let d = CGFloat(hypot(Double(c.x - p.x), Double(c.y - p.y)))
            if d <= Self.hitRadius, d < (best?.1 ?? .infinity) { best = (i, d) }
        }
        return best?.0
    }

    func draw(_ c: inout Canvas, in rect: CGRect, theme t: DrawTheme, panel: EffectControlsDrawPanel) {
        let g = geometry(rect), plot = g.plot
        c.fill(roundedRect: plot, radius: 6, t.field)
        c.saveGState()
        c.clip(to: plot)
        for hz in EQCurveGeometry.gridHz {
            let decade = EQCurveGeometry.decadeHz.contains(hz)
            c.fill(CGRect(x: g.x(hz: hz), y: plot.minY, width: 1, height: plot.height),
                   decade ? t.separator : t.separator.alpha(t.separator.a * InspectorTokens.disabledAlpha))
        }
        for db in EQCurveGeometry.gridDB {
            c.fill(CGRect(x: plot.minX, y: g.y(db: db), width: plot.width, height: 1),
                   db == 0 ? t.label3.alpha(t.label3.a * InspectorTokens.disabledAlpha) : t.separator)
        }
        guard let v = model.eqValues(effect) else { c.restoreGState(); return }
        let freqs = g.sampleFrequencies()
        var dbs: [Double] = []
        ParametricEQResponse.totalDB(v, at: freqs, into: &dbs)
        let line = freqs.indices.map { CGPoint(x: g.x(hz: freqs[$0]), y: g.y(db: dbs[$0])) }
        let zero = g.y(db: 0)
        if let first = line.first, let last = line.last {
            c.fill(polygon: [CGPoint(x: first.x, y: zero)] + line + [CGPoint(x: last.x, y: zero)], t.accentTint)
        }
        c.strokePolyline(line, width: InspectorTokens.focusLineWidth, t.accent)
        c.restoreGState()
        let caption = CGFloat(DrawTheme.TypeSize.caption)
        for (hz, text) in [(100.0, "100"), (1_000, "1k"), (10_000, "10k")] {
            c.draw(text, in: CGRect(x: g.x(hz: hz) - 20, y: plot.maxY + 1, width: 40, height: Self.labelBand - 1), fontSize: caption, t.label3,
                   align: .center)
        }
        for db in [-12.0, -6, 6, 12] {
            c.draw(String(format: "%+.0f", db), in: CGRect(x: plot.minX + 4, y: g.y(db: db) - 14, width: 30, height: 13), fontSize: caption, t.label3)
        }
        let r = Self.handleRadius
        for i in 0..<AudioParametricEQValues.bandCount {
            let p = pointPosition(i, v, g)
            let dot = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
            if v[i].on {
                c.fill(ellipseIn: dot, dragFilter == i ? t.accent : t.label)
                c.stroke(ellipseIn: dot, width: 1, t.divider)
            } else {
                c.stroke(ellipseIn: dot, width: 1, t.label3.alpha(t.label3.a * InspectorTokens.disabledAlpha))
            }
        }
    }

    func mouseDown(at p: CGPoint, in rect: CGRect, clickCount: Int, modifiers: InputModifiers) {
        endScroll()
        guard let i = filter(at: p, rect), let v = model.eqValues(effect) else { return }
        if clickCount == 2 { model.beginGesture(); model.resetEQBand(effect, filter: i); model.endGesture(); return }
        dragFilter = i
        qDrag = modifiers.contains(.option) && EQCurveGeometry.hasGain(i)
        dragStart = (p, v[i].q)
        model.beginGesture()
    }

    func mouseDragged(to p: CGPoint, in rect: CGRect, modifiers: InputModifiers) {
        guard let i = dragFilter, let start = dragStart else { return }
        if qDrag {
            model.setEQBand(effect, filter: i, hz: nil, gainDB: nil, q: EQCurveGeometry.qFactor(start: start.q, dy: start.point.y - p.y))
        } else {
            let g = geometry(rect)
            model.setEQBand(effect, filter: i, hz: g.hz(x: p.x), gainDB: EQCurveGeometry.hasGain(i) ? g.db(y: p.y) : nil, q: nil)
        }
    }

    func mouseUp(at p: CGPoint, in rect: CGRect) {
        guard dragFilter != nil else { return }
        dragFilter = nil; dragStart = nil; qDrag = false
        model.endGesture()
    }

    func mouseMoved(to p: CGPoint?, in rect: CGRect) { if p == nil { endScroll() } }

    /// One scroll gesture = one begin / end pair; Q accumulates from the Q at its start.
    /// shortcut: the gesture ends when the pointer leaves the curve or presses (no idle timer in the portable panel);
    /// upgrade with a host clock tick.
    func scroll(at p: CGPoint, in rect: CGRect, dy: CGFloat) -> Bool {
        var dy = dy
        if let g = ScrollGesture.published {
            // EQCurveView.scrollWheel: the raw deltaY, a wheel line counts 4 (not the list's pixels); a pinch is no Q.
            guard g.isScroll else { return false }
            dy = CGFloat(g.precise ? g.deltaY : g.deltaY * 4)
        }
        if scrolling == nil {
            guard let i = filter(at: p, rect), EQCurveGeometry.hasGain(i), let v = model.eqValues(effect) else { return false }
            scrolling = (i, v[i].q, 0)
            model.beginGesture()
        }
        guard var st = scrolling else { return false }
        st.dy += dy; scrolling = st
        model.setEQBand(effect, filter: st.filter, hz: nil, gainDB: nil, q: EQCurveGeometry.qFactor(start: st.startQ, dy: st.dy))
        return true
    }

    func endScroll() {
        guard scrolling != nil else { return }
        scrolling = nil
        model.endGesture()
    }
}
