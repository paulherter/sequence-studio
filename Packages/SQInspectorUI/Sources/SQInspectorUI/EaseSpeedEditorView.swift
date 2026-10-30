import AppKit
import SQCore

/// The speed curve of one eased stretch on its own: the only editor of the curve popover (keyframe ruler button,
/// transition Easing > Custom, speed band, motion Custom curve, keystones). It is the graph of an opened keyframe
/// row (`InlineSpeedGraphView`) for a single segment that fills the view: same geometry (`SpeedGraphGeometry`), same
/// drawing (`SpeedGraphPainter`), same handles (100 % reach at the middle). Both keys count as selected, so both
/// handles always show. A handle drags both ways: sideways sets its Reach, up and down the speed at its key
/// (`EaseShape.settingSpeed`). Below the 0 line the value runs backwards there: a wind-up at the left key, an overshoot
/// that settles at the right key; the readout in the corner says how far.
final class EaseSpeedEditorView: NSView {
    var reading: EaseReading = .empty { didSet { if reading != oldValue { needsDisplay = true } } }
    var emptyHint = "Nothing to ease" { didSet { needsDisplay = true } }
    var onBegin: (() -> Void)?
    var onChange: ((EaseShape) -> Void)?
    var onEnd: (() -> Void)?

    static let inset: CGFloat = 18
    private let from = UUID(), to = UUID()
    /// What a handle's value part may be (`EaseCurveSource.handleValueRange`): the vertical drag stops there.
    var valueRange: ClosedRange<Double> = -2...3
    /// A vertical drag starts changing the speed after this many points, so a sideways drag keeps the speed.
    static let verticalSlop: CGFloat = EaseHandleDragMath.deadZone
    private struct Drag {
        var side: EaseSide, base: EaseTrackSegment, grab: CGSize, origin: CGPoint
        /// The plot as it was at the press: the scale does not move under the pointer during the drag.
        var geometry: SpeedGraphGeometry
        var vertical = false
    }
    private var drag: Drag?
    private var dragShape: EaseShape?
    private(set) var hovered: EaseSide? { didSet { if oldValue != hovered { needsDisplay = true } } }
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Speed curve")
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The curve the handles sit on: the drag in progress, the common curve, or straight handles when the selected
    /// segments differ (their curves are drawn as ghosts; a drag then writes one curve to all of them).
    var shownShape: EaseShape? {
        if let dragShape { return dragShape }
        switch reading {
        case .empty: return nil
        case .common(let s): return s
        case .mixed: return .linear
        }
    }
    private var isMixed: Bool { if case .mixed = reading, dragShape == nil { return true } else { return false } }

    private func segment(_ shape: EaseShape) -> EaseTrackSegment {
        EaseTrackSegment(from: from, to: to, start: .zero, end: Time(1, 1), shape: shape)
    }
    var segment: EaseTrackSegment? { shownShape.map(segment) }

    private var ghosts: [EaseTrackSegment] {
        if case .mixed(let shapes) = reading, dragShape == nil { return shapes.map(segment) }
        return []
    }

    var geometry: SpeedGraphGeometry {
        if let g = drag?.geometry { return g }
        let all = (segment.map { [$0] } ?? []) + ghosts
        var g = SpeedGraphGeometry(lane: KeyframeLaneGeometry(width: bounds.width, duration: Time(1, 1), inset: Self.inset),
                                   height: bounds.height, peak: SpeedGraphGeometry.peak(of: all))
        g.low = SpeedGraphGeometry.low(of: all)
        return g
    }

    /// "Overshoot 12%" / "Wind-Up 8%" when the value leaves the span between its keys, else nil.
    var readout: String? {
        guard !isMixed, let e = shownShape?.valueExcursion else { return nil }
        func pct(_ v: Double) -> String? { v >= 0.005 ? "\(Int((v * 100).rounded()))%" : nil }
        let parts = [pct(e.below).map { "Wind-Up " + $0 }, pct(e.above).map { "Overshoot " + $0 }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }

    /// The handle at `p`.
    func handle(at p: CGPoint) -> EaseSide? {
        guard let s = segment, case .handle(_, _, let side) = geometry.hitTest(p, rows: [[s]], selected: [[from, to]]) else { return nil }
        return side
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let geo = geometry
        SpeedGraphPainter.drawBackground(ctx, geo, bounds: bounds)
        for g in ghosts {
            SpeedGraphPainter.drawRow(ctx, geo, bounds: bounds, segments: [g], selected: [], color: Theme.Colors.label3) { _, _ in false }
        }
        guard let s = segment else {
            guard ghosts.isEmpty else { return }
            let attrs: [NSAttributedString.Key: Any] = [.font: Theme.Typography.body, .foregroundColor: Theme.Colors.label3]
            let text = emptyHint as NSString, sz = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: bounds.midX - sz.width / 2, y: bounds.midY - sz.height / 2), withAttributes: attrs)
            return
        }
        // Mixed: only the ghosts are curves that exist; the straight one just carries the handles.
        SpeedGraphPainter.drawRow(ctx, geo, bounds: bounds, segments: [s], selected: [from, to],
                                  color: isMixed ? .clear : ControlsMetrics.curveColor(0)) { [hovered, drag] _, side in side == hovered || side == drag?.side }
        if let r = readout {
            let attrs: [NSAttributedString.Key: Any] = [.font: Theme.Typography.caption, .foregroundColor: Theme.Colors.label2]
            let text = r as NSString, sz = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: bounds.maxX - sz.width - 8, y: 5), withAttributes: attrs)
        }
        setAccessibilityValue(readout)
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }

    override func mouseMoved(with event: NSEvent) {
        guard drag == nil else { return }
        hovered = handle(at: convert(event.locationInWindow, from: nil))
        KeyframeCursor.cursor(overGrip: hovered != nil, dragging: false).set()
    }
    override func mouseExited(with event: NSEvent) { if drag == nil { hovered = nil; NSCursor.arrow.set() } }

    override func mouseDown(with event: NSEvent) { press(at: convert(event.locationInWindow, from: nil)) }
    override func mouseDragged(with event: NSEvent) {
        dragGesture(to: convert(event.locationInWindow, from: nil), shift: event.modifierFlags.contains(.shift))
    }
    override func mouseUp(with event: NSEvent) { release() }

    /// Grabs the handle at `p` (tests drive the gesture through `press`, `dragGesture`, `release`).
    @discardableResult
    func press(at p: CGPoint) -> Bool {
        guard let s = segment, let side = handle(at: p) else { return false }
        // The handle never jumps under the pointer: keep the distance to its true end.
        let geo = geometry, end = geo.handleTrueEnd(s, side: side)
        // The true height of the key's speed (the drawn knob is kept inside the view).
        let speed = side == .in ? s.shape.speedIn : s.shape.speedOut
        let trueY = geo.baseline - CGFloat(speed) * geo.unitHeight
        drag = Drag(side: side, base: s, grab: CGSize(width: end.x - p.x, height: trueY - p.y), origin: p, geometry: geo)
        onBegin?()
        KeyframeCursor.cursor(overGrip: true, dragging: true).set()
        needsDisplay = true
        return true
    }

    /// Sideways the handle gets longer or shorter (the speed at its key stays); up and down, past `verticalSlop`, sets
    /// that speed (the reach stays). Below the 0 line the speed is negative: wind-up or overshoot.
    func dragGesture(to p: CGPoint, shift: Bool = false) {
        guard var d = drag else { return }
        let v = EaseHandleDragMath.isVertical(wasVertical: d.vertical, pressY: d.origin.y, y: p.y, shift: shift)
        if v != d.vertical { d.vertical = v; drag = d }
        let reach = d.geometry.reach(atX: p.x + d.grab.width, d.base, side: d.side)
        var s = d.base.shape.settingReach(reach, side: d.side)
        // A longer handle at the same speed has a bigger value part: kept inside what the source stores during the
        // drag already, so the curve does not jump when it is written.
        let speed = d.vertical ? d.geometry.speed(atY: p.y + d.grab.height) : (d.side == .in ? s.speedIn : s.speedOut)
        s = s.settingSpeed(speed, side: d.side, valueRange: valueRange)
        dragShape = s
        onChange?(s)
        needsDisplay = true
    }

    func release() {
        guard drag != nil else { return }
        drag = nil; dragShape = nil
        onEnd?()
        needsDisplay = true
    }
}
