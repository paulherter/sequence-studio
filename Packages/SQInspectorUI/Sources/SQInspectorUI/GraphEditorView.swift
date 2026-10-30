import AppKit
import SQCore

/// Graph Editor of Effect Controls (After Effects style, speed graph only): fills the whole keyframe area (right of the
/// property list, under the ruler) while on. The curves of the selected property rows lie in ONE plot on one shared
/// speed axis (display units per second, 0 at the bottom, labels on the left, grid behind), one color per property;
/// keys are small squares on the curves. Click / Shift-click / marquee select keys across properties; dragging a key
/// moves the whole selection in time (snapping when on); dragging a handle of a selected key gives every selected key
/// the same handle on that side. Hovering a curve shows its speed. A toolbar at the bottom holds the filter, snap, fit
/// and ease buttons. Right-click opens the normal key menu. All edits go through `EffectControlsModel`.
public final class GraphEditorView: NSView {
    public let model: EffectControlsModel
    /// Supplies the key menu (the lanes' menu, so both views offer the same entries).
    var keyMenu: ((Bool) -> [SQMenuItem])?
    let toolbar: GraphEditorToolbar

    private var gesture: GraphEditorGesture?
    private var marquee: CGRect?
    private var escapeCancelled = false
    /// A key or handle drag commits to the model at most once per display frame (every drag event is absolute from the
    /// gesture base, so skipped positions lose nothing; `LiveDragCoalescer`).
    private var pendingDrag: (() -> Void)?
    private lazy var dragCoalescer = LiveDragCoalescer { [weak self] _ in
        guard let run = self?.pendingDrag else { return }
        self?.pendingDrag = nil
        run()
    }
    private var hoverPoint: CGPoint?
    private var tracking: NSTrackingArea?

    /// One color per property (After Effects-like: Position pink, Scale red, Rotation cyan, Opacity teal ...).
    static let palette: [NSColor] = Theme.Palette.graphCurve
    static let handleColor = Theme.Colors.yellow

    public init(model: EffectControlsModel) {
        self.model = model
        toolbar = GraphEditorToolbar(model: model)
        super.init(frame: .zero)
        addSubview(toolbar)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Graph Editor")
    }
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func layout() {
        super.layout()
        let h = GraphEditorGeometry.toolbarHeight
        toolbar.frame = NSRect(x: 0, y: bounds.height - h, width: bounds.width, height: h)
        placePlayhead()
    }

    // MARK: Curve cache

    /// Curves are sampled only when the clip (revision) or the drawn properties change, or the zoom needs another sample
    /// count; not on playhead moves, hover or pan.
    private struct CacheKey: Equatable { var revision: Int; var properties: [EffectProperty] }
    private var cache: (key: CacheKey, samples: Int, curves: [GraphEditorCurve])?
    /// Everything the drawing depends on except the playhead (which is its own layer).
    private struct DrawKey: Equatable {
        var cache: CacheKey; var selection: Set<SummaryMember>; var viewport: KeyframeViewport; var size: CGSize; var showAll: Bool
    }
    private var drawn: DrawKey?
    private(set) var sampleCount = 0      // tests: how often curves were sampled
    private(set) var artworkBuilds = 0    // tests: how often the paths were rebuilt

    private var cacheKey: CacheKey { CacheKey(revision: model.clipRevision, properties: model.graphEditorProperties) }

    var curves: [GraphEditorCurve] {
        let key = cacheKey
        let pps = model.laneGeometry(width: bounds.width).pointsPerSecond
        if let c = cache, c.key == key {
            // Same data: only a changed sample count (zoom) samples again.
            let n = model.graphSampleCount(pointsPerSecond: pps)
            if n == c.samples { return c.curves }
        }
        let n = model.graphSampleCount(pointsPerSecond: pps)
        let v = model.graphEditorCurves(samples: n)
        sampleCount += 1
        cache = (key, n, v)
        return v
    }

    /// Live geometry; while a drag runs the axis only grows (the plot does not jump under the pointer).
    var geometry: GraphEditorGeometry {
        let g = GraphEditorGeometry(lane: model.laneGeometry(width: bounds.width), height: bounds.height, curves: curves)
        return gesture.map { g.growing(from: $0.geometry) } ?? g
    }

    private var drawKey: DrawKey {
        DrawKey(cache: cacheKey, selection: model.selection, viewport: model.viewport, size: bounds.size, showAll: model.graphShowAll)
    }

    /// Content part of a model change (toolbar, curves): redraws only when what is drawn changed.
    func refreshContent() {
        toolbar.update()
        let key = drawKey
        if key != drawn { drawn = key; needsDisplay = true }
    }

    /// Playhead tick: moves the playhead layer, nothing else.
    func movePlayhead() { placePlayhead() }

    private let playheadLine = PlayheadLineView(color: Theme.Colors.playhead)

    private func placePlayhead() {
        if playheadLine.superview == nil { addSubview(playheadLine, positioned: .below, relativeTo: toolbar) }
        playheadLine.isHidden = !model.playheadInClip
        let lane = model.laneGeometry(width: bounds.width)
        let bottom = max(bounds.height - GraphEditorGeometry.bottomInset, 0)
        playheadLine.frame = PlayheadLineView.frame(centerX: lane.x(for: model.localPlayhead), height: bottom)
    }

    // MARK: Drawing

    /// Paths and labels of one drawn state; reused by playhead ticks, hover and tooltip redraws.
    private struct Artwork {
        var key: DrawKey
        var grid = CGMutablePath()
        var labels: [(NSAttributedString, CGPoint)] = []
        var curves: [(CGPath, CGColor)] = []
        var handleLines = CGMutablePath()
        var handleDots = CGMutablePath()
        var keysSelected = CGMutablePath()
        var keysPlain = CGMutablePath()
        var empty = false
    }
    private var artwork: Artwork?

    private static let labelAttributes: [NSAttributedString.Key: Any] = [.font: Theme.Typography.caption, .foregroundColor: Theme.Colors.label3]

    private func makeArtwork(_ g: GraphEditorGeometry, key: DrawKey) -> Artwork {
        artworkBuilds += 1
        var a = Artwork(key: key)
        for t in g.timeTicks() {
            a.grid.addRect(CGRect(x: g.lane.x(seconds: t).rounded(), y: g.plotTop, width: 1, height: g.plotBottom - g.plotTop))
        }
        for v in g.speedTicks() {
            let y = g.y(speed: v).rounded()
            a.grid.addRect(CGRect(x: 0, y: y, width: bounds.width, height: 1))
            let text = NSAttributedString(string: Self.format(v, decimals: v.rounded() == v ? 0 : 1) + "×", attributes: Self.labelAttributes)
            a.labels.append((text, CGPoint(x: 4, y: y + 1)))
        }
        let sel = key.selection
        for c in g.curves {
            let path = CGMutablePath()
            for line in g.polylines(c) {
                for (i, p) in line.enumerated() { i == 0 ? path.move(to: p) : path.addLine(to: p) }
            }
            a.curves.append((path, Self.palette[c.colorIndex % Self.palette.count].cgColor))
        }
        for c in g.curves {
            for h in c.curve.handles where sel.contains(SummaryMember(property: c.property, keyID: h.keyID)) {
                guard let k = c.curve.keys.first(where: { $0.id == h.keyID }), let hp = g.handlePoint(c, h) else { continue }
                a.handleLines.move(to: g.keyPoint(c, k)); a.handleLines.addLine(to: hp)
                a.handleDots.addEllipse(in: CGRect(x: hp.x - 3, y: hp.y - 3, width: 6, height: 6))
            }
            for k in c.curve.keys {
                let kp = g.keyPoint(c, k)
                let r = CGRect(x: kp.x - 3.5, y: kp.y - 3.5, width: 7, height: 7)
                if sel.contains(SummaryMember(property: c.property, keyID: k.id)) { a.keysSelected.addRect(r) } else { a.keysPlain.addRect(r) }
            }
        }
        a.empty = g.curves.isEmpty
        return a
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let g = geometry
        let key = drawKey
        let art: Artwork
        if gesture == nil, let a = artwork, a.key == key { art = a } else { art = makeArtwork(g, key: key); artwork = art }

        ctx.setFillColor(Theme.Colors.lane.cgColor); ctx.fill(bounds)
        ctx.setFillColor(Theme.Colors.separator.cgColor); ctx.addPath(art.grid); ctx.fillPath()
        for (text, at) in art.labels { text.draw(at: at) }
        ctx.setFillColor(Theme.Colors.label3.cgColor)
        ctx.fill(CGRect(x: 0, y: g.plotBottom.rounded(), width: bounds.width, height: 1))

        ctx.setLineWidth(1.5); ctx.setLineJoin(.round)
        for (path, color) in art.curves { ctx.setStrokeColor(color); ctx.addPath(path); ctx.strokePath() }
        ctx.setStrokeColor(Self.handleColor.cgColor); ctx.setLineWidth(1)
        ctx.addPath(art.handleLines); ctx.strokePath()
        ctx.setFillColor(Self.handleColor.cgColor); ctx.addPath(art.handleDots); ctx.fillPath()
        // Plain keys: lane-colored square with a white outline; selected keys: solid white.
        ctx.setFillColor(Theme.Colors.lane.cgColor); ctx.addPath(art.keysPlain); ctx.fillPath()
        ctx.setStrokeColor(Theme.OnPicture.stroke.cgColor); ctx.setLineWidth(1)
        ctx.saveGState()
        ctx.addPath(art.keysPlain); ctx.replacePathWithStrokedPath(); ctx.clip()   // outline stays inside the 7 pt box
        ctx.setFillColor(Theme.OnPicture.stroke.cgColor); ctx.fill(bounds)
        ctx.restoreGState()
        ctx.setFillColor(Theme.OnPicture.stroke.cgColor); ctx.addPath(art.keysSelected); ctx.fillPath()

        if art.empty {
            let text = model.graphShowAll ? "No animated properties" : "Select properties on the left to show their speed"
            let s = NSAttributedString(string: text, attributes: [.font: Theme.Typography.body, .foregroundColor: Theme.Colors.label3])
            s.draw(at: NSPoint(x: (bounds.width - s.size().width) / 2, y: (g.plotTop + g.plotBottom) / 2 - s.size().height / 2))
        }
        if let m = marquee {
            ctx.setFillColor(Theme.Colors.accentTint.cgColor); ctx.fill(m)
            ctx.setStrokeColor(Theme.Colors.accent.cgColor); ctx.setLineWidth(1)
            ctx.stroke(m.insetBy(dx: 0.5, dy: 0.5))
        }
        if let gs = gesture, gs.moved, case .handle(let m, let side) = gs.kind, let c = g.curve(m.property),
           let h = c.curve.handles.first(where: { $0.keyID == m.keyID && $0.side == side }), let hp = g.handlePoint(c, h) {
            // Speed and influence while the handle is dragged (values before the release).
            drawValueReadout(at: hp, text: GraphHandleReadout.text(title: c.title, speed: abs(h.speed), influence: h.influence, unit: c.unit))
        }
        if gesture == nil, let p = hoverPoint, case .handle(let m, let side) = g.hitTest(p, selected: model.selection),
           let c = g.curve(m.property), let h = c.curve.handles.first(where: { $0.keyID == m.keyID && $0.side == side }) {
            // Hovering a handle shows what a drag would change: speed and influence, before any press.
            drawValueReadout(at: p, text: GraphHandleReadout.text(title: c.title, speed: h.speed * c.scale, influence: h.influence, unit: c.unit))
        } else if gesture == nil, let p = hoverPoint, let hit = g.hover(at: p), let c = g.curve(hit.property) {
            drawValueReadout(at: p, text: "\(model.clip?.name ?? "Clip") · \(c.title)\n\(Self.format(hit.speed, decimals: 2)) \(c.unit)/s")
        }
    }

    /// Live speed readout next to the pointer (After Effects). Not a tooltip: it follows the pointer and changes with
    /// it, so it is drawn on the SQ overlay surface; control tooltips stay `Tooltip.text` (INTERACTION-AUDIT §9).
    private func drawValueReadout(at p: CGPoint, text: String) {
        let s = NSAttributedString(string: text, attributes: [.font: Theme.Typography.caption, .foregroundColor: Theme.Colors.label])
        let size = s.size()
        var r = NSRect(x: p.x + 10, y: p.y - size.height - 8, width: size.width + 10, height: size.height + 6)
        if r.maxX > bounds.width { r.origin.x = p.x - r.width - 10 }
        if r.minY < 0 { r.origin.y = p.y + 12 }
        let tip = NSBezierPath(roundedRect: r, xRadius: Theme.Radius.control, yRadius: Theme.Radius.control)
        Theme.Colors.overlay.setFill(); tip.fill()
        Theme.Colors.overlayEdge.setStroke(); tip.lineWidth = Theme.Overlay.edgeWidth; tip.stroke()
        s.draw(at: NSPoint(x: r.minX + 5, y: r.minY + 3))
    }

    static func format(_ v: Double, decimals: Int = 0) -> String { ControlsNumberText.format(v, decimals: decimals) }

    // MARK: Hover

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t); tracking = t
    }
    public override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hoverPoint = p
        if gesture == nil {
            KeyframeCursor.cursor(overGrip: geometry.hitTest(p, selected: model.selection) != .empty, dragging: false).set()
        }
        needsDisplay = true
    }
    public override func mouseExited(with event: NSEvent) {
        hoverPoint = nil; needsDisplay = true
        if gesture == nil { NSCursor.arrow.set() }
    }

    // MARK: Mouse

    public override func mouseDown(with event: NSEvent) {
        escapeCancelled = false
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        let g = GraphEditorGesture(at: p, shift: event.modifierFlags.contains(.shift), geometry: geometry, selection: model.selection)
        gesture = g
        dragCoalescer.begin()
        pendingDrag = nil
        switch g.kind { case .keys, .handle: KeyframeCursor.cursor(overGrip: true, dragging: true).set(); default: break }
        if g.selection != model.selection { model.select(Array(g.selection), extend: false) }
        needsDisplay = true
    }

    public override func mouseDragged(with event: NSEvent) {
        guard !escapeCancelled, var g = gesture else { return }
        let wasMoved = g.moved
        let action = g.drag(to: convert(event.locationInWindow, from: nil), constrain: event.modifierFlags.contains(.shift))
        gesture = g
        if g.moved && !wasMoved {
            switch g.kind { case .keys, .handle: model.beginGesture(); default: break }
        }
        switch action {
        case .moveKeys(let s):
            // Snap within 6 pt; Cmd moves without snapping.
            let tol = event.modifierFlags.contains(.command) ? nil : 6 / max(g.geometry.lane.pointsPerSecond, 1e-9)
            pendingDrag = { [weak self] in self?.model.moveGraphSelection(bySeconds: s, snapTolerance: tol) }
            dragCoalescer.submit(0)
        case .setHandle(let h, let side):
            pendingDrag = { [weak self] in self?.model.setGraphHandle(h, side: side) }
            dragCoalescer.submit(0)
        case .select(let s, let rect):
            marquee = rect
            if s != model.selection { model.select(Array(s), extend: false) }
        case .nothing: break
        }
        needsDisplay = true
    }

    public override func mouseUp(with event: NSEvent) {
        defer { gesture = nil; marquee = nil; needsDisplay = true; mouseMoved(with: event) }
        if escapeCancelled { escapeCancelled = false; return }
        guard let g = gesture else { return }
        dragCoalescer.flush()      // the newest pointer position is committed before the drag ends
        if g.moved {
            switch g.kind {
            case .keys: model.endGraphKeyMove()
            case .handle: model.endGesture()
            default: break
            }
        } else {
            let s = g.endSelection()
            if s != model.selection { model.select(Array(s), extend: false) }
        }
    }

    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, let g = gesture, case .marquee = g.kind {   // Escape: the marquee is dropped, the selection returns
            if g.baseSelection != model.selection { model.select(Array(g.baseSelection), extend: false) }
            gesture = nil; marquee = nil; escapeCancelled = true
            needsDisplay = true
            return
        }
        if event.keyCode == 53, let g = gesture, g.moved {          // Escape: the drag is undone
            switch g.kind {
            case .keys: _ = model.moveSelection(by: .zero); model.endGraphKeyMove()
            case .handle: model.cancelGesture()
            default: break
            }
            dragCoalescer.drop(); pendingDrag = nil
            gesture = nil; marquee = nil; escapeCancelled = true
            needsDisplay = true
            return
        }
        if let sc = GraphEditorShortcut.resolve(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
                                                flags: event.modifierFlags) {
            model.perform(sc); needsDisplay = true; return
        }
        if KeyframeZoomInput.key(event, model: model) { return }
        switch event.keyCode {
        case 51, 117: model.deleteSelectionOrEffect()
        default: super.keyDown(with: event)
        }
    }

    // MARK: Zoom / pan (shared keyframe viewport)

    public override func magnify(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        model.zoom(by: KeyframeZoomInput.magnifyFactor(event.magnification), around: geometry.lane.seconds(atX: x))
    }

    public override func scrollWheel(with event: NSEvent) {
        let lane = model.laneGeometry(width: bounds.width)
        switch KeyframeZoomInput.scroll(event) {
        case .zoom(let f): model.zoom(by: f, around: lane.seconds(atX: convert(event.locationInWindow, from: nil).x))
        case .pan(let pts): model.panViewport(bySeconds: -Double(pts) / max(lane.pointsPerSecond, 1e-6))
        case .none: super.scrollWheel(with: event)
        }
    }

    // MARK: Key menu

    public override func rightMouseDown(with event: NSEvent) {
        SQContextMenu.show(items: keyItems(for: event), for: event, in: self)
    }

    private func keyItems(for event: NSEvent) -> [SQMenuItem] {
        let hit = geometry.hitTest(convert(event.locationInWindow, from: nil), selected: model.selection)
        var onKey = false
        if case .key(let m) = hit {
            onKey = true
            if !model.selection.contains(m) { model.select([m], extend: false) }
        }
        if case .handle = hit { onKey = true }
        return keyMenu?(onKey) ?? []
    }
}

/// Bottom toolbar of the Graph Editor, centered under the plot: Fit | Snap | Smooth, Smooth in, Smooth out | Steady |
/// Hold, Hold Ahead.
final class GraphEditorToolbar: NSView {
    let model: EffectControlsModel
    private(set) var buttons: [IconButton] = []
    private let snap: IconButton
    private var easeButtons: [IconButton] = []
    /// Index of the buttons a gap is placed before (the groups).
    private let groupStarts: Set<Int> = [1, 2, 5, 6]

    init(model m: EffectControlsModel) {
        model = m
        let fit = IconButton(symbol: .moveHorizontal, label: "Fit") { m.fitGraph() }
        snap = IconButton(symbol: .snap, label: "Snap") { m.graphSnap.toggle() }
        super.init(frame: .zero)
        let eases: [(KeyInterpolationChoice, String)] = [(.linear, EaseName.steady), (.easyEase, EaseName.smooth), (.easeIn, EaseName.smoothIn),
                                                         (.easeOut, EaseName.smoothOut), (.hold, EaseName.hold),
                                                         (.holdAhead, EaseName.holdAhead)]
        for (choice, label) in eases {
            let b = IconButton(symbol: .circleDot, label: label) { m.applyGraphEase(choice) }
            b.image = Self.easeGlyph(choice)
            easeButtons.append(b)
        }
        buttons = [fit, snap] + easeButtons
        buttons.forEach(addSubview)
        wantsLayer = true
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("Graph Editor tools")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Theme.Colors.panel.setFill(); bounds.fill()
        Theme.Colors.separator.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    override func layout() {
        super.layout()
        let slot: CGFloat = 26, gap: CGFloat = 12
        let total = CGFloat(buttons.count) * slot + CGFloat(groupStarts.count) * gap
        var x = max((bounds.width - total) / 2, 4)
        for (i, b) in buttons.enumerated() {
            if groupStarts.contains(i) { x += gap }
            b.frame = NSRect(x: x, y: 2, width: slot, height: bounds.height - 4); x += slot
        }
    }

    func update() {
        snap.contentTintColor = model.graphSnap ? Theme.Colors.accent : Theme.Colors.label2
        let hasKeys = !model.selection.isEmpty
        easeButtons.forEach { $0.isEnabled = hasKeys; $0.contentTintColor = Theme.Colors.label2 }
        // Hold Ahead (last button) only where every selected key can store it (not on Animation In/Out rows).
        easeButtons.last?.isEnabled = hasKeys && model.selectionTakesHoldAhead
    }

    /// Small curve glyph per ease button (value over time: step, line, S-curves).
    static func easeGlyph(_ c: KeyInterpolationChoice) -> NSImage {
        let img = NSImage(size: NSSize(width: 16, height: 12), flipped: false) { r in
            let a = NSPoint(x: 1.5, y: 1.5), b = NSPoint(x: r.width - 1.5, y: r.height - 1.5)
            let p = NSBezierPath(); p.lineWidth = 1.3; p.lineCapStyle = .round
            p.move(to: a)
            let w = b.x - a.x
            switch c {
            case .hold: p.line(to: NSPoint(x: b.x - 2, y: a.y)); p.line(to: NSPoint(x: b.x - 2, y: b.y)); p.line(to: b)
            // The Hold glyph mirrored: the step comes right after the left key.
            case .holdAhead: p.line(to: NSPoint(x: a.x + 2, y: a.y)); p.line(to: NSPoint(x: a.x + 2, y: b.y)); p.line(to: b)
            case .linear: p.line(to: b)
            case .autoBezier: p.curve(to: b, controlPoint1: NSPoint(x: a.x + w * 0.3, y: a.y + 3), controlPoint2: NSPoint(x: b.x - w * 0.3, y: b.y - 3))
            case .easyEase: p.curve(to: b, controlPoint1: NSPoint(x: a.x + w * 0.6, y: a.y), controlPoint2: NSPoint(x: b.x - w * 0.6, y: b.y))
            case .easeIn: p.curve(to: b, controlPoint1: NSPoint(x: a.x + w * 0.3, y: a.y + 3), controlPoint2: NSPoint(x: b.x - w * 0.6, y: b.y))
            default: p.curve(to: b, controlPoint1: NSPoint(x: a.x + w * 0.6, y: a.y), controlPoint2: NSPoint(x: b.x - w * 0.3, y: b.y - 3))
            }
            NSColor.black.setStroke(); p.stroke()
            for q in [a, b] { NSColor.black.setFill(); NSRect(x: q.x - 1.5, y: q.y - 1.5, width: 3, height: 3).fill() }
            return true
        }
        img.isTemplate = true
        return img
    }
}

/// Toggle between the keyframe lanes and the Graph Editor, in the panel header strip (highlighted when on).
public final class GraphEditorToggle: NSButton {
    public let model: EffectControlsModel
    public var onToggle: ((Bool) -> Void)?

    public init(model: EffectControlsModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 20))
        if let img = Theme.symbol(.chartLine, size: 12, label: "Graph Editor") { image = img; imagePosition = .imageOnly } else { title = "Graph" }
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = Theme.Radius.control
        sqToolTip = "Graph Editor"
        setAccessibilityLabel("Graph Editor")
        target = self; action = #selector(toggle(_:))
        update()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update() {
        contentTintColor = model.graphEditor ? Theme.Colors.accent : Theme.Colors.label2
        layer?.backgroundColor = model.graphEditor ? Theme.Colors.accentTint.cgColor : NSColor.clear.cgColor
        setAccessibilityValue(model.graphEditor ? "On" : "Off")
    }

    @objc private func toggle(_ sender: Any?) {
        model.toggleGraphEditor()
        update()
        onToggle?(model.graphEditor)
    }
}
