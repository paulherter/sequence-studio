import AppKit
import SQCore

/// Draws a speed graph: the one look of the Controls row (`InlineSpeedGraphView`) and of the transition curve editor
/// (`EaseSpeedEditorView`), so the two cannot drift apart.
enum SpeedGraphPainter {
    typealias Look = SpeedGraphLook

    /// Fill plus the only two reference lines: speed 0 and the dashed Steady (1.0x) line. No grid, no labels.
    static func drawBackground(_ ctx: CGContext, _ geo: SpeedGraphGeometry, bounds: CGRect) {
        let w = bounds.width, b = geo.baseline, u = geo.unitHeight
        ctx.setFillColor(Theme.Colors.content.cgColor); ctx.fill(bounds)
        ctx.setFillColor(ControlsColors.graphGrid.cgColor)
        ctx.fill(CGRect(x: 0, y: b.rounded(), width: w, height: 1))
        ctx.saveGState()
        ctx.setStrokeColor(ControlsColors.graphGrid.cgColor); ctx.setLineWidth(1); ctx.setLineDash(phase: 0, lengths: [2, 3])
        let sy = (b - u).rounded() + 0.5
        ctx.move(to: CGPoint(x: 0, y: sy)); ctx.addLine(to: CGPoint(x: w, y: sy)); ctx.strokePath()
        ctx.restoreGState()
    }

    /// The path of one row: flat at the baseline outside the keys, one hill (or flat line) per segment.
    static func curvePath(_ geo: SpeedGraphGeometry, segments: [EaseTrackSegment], width: CGFloat) -> CGPath {
        let path = CGMutablePath(), b = geo.baseline
        guard let first = segments.first, let last = segments.last else { return path }
        path.move(to: CGPoint(x: 0, y: b)); path.addLine(to: CGPoint(x: geo.x(first, share: 0), y: b))
        for s in segments { for p in geo.points(s) { path.addLine(to: p) } }
        path.addLine(to: CGPoint(x: geo.x(last, share: 1), y: b)); path.addLine(to: CGPoint(x: width, y: b))
        return path
    }

    /// One row: curve, the handles of its selected keys (hairline stem, small round knob; `hot` = hovered or dragged),
    /// then its keys as diamonds (selected ones in the accent).
    static func drawRow(_ ctx: CGContext, _ geo: SpeedGraphGeometry, bounds: CGRect, segments: [EaseTrackSegment], selected: Set<UUID>,
                        color: NSColor, hot: (EaseTrackSegment, EaseSide) -> Bool) {
        guard !segments.isEmpty else { return }
        // A peak taller than the plot runs off the top: clipped at the edge.
        ctx.saveGState()
        ctx.clip(to: bounds)
        let path = curvePath(geo, segments: segments, width: bounds.width)
        // A faint fill between the curve and the baseline, and a dashed guide from the top of the graph down to every key
        // (v9 `.kgd`): the keys of the row above and their speed read as one.
        ctx.addPath(path); ctx.closePath()
        ctx.setFillColor(color.withAlphaComponent(Look.fillAlpha).cgColor); ctx.fillPath()
        ctx.setStrokeColor(ControlsColors.graphGrid.cgColor); ctx.setLineWidth(1); ctx.setLineDash(phase: 0, lengths: [2, 3])
        for k in geo.keyPoints(segments) {
            let x = k.point.x.rounded() + 0.5
            ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: k.point.y)); ctx.strokePath()
        }
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(Look.curveWidth); ctx.setLineJoin(.round)
        ctx.addPath(path); ctx.strokePath()
        ctx.restoreGState()
        for h in geo.visibleHandles(segments, selected: selected) {
            let s = segments[h.segment]
            let k = geo.key(s, side: h.side), e = geo.handleEnd(s, side: h.side)
            let isHot = hot(s, h.side)
            ctx.setStrokeColor(Theme.Colors.graphHandleLine.cgColor); ctx.setLineWidth(Look.stemWidth)
            let y = k.y.rounded() + 0.5
            ctx.move(to: CGPoint(x: k.x, y: y)); ctx.addLine(to: CGPoint(x: e.x, y: y)); ctx.strokePath()
            let d = Look.knobDiameter + (isHot ? 2 : 0)
            // Hollow knob: content fill with an inner ring (accent while hovered or dragged).
            let knob = CGRect(x: e.x - d / 2, y: y - d / 2, width: d, height: d)
            ctx.setFillColor((isHot ? Theme.Colors.accent : Theme.Colors.label2).cgColor); ctx.fillEllipse(in: knob)
            ctx.setFillColor(Theme.Colors.content.cgColor); ctx.fillEllipse(in: knob.insetBy(dx: Look.knobRing, dy: Look.knobRing))
        }
        for k in geo.keyPoints(segments) {
            ctx.addPath(KeyGlyphPath.cgDiamond(centre: k.point, side: Look.keySide))
            ctx.setFillColor((selected.contains(k.id) ? Theme.Colors.accent : Theme.Colors.keyframe).cgColor); ctx.fillPath()
        }
    }
}

/// The right pane of an opened keyframe row: a minimal speed graph (feedback 2026-10-05: back to the first, uncluttered
/// version). One hill per drawn row in the row's color, flat at the baseline before the first and after the last key,
/// a faint 0 baseline and a faint dashed Steady line, no labels. Keys are diamonds; the handles of selected keys are a
/// thin stem with a small round knob. Press: handle > key > curve > empty space (marquee). Right-click: curve presets
/// for the selected keys. Every edit goes through `EffectControlsModel`.
final class InlineSpeedGraphView: NSView {
    let property: EffectProperty
    let model: EffectControlsModel
    private let playheadLine = PlayheadLineView(color: Theme.Colors.playhead)

    struct Handle: Equatable {
        var property: EffectProperty
        var segment: EaseTrackSegment
        var side: EaseSide
        /// The same handle whatever its segment's shape is right now.
        func isSame(_ o: Handle?) -> Bool {
            guard let o else { return false }
            return property == o.property && segment.from == o.segment.from && segment.to == o.segment.to && side == o.side
        }
    }
    private var drag: Handle?
    /// x of the grabbed handle's true end minus the pointer's x at the press (the handle never jumps under the pointer).
    private var grabOffset: CGFloat = 0
    /// Pointer height at the press minus the handle's true height (speed) there; the vertical part latches past the dead zone.
    private var grabY: CGFloat = 0, pressY: CGFloat = 0, vertical = false
    private(set) var hovered: Handle? { didSet { if oldValue != hovered { needsDisplay = true } } }
    private var tracking: NSTrackingArea?

    /// A running marquee: press point, shift (adds to the selection) and the selection it adds to.
    private struct Marquee { var origin: CGPoint; var additive: Bool; var base: Set<SummaryMember> }
    /// The keyframe lanes around this graph: a marquee is not bound to the graph, dragged out of it (up over the row's
    /// diamonds) it keeps selecting there. Called with the marquee in this view's coordinates (nil when it ends),
    /// returns the lane keys inside. Set by the panel.
    var outerMarquee: (@MainActor (CGRect?, NSView) -> Set<SummaryMember>)?
    private var marquee: Marquee?
    private(set) var marqueeRect: CGRect? { didSet { if oldValue != marqueeRect { needsDisplay = true } } }
    /// Extra items appended under the curve presets of the right-click menu (copy, paste, delete keys); set by the row.
    var extraMenu: (@MainActor () -> [SQMenuItem])?

    init(property: EffectProperty, model: EffectControlsModel) {
        self.property = property; self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(playheadLine)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(property.title) speed graph")
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Content

    /// The rows drawn (the opened one first) with their segments.
    var curves: [(property: EffectProperty, segments: [EaseTrackSegment])] {
        model.speedGraphRows(for: property).map { ($0, model.speedSegments($0)) }
    }

    var geometry: SpeedGraphGeometry {
        SpeedGraphGeometry(lane: model.laneGeometry(width: bounds.width), height: bounds.height,
                           peak: SpeedGraphGeometry.peak(of: curves.flatMap(\.segments)))
    }

    private func hit(_ p: CGPoint) -> (SpeedGraphHit, [(property: EffectProperty, segments: [EaseTrackSegment])]) {
        let c = curves
        return (geometry.hitTest(p, rows: c.map(\.segments), selected: c.map { model.selectedKeyIDs($0.property) }), c)
    }

    /// The handle at `p`, if a visible handle is hit.
    func handle(at p: CGPoint) -> Handle? {
        let (h, c) = hit(p)
        guard case .handle(let r, let i, let side) = h else { return nil }
        return Handle(property: c[r].property, segment: c[r].segments[i], side: side)
    }

    private struct ContentKey: Equatable {
        var revision: Int; var selection: Set<SummaryMember>; var viewport: KeyframeViewport; var size: CGSize
        var rows: [EffectProperty]
    }
    private var drawnKey: ContentKey?

    /// Model change: redraws only when what the graph shows changed (never on a playhead tick).
    func refresh() {
        let key = ContentKey(revision: model.clipRevision, selection: model.selection, viewport: model.viewport, size: bounds.size,
                             rows: model.speedGraphRows(for: property))
        if key != drawnKey { drawnKey = key; needsDisplay = true }
        movePlayhead()
    }

    func movePlayhead() {
        playheadLine.isHidden = !model.playheadInClip
        guard model.playheadInClip else { return }
        let x = model.laneGeometry(width: bounds.width).x(for: model.localPlayhead).rounded()
        playheadLine.frame = PlayheadLineView.frame(centerX: x, height: bounds.height)
    }

    override func layout() { super.layout(); movePlayhead() }

    // MARK: Drawing

    typealias Look = SpeedGraphPainter.Look

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let geo = geometry
        SpeedGraphPainter.drawBackground(ctx, geo, bounds: bounds)
        ctx.setFillColor(Theme.Colors.separator.cgColor)
        ctx.fill(CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1))
        for (i, c) in curves.enumerated() {
            SpeedGraphPainter.drawRow(ctx, geo, bounds: bounds, segments: c.segments, selected: model.selectedKeyIDs(c.property),
                                      color: ControlsMetrics.curveColor(i)) { [hovered, drag] s, side in
                let this = Handle(property: c.property, segment: s, side: side)
                return this.isSame(hovered) || this.isSame(drag)
            }
        }
        if let m = marqueeRect {
            ctx.setFillColor(Theme.Colors.accentTint.cgColor); ctx.fill(m)
            ctx.setStrokeColor(Theme.Colors.accent.cgColor); ctx.setLineWidth(1)
            ctx.stroke(m.insetBy(dx: 0.5, dy: 0.5))
        }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }

    override func mouseMoved(with event: NSEvent) {
        guard drag == nil, marquee == nil else { return }
        hovered = handle(at: convert(event.locationInWindow, from: nil))
        KeyframeCursor.cursor(overGrip: hovered != nil, dragging: false).set()
    }
    override func mouseExited(with event: NSEvent) { if drag == nil { hovered = nil; NSCursor.arrow.set() } }

    override func mouseDown(with event: NSEvent) {
        press(at: convert(event.locationInWindow, from: nil), shift: event.modifierFlags.contains(.shift))
    }
    override func mouseDragged(with event: NSEvent) {
        dragGesture(to: convert(event.locationInWindow, from: nil), shift: event.modifierFlags.contains(.shift))
    }
    override func mouseUp(with event: NSEvent) { release() }

    /// A press (tests drive the gesture through `press`, `dragGesture`, `release`): grabs a handle, selects a key or the
    /// two keys of a curve segment, or starts a marquee in empty space.
    func press(at p: CGPoint, shift: Bool) {
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
            if !shift { model.clearSelection(); needsDisplay = true }
            marquee = Marquee(origin: p, additive: shift, base: shift ? model.selection : [])
        }
    }

    func dragGesture(to p: CGPoint, shift: Bool = false) {
        if drag != nil { continueDrag(to: p, shift: shift); return }
        guard let m = marquee else { return }
        let rect = CGRect(x: min(m.origin.x, p.x), y: min(m.origin.y, p.y), width: abs(p.x - m.origin.x), height: abs(p.y - m.origin.y))
        marqueeRect = rect
        let c = curves
        let hits = geometry.keys(in: rect, rows: c.map(\.segments),
                                 selected: c.map { row in Set(m.base.filter { $0.property == row.property.id }.map(\.keyID)) })
        var sel = m.base
        for (r, ids) in hits { for id in ids { sel.insert(SummaryMember(property: c[r].property.id, keyID: id)) } }
        // Outside the graph the marquee goes on over the lanes (their diamonds select by row and time).
        sel.formUnion(outerMarquee?(rect, self) ?? [])
        if sel != model.selection { model.select(Array(sel), extend: false) }
        needsDisplay = true
    }

    func release() {
        if drag != nil { endDrag(); return }
        if marquee != nil { _ = outerMarquee?(nil, self) }
        marquee = nil; marqueeRect = nil
    }

    /// Writes the selection of the drawn rows: `replacing` clears the rows not named.
    private func select(rows: [(property: EffectProperty, segments: [EaseTrackSegment])], _ ids: [EffectProperty: Set<UUID>], replacing: Bool) {
        for r in rows {
            if let s = ids[r.property] { if model.selectedKeyIDs(r.property) != s { model.setSelection(for: r.property, ids: s) } }
            else if replacing, !model.selectedKeyIDs(r.property).isEmpty { model.setSelection(for: r.property, ids: []) }
        }
        needsDisplay = true
    }

    /// Grabs the handle at `p`.
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
        KeyframeCursor.cursor(overGrip: true, dragging: true).set()
        return true
    }

    func continueDrag(to p: CGPoint, shift: Bool = false) {
        guard let h = drag else { return }
        // 100 % reach sits at the middle of the segment. Sideways sets the reach; past the dead zone the height sets
        // the speed at the key too (Shift: sideways only). One gesture, so one undo step.
        let reach = geometry.reach(atX: p.x + grabOffset, h.segment, side: h.side)
        vertical = EaseHandleDragMath.isVertical(wasVertical: vertical, pressY: pressY, y: p.y, shift: shift)
        guard vertical, h.segment.scale > 0 else {
            model.setReach(reach, side: h.side, for: property)
            needsDisplay = true
            return
        }
        let pointer = geometry.speed(atY: p.y + grabY) / h.segment.scale
        let speed = EaseHandleDragMath.speed(vertical: true, pointer: pointer, kept: 0, reach: max(reach, SpeedHill.minReach),
                                             valueRange: -2...3)
        model.setHandle(reach: reach, speed: speed, side: h.side, for: property)
        needsDisplay = true
    }

    func endDrag() {
        guard drag != nil else { return }
        model.endGesture()
        drag = nil
        needsDisplay = true
    }

    // MARK: Right-click: curve presets for the selected keys

    override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
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
        let items = curveMenuItems()
        let screen = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        SQMenuController.shared.present(items: items, at: screen)
    }

    /// Steady, Smooth, Smooth In, Smooth Out, Hold, Hold Ahead (applied to the selected keys), then the row's key items.
    func curveMenuItems() -> [SQMenuItem] {
        let on = model.speedChip(for: property)
        let ahead = !property.isAnimationRow && model.selectionTakesHoldAhead
        var items = SpeedCurveChip.allCases.filter { $0 != .holdAhead || ahead }.map { chip in
            SQMenuItem(title: chip.title, isChecked: chip == on) { [weak self] in
                guard let self else { return }
                self.model.applySpeedChip(chip, for: self.property)
                self.needsDisplay = true
            }
        }
        if let extra = extraMenu?(), !extra.isEmpty { items.append(.separator); items += extra }
        return items
    }

    // MARK: Zoom (as the lanes)

    override func magnify(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        model.zoom(by: KeyframeZoomInput.magnifyFactor(event.magnification), around: model.laneGeometry(width: bounds.width).seconds(atX: x))
    }

    override func scrollWheel(with event: NSEvent) {
        let geo = model.laneGeometry(width: bounds.width)
        switch KeyframeZoomInput.scroll(event) {
        case .zoom(let f): model.zoom(by: f, around: geo.seconds(atX: convert(event.locationInWindow, from: nil).x))
        case .pan(let pts): model.panViewport(bySeconds: -Double(pts) / max(geo.pointsPerSecond, 1e-6))
        case .none: super.scrollWheel(with: event)
        }
    }
}

/// The left pane of an opened keyframe row: empty on purpose (feedback 2026-10-05: no preset buttons, no labels). The curve
/// presets live in the graph's right-click menu; the pane only keeps the graph aligned with the lanes above.
final class EasePaneView: NSView {
    let property: EffectProperty
    let model: EffectControlsModel

    init(property: EffectProperty, model: EffectControlsModel) {
        self.property = property; self.model = model
        super.init(frame: .zero)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        ControlsColors.paneFill.setFill(); bounds.fill()
        // No line on top: the pane continues the property row above it (one element).
        Theme.Colors.separator.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    func update() {}
}
