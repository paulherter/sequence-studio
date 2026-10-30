import AppKit
import SQCore

/// Value / speed graph for one scalar property (Effect Controls). Custom drawn (DESIGN.md screen 2):
/// curve, keyframe glyphs (diamond linear, circle eased, square hold), bezier handles on selected keys.
/// The view never mutates the model: it previews a gesture locally and calls `onEdit` once on mouse-up.
public final class KeyframeGraphView: NSView {
    public var track = KeyframeTrack<Double>() { didSet { if !isGesturing { refit() }; needsDisplay = true } }
    public var mode: GraphMode = .value { didSet { refit(); needsDisplay = true } }
    public var selectedKeyIDs = Set<UUID>() { didSet { needsDisplay = true } }
    /// Playhead in clip-local seconds (optional thin line).
    public var playheadSeconds: Double? { didSet { needsDisplay = true } }
    public var frameDuration = Time(1, 30)
    public var minTime = Time.zero
    public var maxTime: Time? { didSet { if !isGesturing, maxTime != oldValue { refit(); needsDisplay = true } } }
    public var easingLibrary = EasingLibrary()
    /// Visible time window (clip-local seconds) shared with the lanes and ruler; nil = whole clip range.
    public var visibleTime: ClosedRange<Double>? { didSet { if !isGesturing, visibleTime != oldValue { refit(); needsDisplay = true } } }
    /// Factor from native values to the numbers shown (scale and opacity show percent).
    public var displayScale: Double = 1 { didSet { needsDisplay = true } }
    /// Pinch / Option-scroll zoom (factor, anchor seconds) and horizontal scroll pan (seconds), in the shared keyframe viewport.
    public var onZoom: ((Double, Double) -> Void)?
    public var onPan: ((Double) -> Void)?
    /// Switches between the speed and the value graph (context menu).
    public var onModeChange: ((GraphMode) -> Void)?
    /// Plot margins. Effect Controls sets `left` so the plot starts exactly where the keyframe lanes start.
    public var insets = GraphInsets() { didSet { needsDisplay = true } }
    /// Width of the row's left (label) area, painted as panel instead of graph background.
    public var leadingPanelWidth: CGFloat = 0 { didSet { needsDisplay = true } }

    /// One call per gesture (one undo step) with the complete new track.
    public var onEdit: ((KeyframeTrack<Double>) -> Void)?
    public var onSelectionChange: ((Set<UUID>) -> Void)?
    public var onLibraryChange: ((EasingLibrary) -> Void)?
    /// Asks for a preset name. Default: modal alert with a text field. Return nil to cancel.
    public var namePrompt: @MainActor (String) -> String? = KeyframeGraphView.runNameAlert

    private var fit = GraphFit(time: 0...1, value: 0...1)
    private var gesture: GraphGestureState?
    private var preview: KeyframeTrack<Double>?
    private var marquee: CGRect?
    private var easeSide = EaseSide.both
    private var isGesturing: Bool { gesture != nil }
    /// Key or handle under the pointer (hover highlight + open-hand cursor).
    private(set) var hoverHit: GraphHit = .empty
    private var tracking: NSTrackingArea?

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override init(frame: NSRect) { super.init(frame: frame); commonInit() }
    public required init?(coder: NSCoder) { super.init(coder: coder); commonInit() }
    private func commonInit() {
        setAccessibilityRole(.group)
        setAccessibilityLabel("Keyframe graph")
    }

    private var shownTrack: KeyframeTrack<Double> { preview ?? track }
    private func refit() {
        let range = maxTime.map { GraphMath.seconds(minTime)...max(GraphMath.seconds($0), GraphMath.seconds(minTime)) }
        fit = GraphFit.make(track: track, mode: mode, timeRange: range, visibleTime: visibleTime)
    }
    /// Playhead line from the top to the bottom of the view (same pixel column as the keyframe lanes draw it); nil when
    /// there is no playhead or it sits in the label column or outside the view.
    var playheadLineRect: NSRect? {
        guard let ph = playheadSeconds else { return nil }
        let x = geometry.x(seconds: ph).rounded()
        guard x >= leadingPanelWidth, x < bounds.maxX else { return nil }
        return Theme.PlayheadSkin.lineFrame(centerX: x, height: bounds.height)
    }

    private var geometry: KeyframeGraphGeometry { KeyframeGraphGeometry(size: bounds.size, insets: insets, fit: fit, mode: mode) }
    private var limits: GraphEditLimits { GraphEditLimits(frameDuration: frameDuration, minTime: minTime, maxTime: maxTime) }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        let g = geometry
        Theme.Colors.lane.setFill()
        bounds.fill()
        if leadingPanelWidth > 0 {
            Theme.Colors.panel.setFill()
            NSRect(x: 0, y: 0, width: min(leadingPanelWidth, bounds.width), height: bounds.height).fill()
        }

        let plot = g.plot
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: plot.insetBy(dx: -1, dy: -4)).addClip()

        // Grid
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.Typography.caption, .foregroundColor: Theme.Colors.label3]
        let valueAttrs: [NSAttributedString.Key: Any] = [.font: Theme.Typography.caption, .foregroundColor: Theme.Colors.accent]
        for v in g.gridValues(targetCount: 3) {
            let y = g.y(value: v).rounded() + 0.5
            (v == 0 ? Theme.Colors.label3 : Theme.Colors.separator).setStroke()
            let line = NSBezierPath()
            line.move(to: NSPoint(x: plot.minX, y: y)); line.line(to: NSPoint(x: plot.maxX, y: y))
            line.lineWidth = 1
            line.stroke()
        }

        // Playhead over the grid, under the curve: the full height of the row, outside the plot clip, like the lanes above
        // and below it (FB-Q: no gap over or under the plot).
        if let r = playheadLineRect {
            NSGraphicsContext.restoreGraphicsState()
            Theme.Colors.playhead.setFill()
            r.fill()
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: plot.insetBy(dx: -1, dy: -4)).addClip()
        }

        // Curve
        let t = shownTrack
        (mode == .value ? Theme.Colors.curveX : Theme.Colors.curveY).setStroke()
        for seg in g.curvePolylines(track: t) {
            let path = NSBezierPath()
            path.lineWidth = 1.5; path.lineJoinStyle = .round
            for (i, p) in seg.points.enumerated() { i == 0 ? path.move(to: p) : path.line(to: p) }
            path.stroke()
        }

        // Handles of selected keys
        for k in t.keys where selectedKeyIDs.contains(k.id) {
            guard let i = t.keys.firstIndex(where: { $0.id == k.id }) else { continue }
            let kp = g.keyPoint(track: t, index: i)
            for side in [GraphHandleSide.inSide, .outSide] {
                guard let hp = g.handlePoint(track: t, keyID: k.id, side: side) else { continue }
                Theme.Colors.accent.setStroke()
                let l = NSBezierPath()
                l.move(to: kp); l.line(to: hp); l.lineWidth = KeyframeGraphGeometry.handleLineWidth; l.stroke()
                let d = KeyframeGraphGeometry.handleKnobDiameter
                let dot = NSBezierPath(ovalIn: NSRect(x: hp.x - d / 2, y: hp.y - d / 2, width: d, height: d))
                Theme.Colors.accent.setFill(); dot.fill()
            }
        }
        // Hover: the key or handle under the pointer gets the shared hover fill behind it.
        if let c = hoverPoint(g, t) {
            Theme.Selection.hover.setFill()
            NSBezierPath(roundedRect: NSRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12),
                         xRadius: Theme.Radius.small, yRadius: Theme.Radius.small).fill()
        }
        // Keys
        for (i, k) in KeyGlyph.glyphs(of: t).enumerated() {
            drawKeyMarker(at: g.keyPoint(track: t, index: i), selected: selectedKeyIDs.contains(k.id))
        }
        NSGraphicsContext.restoreGraphicsState()

        // Axis labels: only the top and bottom of the visible range and the graph kind, in the label column.
        let labelRight = (leadingPanelWidth > 0 ? leadingPanelWidth : plot.minX) - 10
        let hi = NSAttributedString(string: GraphAxisLabels.format(fit.value.upperBound, scale: displayScale), attributes: valueAttrs)
        let lo = NSAttributedString(string: GraphAxisLabels.format(fit.value.lowerBound, scale: displayScale), attributes: valueAttrs)
        hi.draw(at: NSPoint(x: labelRight - hi.size().width, y: plot.minY - 2))
        lo.draw(at: NSPoint(x: labelRight - lo.size().width, y: plot.maxY - lo.size().height + 2))
        let kind = NSAttributedString(string: mode == .speed ? "Speed" : "Value", attributes: attrs)
        kind.draw(at: NSPoint(x: labelRight - kind.size().width, y: bounds.midY - kind.size().height / 2))

        if let m = marquee {
            Theme.Colors.accentTint.setFill(); m.fill()
            Theme.Colors.accent.setStroke()
            let p = NSBezierPath(rect: m.insetBy(dx: 0.5, dy: 0.5)); p.lineWidth = 1; p.stroke()
        }
    }

    /// Keys are shown once, as the glyphs in the property row above; in the graph each key is only a small marker on
    /// the curve (Premiere), so the row glyph and the graph never look like two keys.
    private func drawKeyMarker(at c: CGPoint, selected: Bool) {
        let r = NSRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)
        (selected ? Theme.Colors.accent : Theme.Colors.keyframe).setFill()
        r.fill()
    }

    private func hoverPoint(_ g: KeyframeGraphGeometry, _ t: KeyframeTrack<Double>) -> CGPoint? {
        guard gesture == nil else { return nil }
        switch hoverHit {
        case .key(let id): return t.keys.firstIndex { $0.id == id }.map { g.keyPoint(track: t, index: $0) }
        case .handle(let id, let side): return g.handlePoint(track: t, keyID: id, side: side)
        case .segment, .empty: return nil
        }
    }

    /// Keys and handles are draggable (open hand); the curve between them and empty space are not.
    static func isGrip(_ h: GraphHit) -> Bool {
        switch h { case .key, .handle: true; case .segment, .empty: false }
    }

    // MARK: Hover

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }

    public override func mouseMoved(with event: NSEvent) {
        guard gesture == nil else { return }
        let h = geometry.hitTest(convert(event.locationInWindow, from: nil), track: track, selected: selectedKeyIDs)
        let grip = Self.isGrip(h) ? h : .empty
        if grip != hoverHit { hoverHit = grip; needsDisplay = true }
        KeyframeCursor.cursor(overGrip: grip != .empty, dragging: false).set()
    }

    public override func mouseExited(with event: NSEvent) {
        guard gesture == nil else { return }
        if hoverHit != .empty { hoverHit = .empty; needsDisplay = true }
        NSCursor.arrow.set()
    }

    // MARK: Mouse

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        refit()
        if Self.isGrip(geometry.hitTest(p, track: track, selected: selectedKeyIDs)) {
            KeyframeCursor.cursor(overGrip: true, dragging: true).set()
        }
        gesture = GraphGestureState(at: p, shift: event.modifierFlags.contains(.shift), geometry: geometry,
                                    track: track, selection: selectedKeyIDs, limits: limits)
        apply(gesture!.current)
    }

    public override func mouseDragged(with event: NSEvent) {
        guard gesture != nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        if let r = gesture?.drag(to: p, free: event.modifierFlags.contains(.shift)) { apply(r) }
    }

    public override func mouseUp(with event: NSEvent) {
        guard var g = gesture else { return }
        let r = g.end(at: convert(event.locationInWindow, from: nil))
        gesture = nil; preview = nil; marquee = nil
        setSelection(r.selection)
        if r.commit { track = r.track; onEdit?(r.track) } else { refit() }
        mouseMoved(with: event)
        needsDisplay = true
    }


    private func apply(_ r: GraphGestureState.Result) {
        preview = r.track == track ? nil : r.track
        marquee = r.marquee
        setSelection(r.selection)
        needsDisplay = true
    }

    private func setSelection(_ s: Set<UUID>) {
        guard s != selectedKeyIDs else { return }
        selectedKeyIDs = s
        onSelectionChange?(s)
    }

    // MARK: Zoom

    public override func magnify(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        onZoom?(KeyframeZoomInput.magnifyFactor(event.magnification), geometry.seconds(atX: x))
    }

    public override func scrollWheel(with event: NSEvent) {
        switch KeyframeZoomInput.scroll(event) {
        case .zoom(let f): onZoom?(f, geometry.seconds(atX: convert(event.locationInWindow, from: nil).x))
        case .pan(let pts): onPan?(-Double(pts) / max(geometry.pointsPerSecond, 1e-6))
        case .none: super.scrollWheel(with: event)
        }
    }

    // MARK: Easing menu

    public override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        refit()
        if case .key(let id) = geometry.hitTest(p, track: track, selected: selectedKeyIDs), !selectedKeyIDs.contains(id) {
            setSelection([id])
        }
        SQContextMenu.show(items: makeEasingItems(), for: event, in: self)
    }

    /// Rows: graph mode, side choice (applies to in / out / both), built-in curves, user presets, Save Curve.
    public func makeEasingItems() -> [SQMenuItem] {
        let spec = EasingMenuSpec(library: easingLibrary, side: easeSide, hasSelection: !selectedKeyIDs.isEmpty)
        var items: [SQMenuItem] = []
        for (m, title) in [(GraphMode.speed, "Speed"), (.value, "Value")] {
            items.append(SQMenuItem(title: title, isChecked: mode == m) { [weak self] in self?.onModeChange?(m) })
        }
        items.append(.separator)
        for entry in spec.entries {
            switch entry {
            case .header(let title):
                items.append(.header(title))
            case .side(let s, let title, let checked):
                items.append(SQMenuItem(title: title, isChecked: checked) { [weak self] in self?.easeSide = s })
            case .curve(let c, let enabled):
                items.append(SQMenuItem(title: EasingMenuSpec.title(of: c),
                                        isEnabled: enabled) { [weak self] in self?.applyEasingCurve(c) })
            case .separator:
                items.append(.separator)
            case .saveCurve(let enabled):
                items.append(SQMenuItem(title: "Save as preset\u{2026}", isEnabled: enabled) { [weak self] in self?.saveSelectedCurve() })
            }
        }
        return items
    }

    private func applyEasingCurve(_ c: EasingCurve) {
        guard !selectedKeyIDs.isEmpty else { return }
        var t = track
        t.apply(c, to: selectedKeyIDs, side: easeSide)
        guard t != track else { return }
        track = t
        onEdit?(t)
    }

    private func saveSelectedCurve() {
        guard let key = track.keys.first(where: { selectedKeyIDs.contains($0.id) }),
              let name = namePrompt("Curve"), !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        easingLibrary.saveCurve(from: key, name: name.trimmingCharacters(in: .whitespaces))
        onLibraryChange?(easingLibrary)
    }

    @MainActor private static func runNameAlert(_ suggestion: String) -> String? {
        let alert = SQDialog()
        alert.messageText = "Save Curve"
        alert.informativeText = "Name for the new easing preset."
        let field = SQDialog.makeField(width: 240)
        field.stringValue = suggestion
        alert.accessoryView = field
        alert.addButton("Save")
        alert.addButton("Cancel")
        alert.initialFirstResponder = field
        return alert.runModal() == .first ? field.stringValue : nil
    }
}
