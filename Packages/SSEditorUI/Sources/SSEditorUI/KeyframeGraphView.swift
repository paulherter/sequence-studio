import AppKit
import SSCore

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
    public var maxTime: Time?
    public var easingLibrary = EasingLibrary()

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
    private func refit() { fit = GraphFit.make(track: track, mode: mode) }
    private var geometry: KeyframeGraphGeometry { KeyframeGraphGeometry(size: bounds.size, fit: fit, mode: mode) }
    private var limits: GraphEditLimits { GraphEditLimits(frameDuration: frameDuration, minTime: minTime, maxTime: maxTime) }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        let g = geometry
        Theme.Colors.lane.setFill()
        bounds.fill()

        let plot = g.plot
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: plot.insetBy(dx: -1, dy: -4)).addClip()

        // Grid
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.Fonts.mini, .foregroundColor: Theme.Colors.label3]
        for v in g.gridValues() {
            let y = g.y(value: v).rounded() + 0.5
            (v == 0 ? Theme.Colors.label3 : Theme.Colors.separator).setStroke()
            let line = NSBezierPath()
            line.move(to: NSPoint(x: plot.minX, y: y)); line.line(to: NSPoint(x: plot.maxX, y: y))
            line.lineWidth = 1
            line.stroke()
        }
        if let ph = playheadSeconds {
            let x = g.x(seconds: ph).rounded() + 0.5
            Theme.Colors.playhead.setStroke()
            let l = NSBezierPath()
            l.move(to: NSPoint(x: x, y: plot.minY - 4)); l.line(to: NSPoint(x: x, y: plot.maxY + 4))
            l.lineWidth = 1
            l.stroke()
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
                Theme.Colors.accentRing.setStroke()
                let l = NSBezierPath()
                l.move(to: kp); l.line(to: hp); l.lineWidth = 1; l.stroke()
                let r = NSRect(x: hp.x - 3.5, y: hp.y - 3.5, width: 7, height: 7)
                let dot = NSBezierPath(ovalIn: r)
                Theme.Colors.lane.setFill(); dot.fill()
                Theme.Colors.accent.setStroke(); dot.lineWidth = 1.5; dot.stroke()
            }
        }
        // Keys
        for (i, k) in t.keys.enumerated() {
            drawGlyph(k.interpolation, at: g.keyPoint(track: t, index: i), selected: selectedKeyIDs.contains(k.id))
        }
        NSGraphicsContext.restoreGraphicsState()

        // Axis labels
        let fmt: (Double) -> String = { abs($0) >= 100 ? String(format: "%.0f", $0) : String(format: "%.2f", $0) }
        for v in g.gridValues() {
            let s = NSAttributedString(string: fmt(v), attributes: attrs)
            let size = s.size()
            s.draw(at: NSPoint(x: plot.minX - size.width - 6, y: g.y(value: v) - size.height / 2))
        }

        if let m = marquee {
            Theme.Colors.accentTint.setFill(); m.fill()
            Theme.Colors.accent.setStroke()
            let p = NSBezierPath(rect: m.insetBy(dx: 0.5, dy: 0.5)); p.lineWidth = 1; p.stroke()
        }
    }

    private func drawGlyph(_ kind: Interpolation, at c: CGPoint, selected: Bool) {
        let r: CGFloat = 4.5
        let path: NSBezierPath
        switch kind {
        case .linear:
            path = NSBezierPath()
            path.move(to: NSPoint(x: c.x, y: c.y - r - 1)); path.line(to: NSPoint(x: c.x + r + 1, y: c.y))
            path.line(to: NSPoint(x: c.x, y: c.y + r + 1)); path.line(to: NSPoint(x: c.x - r - 1, y: c.y))
            path.close()
        case .bezier: path = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        case .hold: path = NSBezierPath(rect: NSRect(x: c.x - r + 0.5, y: c.y - r + 0.5, width: 2 * r - 1, height: 2 * r - 1))
        }
        (selected ? Theme.Colors.accent : Theme.Colors.keyframe).setFill()
        path.fill()
        Theme.black(0.55).setStroke(); path.lineWidth = 1; path.stroke()
    }

    // MARK: Mouse

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        refit()
        gesture = GraphGestureState(at: p, shift: event.modifierFlags.contains(.shift), geometry: geometry,
                                    track: track, selection: selectedKeyIDs, limits: limits)
        apply(gesture!.current)
    }

    public override func mouseDragged(with event: NSEvent) {
        guard gesture != nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        if let r = gesture?.drag(to: p) { apply(r) }
    }

    public override func mouseUp(with event: NSEvent) {
        guard var g = gesture else { return }
        let r = g.end(at: convert(event.locationInWindow, from: nil))
        gesture = nil; preview = nil; marquee = nil
        setSelection(r.selection)
        if r.commit { track = r.track; onEdit?(r.track) } else { refit() }
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

    // MARK: Easing menu

    public override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        refit()
        if case .key(let id) = geometry.hitTest(p, track: track, selected: selectedKeyIDs), !selectedKeyIDs.contains(id) {
            setSelection([id])
        }
        return makeEasingMenu()
    }

    /// Menu: side choice (applies to in / out / both), built-in curves, user presets, Save Curve.
    public func makeEasingMenu() -> NSMenu {
        let spec = EasingMenuSpec(library: easingLibrary, side: easeSide, hasSelection: !selectedKeyIDs.isEmpty)
        let menu = NSMenu(title: "Easing")
        menu.autoenablesItems = false

        for entry in spec.entries {
            switch entry {
            case .header(let title):
                menu.addItem(NSMenuItem.sectionHeader(title: title))
            case .side(let s, let title, let checked):
                let item = NSMenuItem(title: title, action: #selector(pickSide(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = SideBox(s); item.state = checked ? .on : .off
                menu.addItem(item)
            case .curve(let c, let enabled):
                let item = NSMenuItem(title: c.name, action: #selector(applyCurve(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = c; item.isEnabled = enabled
                menu.addItem(item)
            case .separator:
                menu.addItem(.separator())
            case .saveCurve(let enabled):
                let item = NSMenuItem(title: "Save Curve\u{2026}", action: #selector(saveCurve(_:)), keyEquivalent: "")
                item.target = self; item.isEnabled = enabled
                menu.addItem(item)
            }
        }
        return menu
    }

    private final class SideBox: NSObject {
        let side: EaseSide
        init(_ s: EaseSide) { side = s }
    }

    @objc private func pickSide(_ sender: NSMenuItem) {
        if let b = sender.representedObject as? SideBox { easeSide = b.side }
    }

    @objc private func applyCurve(_ sender: NSMenuItem) {
        guard let c = sender.representedObject as? EasingCurve, !selectedKeyIDs.isEmpty else { return }
        var t = track
        t.apply(c, to: selectedKeyIDs, side: easeSide)
        guard t != track else { return }
        track = t
        onEdit?(t)
    }

    @objc private func saveCurve(_ sender: NSMenuItem) {
        guard let key = track.keys.first(where: { selectedKeyIDs.contains($0.id) }),
              let name = namePrompt("Curve"), !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        easingLibrary.saveCurve(from: key, name: name.trimmingCharacters(in: .whitespaces))
        onLibraryChange?(easingLibrary)
    }

    @MainActor private static func runNameAlert(_ suggestion: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Save Curve"
        alert.informativeText = "Name for the new easing preset."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        field.stringValue = suggestion
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
}

/// Pure description of the easing menu (testable without AppKit).
public struct EasingMenuSpec: Sendable, Equatable {
    public enum Entry: Sendable, Equatable {
        case header(String)
        case side(EaseSide, title: String, checked: Bool)
        case curve(EasingCurve, enabled: Bool)
        case separator
        case saveCurve(enabled: Bool)
    }
    public var entries: [Entry]

    public init(library: EasingLibrary, side: EaseSide, hasSelection: Bool) {
        var e: [Entry] = [.header("Apply To")]
        e.append(.side(.both, title: "Both Sides", checked: side == .both))
        e.append(.side(.in, title: "Incoming Only", checked: side == .in))
        e.append(.side(.out, title: "Outgoing Only", checked: side == .out))
        e.append(.separator)
        e.append(.header("Easing"))
        for c in EasingCurve.builtIns { e.append(.curve(c, enabled: hasSelection)) }
        if !library.userCurves.isEmpty {
            e.append(.separator)
            e.append(.header("My Curves"))
            for c in library.userCurves { e.append(.curve(c, enabled: hasSelection)) }
        }
        e.append(.separator)
        e.append(.saveCurve(enabled: hasSelection))
        entries = e
    }

    public var curveNames: [String] { entries.compactMap { if case .curve(let c, _) = $0 { c.name } else { nil } } }
}
