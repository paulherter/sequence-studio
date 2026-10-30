import AppKit
import SQAudioFX
import SQCore

/// Combined frequency response of the Parametric EQ with one draggable point per band. Horizontal = frequency, vertical =
/// gain; scroll or Option-drag = Q; double-click resets the band. The view only reports edits (`onChange`), the model writes
/// the effect parameters. The response path is cached and rebuilt only when the values or the width change.
public final class EQCurveView: NSView {
    public var values: AudioParametricEQValues? { didSet { if values != oldValue { rebuild() } } }
    public var onBegin: (() -> Void)?
    /// Filter index (0 HP ... 8 LP) and the new frequency, gain (nil for HP / LP) or Q (nil unless Q is dragged).
    public var onChange: ((Int, Double?, Double?, Double?) -> Void)?
    public var onEnd: (() -> Void)?
    public var onReset: ((Int) -> Void)?

    /// Builds of the cached path (for tests).
    public private(set) var buildCount = 0
    private var curve: NSBezierPath?
    private var fillPath: NSBezierPath?
    private var cachedSize = NSSize.zero
    private var scratch: [Double] = []
    private var dragFilter: Int?
    private var dragStart: (point: NSPoint, q: Double)?
    private var qDrag = false

    private static let handleRadius: CGFloat = Theme.Spacing.xs + Theme.Spacing.xxs
    private static let hitRadius: CGFloat = Theme.Spacing.md
    private static let labelBand: CGFloat = Theme.Spacing.lg

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { false }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        sqToolTip = "Drag a point: frequency and gain. Scroll or Option-drag: Q. Double-click: reset the band."
        setAccessibilityRole(.group)
        setAccessibilityLabel("EQ curve")
    }
    required init?(coder: NSCoder) { fatalError() }

    var geometry: EQCurveGeometry {
        EQCurveGeometry(plot: NSRect(x: 0, y: 0, width: bounds.width, height: max(bounds.height - Self.labelBand, 1)))
    }

    public override func layout() {
        super.layout()
        if bounds.size != cachedSize { rebuild() }
    }

    private func rebuild() {
        needsDisplay = true
        cachedSize = bounds.size
        buildCount += 1
        guard let v = values, bounds.width > 1 else { curve = nil; fillPath = nil; updateAccessibility(); return }
        let g = geometry
        let freqs = g.sampleFrequencies()
        ParametricEQResponse.totalDB(v, at: freqs, into: &scratch)
        let line = NSBezierPath(), area = NSBezierPath()
        let zero = g.y(db: 0)
        area.move(to: NSPoint(x: g.x(hz: freqs[0]), y: zero))
        for (i, hz) in freqs.enumerated() {
            let p = NSPoint(x: g.x(hz: hz), y: g.y(db: scratch[i]))
            if i == 0 { line.move(to: p) } else { line.line(to: p) }
            area.line(to: p)
        }
        area.line(to: NSPoint(x: g.x(hz: freqs[freqs.count - 1]), y: zero)); area.close()
        line.lineWidth = Theme.State.focusLineWidth; line.lineJoinStyle = .round
        curve = line; fillPath = area
        updateAccessibility()
    }

    // MARK: Points

    /// Plot position of band `i`'s point. HP / LP sit on the combined curve; the others at their gain.
    func pointPosition(_ i: Int) -> NSPoint? {
        guard let v = values else { return nil }
        let g = geometry, b = v[i]
        let db = (i == 0 || i == 8) ? ParametricEQResponse.totalDB(v, hz: b.hz) : b.gainDB
        return NSPoint(x: g.x(hz: b.hz), y: g.y(db: db))
    }

    static func hasGain(_ i: Int) -> Bool { EQCurveGeometry.hasGain(i) }

    private func filter(at p: NSPoint) -> Int? {
        guard let v = values else { return nil }
        var best: (Int, CGFloat)?
        for i in 0..<AudioParametricEQValues.bandCount where v[i].on {
            guard let c = pointPosition(i) else { continue }
            let d = hypot(c.x - p.x, c.y - p.y)
            if d <= Self.hitRadius, d < (best?.1 ?? .infinity) { best = (i, d) }
        }
        return best?.0
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        let g = geometry
        let frame = NSBezierPath(roundedRect: g.plot, xRadius: Theme.Radius.control, yRadius: Theme.Radius.control)
        Theme.Colors.field.setFill(); frame.fill()
        NSGraphicsContext.saveGraphicsState()
        frame.addClip()
        for hz in EQCurveGeometry.gridHz {
            let decade = EQCurveGeometry.decadeHz.contains(hz)
            (decade ? Theme.Colors.separator : Theme.Colors.separator.withAlphaComponent(Theme.State.disabledAlpha)).setFill()
            NSRect(x: g.x(hz: hz), y: 0, width: 1, height: g.plot.height).fill()
        }
        for db in EQCurveGeometry.gridDB {
            (db == 0 ? Theme.Colors.label3.withAlphaComponent(Theme.State.disabledAlpha) : Theme.Colors.separator).setFill()
            NSRect(x: 0, y: g.y(db: db), width: g.plot.width, height: 1).fill()
        }
        Theme.Colors.accentTint.setFill(); fillPath?.fill()
        Theme.Colors.accent.setStroke(); curve?.stroke()
        NSGraphicsContext.restoreGraphicsState()
        drawLabels(g)
        guard let v = values else { return }
        for i in 0..<AudioParametricEQValues.bandCount {
            guard let c = pointPosition(i) else { continue }
            let r = Self.handleRadius
            let dot = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            if v[i].on {
                (dragFilter == i ? Theme.Colors.accent : Theme.Colors.label).setFill(); dot.fill()
                Theme.Colors.divider.setStroke(); dot.lineWidth = Theme.Separator.width; dot.stroke()
            } else {
                Theme.Colors.label3.withAlphaComponent(Theme.State.disabledAlpha).setStroke(); dot.lineWidth = Theme.Separator.width; dot.stroke()
            }
        }
    }

    private func drawLabels(_ g: EQCurveGeometry) {
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.Typography.caption, .foregroundColor: Theme.Colors.label3]
        for (hz, text) in [(100.0, "100"), (1_000, "1k"), (10_000, "10k")] {
            let s = NSAttributedString(string: text, attributes: attrs)
            s.draw(at: NSPoint(x: g.x(hz: hz) - s.size().width / 2, y: g.plot.maxY + 1))
        }
        for db in [-12.0, -6, 6, 12] {
            let s = NSAttributedString(string: String(format: "%+.0f", db), attributes: attrs)
            s.draw(at: NSPoint(x: Theme.Spacing.xs, y: g.y(db: db) - s.size().height - 1))
        }
    }

    // MARK: Mouse

    public override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = filter(at: p), let v = values else { return }
        if event.clickCount == 2 { onBegin?(); onReset?(i); onEnd?(); return }
        dragFilter = i
        qDrag = event.modifierFlags.contains(.option) && Self.hasGain(i)
        dragStart = (p, v[i].q)
        onBegin?()
        needsDisplay = true
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let i = dragFilter, let v = values, let start = dragStart else { return }
        let p = convert(event.locationInWindow, from: nil), g = geometry
        if qDrag {
            // Up = narrower (higher Q): 2x per 40 points.
            onChange?(i, nil, nil, Self.qFactor(start: start.q, dy: start.point.y - p.y))
        } else {
            onChange?(i, g.hz(x: p.x), Self.hasGain(i) ? g.db(y: p.y) : nil, nil)
        }
    }

    public override func mouseUp(with event: NSEvent) {
        guard dragFilter != nil else { return }
        dragFilter = nil; dragStart = nil; qDrag = false
        needsDisplay = true
        onEnd?()
    }

    static func qFactor(start: Double, dy: CGFloat) -> Double { EQCurveGeometry.qFactor(start: start, dy: dy) }

    private var scroll: (filter: Int, startQ: Double, dy: CGFloat)?
    private var scrollTimer: Timer?
    /// A mouse wheel has no phases: the gesture ends this long after the last event.
    static let scrollIdle: TimeInterval = 0.3

    public override func scrollWheel(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if scroll == nil, filter(at: p) == nil || !Self.hasGain(filter(at: p) ?? 0) { super.scrollWheel(with: event); return }
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 4
        applyScroll(at: p, dy: dy)
        // Trackpad: the gesture (momentum included) is over when the system says so; otherwise the idle timer ends it.
        if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled)
            || (event.phase.contains(.cancelled)) { endScrollGesture() }
    }

    /// One scroll gesture = one begin / end pair; Q accumulates from the Q at its start.
    func applyScroll(at p: NSPoint, dy: CGFloat) {
        if scroll == nil {
            guard let i = filter(at: p), Self.hasGain(i), let v = values else { return }
            scroll = (i, v[i].q, 0)
            onBegin?()
        }
        guard var st = scroll else { return }
        st.dy += dy; scroll = st
        onChange?(st.filter, nil, nil, Self.qFactor(start: st.startQ, dy: st.dy))
        scrollTimer?.invalidate()
        scrollTimer = Timer.scheduledTimer(withTimeInterval: Self.scrollIdle, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.endScrollGesture() }
        }
    }

    func endScrollGesture() {
        scrollTimer?.invalidate(); scrollTimer = nil
        guard scroll != nil else { return }
        scroll = nil
        onEnd?()
    }

    // MARK: Accessibility

    private var pointElements: [NSAccessibilityElement] = []
    static let filterNames = EQCurveGeometry.filterNames

    static func accessibilityText(_ i: Int, _ b: AudioPEQBand) -> String {
        var s = "\(filterNames[i]), \(Int(b.hz.rounded())) hertz"
        if hasGain(i) { s += String(format: ", %.1f decibels, Q %.2f", b.gainDB, b.q) }
        return b.on ? s : s + ", off"
    }

    private func updateAccessibility() {
        guard let v = values else { pointElements = []; setAccessibilityChildren(nil); return }
        if pointElements.count != AudioParametricEQValues.bandCount {
            pointElements = (0..<AudioParametricEQValues.bandCount).map { _ in
                let e = NSAccessibilityElement(); e.setAccessibilityRole(.slider); e.setAccessibilityParent(self); return e
            }
        }
        let r = Self.hitRadius
        for (i, e) in pointElements.enumerated() {
            e.setAccessibilityLabel(Self.accessibilityText(i, v[i]))
            if let c = pointPosition(i) {
                e.setAccessibilityFrameInParentSpace(NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            }
        }
        setAccessibilityChildren(pointElements)
    }
}
