import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import SQCore
import SQUIKit
import SQDrawKit

/// The right pane of an opened keyframe row on the shared toolkit: `InlineSpeedGraphView` and `SpeedGraphPainter`
/// translated (geometry and every edit stay in `SpeedGraphGeometry` / `EffectControlsModel`). One hill per drawn row in
/// the row's color, a faint 0 baseline and a dashed Steady line; handles of selected keys; press: handle > key > curve >
/// marquee; right click: the curve presets plus the row's key items. Coordinates: points, y down, (0, 0) = the pane's
/// top-left.
@MainActor public final class InlineSpeedGraphDraw {
    public let property: EffectProperty
    public let model: EffectControlsModel
    public var theme = DrawTheme()
    public var size: CGSize = .zero

    /// A marquee that leaves the graph goes on over the lanes: rect in this pane's coordinates (nil when it ends),
    /// returns the lane keys inside. Set by the panel.
    var outerMarquee: (@MainActor (CGRect?) -> Set<SummaryMember>)?
    /// Items under the curve presets of the right-click menu (copy, paste, delete keys); set by the panel.
    var extraMenu: (@MainActor () -> [SQMenuItem])?

    struct Handle: Equatable {
        var property: EffectProperty
        var segment: EaseTrackSegment
        var side: EaseSide
        func isSame(_ o: Handle?) -> Bool {
            guard let o else { return false }
            return property == o.property && segment.from == o.segment.from && segment.to == o.segment.to && side == o.side
        }
    }
    private var drag: Handle?
    private var grabOffset: CGFloat = 0
    private var grabY: CGFloat = 0, pressY: CGFloat = 0, vertical = false
    private(set) var hovered: Handle?
    private struct Marquee { var origin: CGPoint; var additive: Bool; var base: Set<SummaryMember> }
    private var marquee: Marquee?
    public private(set) var marqueeRect: CGRect?

    public init(property: EffectProperty, model: EffectControlsModel) {
        self.property = property; self.model = model
    }

    // MARK: Content (as the Mac view)

    var curves: [(property: EffectProperty, segments: [EaseTrackSegment])] {
        model.speedGraphRows(for: property).map { ($0, model.speedSegments($0)) }
    }

    var geometry: SpeedGraphGeometry {
        SpeedGraphGeometry(lane: model.laneGeometry(width: size.width), height: size.height,
                           peak: SpeedGraphGeometry.peak(of: curves.flatMap(\.segments)))
    }

    private func hit(_ p: CGPoint) -> (SpeedGraphHit, [(property: EffectProperty, segments: [EaseTrackSegment])]) {
        let c = curves
        return (geometry.hitTest(p, rows: c.map(\.segments), selected: c.map { model.selectedKeyIDs($0.property) }), c)
    }

    func handle(at p: CGPoint) -> Handle? {
        let (h, c) = hit(p)
        guard case .handle(let r, let i, let side) = h else { return nil }
        return Handle(property: c[r].property, segment: c[r].segments[i], side: side)
    }

    /// Color of the n-th drawn row (`ControlsMetrics.curveColor`): accent, label, then the graph palette.
    func curveColor(_ index: Int) -> DrawColor {
        switch index {
        case 0: theme.accent
        case 1: theme.label
        default: theme.graphCurve[(index - 2) % theme.graphCurve.count]
        }
    }

    // MARK: Drawing (SpeedGraphPainter)

    typealias Look = SpeedGraphLook

    public func draw(_ c: inout Canvas) {
        let t = theme, bounds = CGRect(origin: .zero, size: size), geo = geometry
        c.saveGState()
        c.clip(to: bounds)
        c.fill(bounds, t.content)
        let b = geo.baseline, w = size.width
        c.fill(CGRect(x: 0, y: b.rounded(), width: w, height: 1), t.graphGrid)
        Self.dashedH(&c, y: (b - geo.unitHeight).rounded(), from: 0, to: w, t.graphGrid)
        c.fill(CGRect(x: 0, y: size.height - 1, width: w, height: 1), t.separator)
        for (i, row) in curves.enumerated() {
            drawRow(&c, geo, segments: row.segments, selected: model.selectedKeyIDs(row.property), color: curveColor(i)) { [hovered, drag] s, side in
                let this = Handle(property: row.property, segment: s, side: side)
                return this.isSame(hovered) || this.isSame(drag)
            }
        }
        if let m = marqueeRect {
            c.fill(m, t.accentTint)
            let e = m.insetBy(dx: 0.5, dy: 0.5)
            c.stroke(polygon: [CGPoint(x: e.minX, y: e.minY), CGPoint(x: e.maxX, y: e.minY), CGPoint(x: e.maxX, y: e.maxY),
                               CGPoint(x: e.minX, y: e.maxY)], width: 1, t.accent)
        }
        if model.playheadInClip {
            c.fill(CGRect(x: model.laneGeometry(width: w).x(for: model.localPlayhead).rounded() - 1, y: 0, width: 2, height: size.height),
                   t.playhead)
        }
        c.restoreGState()
    }

    /// A 2-on / 3-off dashed hairline (CGContext `setLineDash([2, 3])`).
    static func dashedH(_ c: inout Canvas, y: CGFloat, from x0: CGFloat, to x1: CGFloat, _ color: DrawColor) {
        var x = x0
        while x < x1 { c.fill(CGRect(x: x, y: y, width: min(2, x1 - x), height: 1), color); x += 5 }
    }
    static func dashedV(_ c: inout Canvas, x: CGFloat, from y0: CGFloat, to y1: CGFloat, _ color: DrawColor) {
        var y = y0
        while y < y1 { c.fill(CGRect(x: x, y: y, width: 1, height: min(2, y1 - y)), color); y += 5 }
    }

    private func drawRow(_ c: inout Canvas, _ geo: SpeedGraphGeometry, segments: [EaseTrackSegment], selected: Set<UUID>,
                         color: DrawColor, hot: (EaseTrackSegment, EaseSide) -> Bool) {
        Self.drawRow(&c, geo, width: size.width, theme: theme, segments: segments, selected: selected, color: color, hot: hot)
    }

    /// One row (SpeedGraphPainter.drawRow): the filled hill, key stems, the curve, handles of selected keys, the keys.
    static func drawRow(_ c: inout Canvas, _ geo: SpeedGraphGeometry, width: CGFloat, theme t: DrawTheme, segments: [EaseTrackSegment],
                        selected: Set<UUID>, color: DrawColor, hot: (EaseTrackSegment, EaseSide) -> Bool) {
        guard let first = segments.first, let last = segments.last else { return }
        let b = geo.baseline
        var line = [CGPoint(x: 0, y: b), CGPoint(x: geo.x(first, share: 0), y: b)]
        for s in segments { line += geo.points(s) }
        line += [CGPoint(x: geo.x(last, share: 1), y: b), CGPoint(x: width, y: b)]
        if color.a > 0 { c.fill(polygon: line, color.alpha(Float(Look.fillAlpha))) }
        for k in geo.keyPoints(segments) { Self.dashedV(&c, x: k.point.x.rounded(), from: 0, to: k.point.y, t.graphGrid) }
        if color.a > 0 { c.strokePolyline(line, width: Look.curveWidth, color) }
        for h in geo.visibleHandles(segments, selected: selected) {
            let s = segments[h.segment]
            let k = geo.key(s, side: h.side), e = geo.handleEnd(s, side: h.side)
            let isHot = hot(s, h.side), y = k.y.rounded()
            c.fill(CGRect(x: min(k.x, e.x), y: y, width: abs(e.x - k.x), height: Look.stemWidth), t.graphHandleLine)
            let d = Look.knobDiameter + (isHot ? 2 : 0)
            let knob = CGRect(x: e.x - d / 2, y: y + 0.5 - d / 2, width: d, height: d)
            c.fill(ellipseIn: knob, isHot ? t.accent : t.label2)
            c.fill(ellipseIn: knob.insetBy(dx: Look.knobRing, dy: Look.knobRing), t.content)
        }
        for k in geo.keyPoints(segments) {
            c.fill(polygon: InspectorDraw.diamond(k.point, size: Look.keySide * 2.0.squareRoot()),
                   selected.contains(k.id) ? t.accent : t.keyframe)
        }
    }

    // MARK: Mouse (InlineSpeedGraphView.press / dragGesture / release)

    public func mouseMoved(to p: CGPoint?) {
        guard drag == nil, marquee == nil else { return }
        hovered = p.flatMap(handle(at:))
    }

    public func press(at p: CGPoint, shift: Bool) {
        if beginDrag(at: p) { return }
        let (h, c) = hit(p)
        switch h {
        case .handle: return
        case .key(let r, let id):
            var ids = model.selectedKeyIDs(c[r].property)
            if shift { if ids.contains(id) { ids.remove(id) } else { ids.insert(id) } }
            else if !ids.contains(id) { ids = [id] }
            select(rows: c, [c[r].property: ids], replacing: !shift)
        case .curve(let r, let i):
            let s = c[r].segments[i]
            let ids: Set<UUID> = shift ? model.selectedKeyIDs(c[r].property).union([s.from, s.to]) : [s.from, s.to]
            select(rows: c, [c[r].property: ids], replacing: !shift)
        case .empty:
            if !shift { model.clearSelection() }
            marquee = Marquee(origin: p, additive: shift, base: shift ? model.selection : [])
        }
    }

    public func dragGesture(to p: CGPoint, shift: Bool = false) {
        if drag != nil { continueDrag(to: p, shift: shift); return }
        guard let m = marquee else { return }
        let rect = CGRect(x: min(m.origin.x, p.x), y: min(m.origin.y, p.y), width: abs(p.x - m.origin.x), height: abs(p.y - m.origin.y))
        marqueeRect = rect
        let c = curves
        let hits = geometry.keys(in: rect, rows: c.map(\.segments),
                                 selected: c.map { row in Set(m.base.filter { $0.property == row.property.id }.map(\.keyID)) })
        var sel = m.base
        for (r, ids) in hits { for id in ids { sel.insert(SummaryMember(property: c[r].property.id, keyID: id)) } }
        sel.formUnion(outerMarquee?(rect) ?? [])
        if sel != model.selection { model.select(Array(sel), extend: false) }
    }

    public func release() {
        if drag != nil { endDrag(); return }
        if marquee != nil { _ = outerMarquee?(nil) }
        marquee = nil; marqueeRect = nil
    }

    public var isDragging: Bool { drag != nil || marquee != nil }

    private func select(rows: [(property: EffectProperty, segments: [EaseTrackSegment])], _ ids: [EffectProperty: Set<UUID>], replacing: Bool) {
        for r in rows {
            if let s = ids[r.property] { if model.selectedKeyIDs(r.property) != s { model.setSelection(for: r.property, ids: s) } }
            else if replacing, !model.selectedKeyIDs(r.property).isEmpty { model.setSelection(for: r.property, ids: []) }
        }
    }

    @discardableResult
    func beginDrag(at p: CGPoint) -> Bool {
        guard let h = handle(at: p) else { return false }
        grabOffset = geometry.handleTrueEnd(h.segment, side: h.side).x - p.x
        let speed = h.side == .in ? h.segment.shape.speedIn : h.segment.shape.speedOut
        grabY = geometry.baseline - CGFloat(speed * h.segment.scale) * geometry.unitHeight - p.y
        pressY = p.y; vertical = false
        model.selectSpeedSegment(h.property, from: h.segment.from, to: h.segment.to)
        model.beginGesture()
        drag = h
        return true
    }

    func continueDrag(to p: CGPoint, shift: Bool = false) {
        guard let h = drag else { return }
        let reach = geometry.reach(atX: p.x + grabOffset, h.segment, side: h.side)
        vertical = EaseHandleDragMath.isVertical(wasVertical: vertical, pressY: pressY, y: p.y, shift: shift)
        guard vertical, h.segment.scale > 0 else {
            model.setReach(reach, side: h.side, for: property)
            return
        }
        let pointer = geometry.speed(atY: p.y + grabY) / h.segment.scale
        let speed = EaseHandleDragMath.speed(vertical: true, pointer: pointer, kept: 0, reach: max(reach, SpeedHill.minReach),
                                             valueRange: -2...3)
        model.setHandle(reach: reach, speed: speed, side: h.side, for: property)
    }

    func endDrag() {
        guard drag != nil else { return }
        model.endGesture()
        drag = nil
    }

    // MARK: Right click (InlineSpeedGraphView.rightMouseDown)

    /// Selects what the right click is over (as the Mac view), then returns the menu: presets, then the key items.
    public func contextMenu(at p: CGPoint) -> [SQMenuItem] {
        let (h, c) = hit(p)
        switch h {
        case .key(let r, let id) where !model.selectedKeyIDs(c[r].property).contains(id):
            select(rows: c, [c[r].property: [id]], replacing: true)
        case .curve(let r, let i):
            let s = c[r].segments[i]
            if !model.selectedKeyIDs(c[r].property).isSuperset(of: [s.from, s.to]) {
                select(rows: c, [c[r].property: [s.from, s.to]], replacing: true)
            }
        default: break
        }
        return curveMenuItems()
    }

    /// Steady, Smooth, Smooth In, Smooth Out, Hold, Hold Ahead (applied to the selected keys), then the row's key items.
    func curveMenuItems() -> [SQMenuItem] {
        let on = model.speedChip(for: property)
        let ahead = !property.isAnimationRow && model.selectionTakesHoldAhead
        let model = model, property = property
        var items = SpeedCurveChip.allCases.filter { $0 != .holdAhead || ahead }.map { chip in
            SQMenuItem(title: chip.title, isChecked: chip == on) { model.applySpeedChip(chip, for: property) }
        }
        if let extra = extraMenu?(), !extra.isEmpty { items.append(.separator); items += extra }
        return items
    }
}
