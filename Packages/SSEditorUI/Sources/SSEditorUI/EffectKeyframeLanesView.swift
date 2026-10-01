import AppKit
import SSCore

/// The right side of Effect Controls: one keyframe lane per row, clip range edge to edge.
/// Property rows show their own keys; a collapsed section shows summary keys (all children, one glyph per time).
/// Click selects (Shift toggles), drag moves the selection in time (frame snapped, one undo step),
/// drag on empty space is a marquee, right-click opens the easing menu. Never mutates anything itself:
/// every change goes through `EffectControlsModel`.
public final class EffectKeyframeLanesView: NSView {
    public let model: EffectControlsModel
    public var rows: [EffectRow] = [] { didSet { needsDisplay = true } }
    /// Asks for a preset name. Default: modal alert with a text field. Return nil to cancel.
    public var namePrompt: @MainActor (String) -> String? = EffectKeyframeLanesView.runNameAlert

    static let hitRadius: CGFloat = 6
    private static let dragThreshold: CGFloat = 3

    enum Hit: Equatable {
        case key(EffectProperty, UUID, Time)
        case summary(EffectSection, Time)
        case none
    }

    private enum Drag {
        case keys(downX: CGFloat, downTime: Time, started: Bool, hit: Hit, shift: Bool, wasSelected: Bool)
        case marquee(origin: CGPoint, base: Set<SummaryMember>, shift: Bool)
    }
    private var drag: Drag?
    private var marquee: CGRect?
    private var easeSide = EaseSide.both

    public init(model: EffectControlsModel) {
        self.model = model
        super.init(frame: .zero)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Keyframes")
    }
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var geometry: KeyframeLaneGeometry { model.laneGeometry(width: bounds.width) }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        Theme.Colors.lane.setFill(); bounds.fill()
        let geo = geometry
        let visible = rows.filter { $0.y + $0.height >= dirtyRect.minY && $0.y <= dirtyRect.maxY }
        for row in visible {
            let r = NSRect(x: 0, y: row.y, width: bounds.width, height: row.height)
            switch row.kind {
            case .graph: Theme.Colors.content.setFill(); r.fill()
            case .section: Theme.Colors.titlebar.setFill(); r.fill()
            default: break
            }
            Theme.Colors.separator.setFill()
            NSRect(x: 0, y: r.maxY - 1, width: r.width, height: 1).fill()
        }
        // Playhead line first, from the top to the very bottom (also below the last row): keys are drawn over it, so a
        // key at the playhead stays one solid shape.
        if model.playheadInClip {
            let x = (geo.x(for: model.localPlayhead)).rounded() + 0.5
            Theme.Colors.playhead.setFill()
            NSRect(x: x - 0.5, y: 0, width: 1, height: bounds.height).fill()
        }
        for row in visible {
            let cy = row.y + row.height / 2
            switch row.kind {
            case .property(let p):
                let sel = model.selectedKeyIDs(p)
                for k in model.track(p)?.glyphs ?? [] {
                    drawGlyph(k.glyph, at: NSPoint(x: geo.x(for: k.time), y: cy),
                              selected: sel.contains(k.id), summary: false)
                }
            case .section(let s) where model.collapsedSections.contains(s):
                for key in model.summaryKeys(s) {
                    let shape = Self.summaryGlyph(key, model: model)
                    drawGlyph(shape, at: NSPoint(x: geo.x(for: key.time), y: cy),
                              selected: model.isSelected(key), summary: true)
                }
            default: break
            }
        }
        if let m = marquee {
            Theme.Colors.accentTint.setFill(); m.fill()
            Theme.Colors.accent.setStroke()
            let p = NSBezierPath(rect: m.insetBy(dx: 0.5, dy: 0.5)); p.lineWidth = 1; p.stroke()
        }
    }

    /// Summary glyph: per side hold if every member is hold, eased if any member is eased, else linear.
    static func summaryGlyph(_ key: SummaryKey, model: EffectControlsModel) -> KeyGlyph {
        var glyphs: [KeyGlyph] = []
        for m in key.members {
            let t = model.track(EffectProperty(rawValue: m.property.rawValue) ?? .opacity)
            if let g = t?.glyphs.first(where: { $0.id == m.keyID }) { glyphs.append(g.glyph) }
        }
        return KeyGlyph.merged(glyphs)
    }

    /// One solid shape per key: diamond = linear, circle = any easing, square = hold. Selected = accent fill.
    private func drawGlyph(_ glyph: KeyGlyph, at c: NSPoint, selected: Bool, summary: Bool) {
        KeyGlyphDrawing.draw(glyph, at: c, size: summary ? 14 : 13,
                             fill: selected ? Theme.Colors.accent : (summary ? Theme.Colors.label2 : Theme.Colors.keyframe))
    }

    // MARK: Hit testing

    func hit(at p: CGPoint) -> Hit {
        guard let row = EffectControlsLayout.row(at: p.y, in: rows) else { return .none }
        let geo = geometry
        let start = model.clip?.start ?? .zero
        switch row.kind {
        case .property(let p0):
            let ks = model.keys(p0)
            let locals = ks.map { $0.time - start }
            if let i = geo.nearestIndex(toX: p.x, in: locals, radius: Self.hitRadius) { return .key(p0, ks[i].id, locals[i]) }
        case .section(let s) where model.collapsedSections.contains(s):
            let groups = model.summaryKeys(s)
            if let i = geo.nearestIndex(toX: p.x, in: groups.map(\.time), radius: Self.hitRadius) { return .summary(s, groups[i].time) }
        default: break
        }
        return .none
    }

    private func select(_ h: Hit, extend: Bool) {
        switch h {
        case .key(let p, let id, _): model.selectKey(p, id: id, extend: extend)
        case .summary(let s, let t):
            if let k = model.summaryKeys(s).first(where: { $0.time == t }) { model.selectSummary(k, extend: extend) }
        case .none: break
        }
    }

    private func isSelected(_ h: Hit) -> Bool {
        switch h {
        case .key(let p, let id, _): model.selectedKeyIDs(p).contains(id)
        case .summary(let s, let t): model.summaryKeys(s).first { $0.time == t }.map(model.isSelected) ?? false
        case .none: false
        }
    }

    // MARK: Mouse

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        let shift = event.modifierFlags.contains(.shift)
        let h = hit(at: p)
        if h == .none {
            let base = shift ? model.selection : []
            if !shift { model.clearSelection() }
            drag = .marquee(origin: p, base: base, shift: shift)
            return
        }
        let was = isSelected(h)
        if shift { select(h, extend: true) } else if !was { select(h, extend: false) }
        drag = .keys(downX: p.x, downTime: geometry.time(at: p.x, frameDuration: model.frameDuration),
                     started: false, hit: h, shift: shift, wasSelected: was)
    }

    public override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch drag {
        case .keys(let downX, let downTime, let started, let h, let shift, let was)?:
            guard !shift else { return }
            if !started {
                guard abs(p.x - downX) >= Self.dragThreshold else { return }
                model.beginGesture()
                drag = .keys(downX: downX, downTime: downTime, started: true, hit: h, shift: shift, wasSelected: was)
            }
            let now = geometry.time(at: p.x, frameDuration: model.frameDuration)
            model.moveSelection(by: now - downTime)
        case .marquee(let origin, let base, let shift)?:
            let r = NSRect(x: min(origin.x, p.x), y: min(origin.y, p.y), width: abs(p.x - origin.x), height: abs(p.y - origin.y))
            marquee = r
            applyMarquee(r, base: base, shift: shift)
            needsDisplay = true
        case nil: break
        }
    }

    public override func mouseUp(with event: NSEvent) {
        defer { drag = nil; marquee = nil; needsDisplay = true }
        guard case .keys(_, _, let started, let h, let shift, let was)? = drag else { return }
        if started { model.endKeyMove() }       // one undo step; the moved keys are deselected
        else if was && !shift { select(h, extend: false) }   // plain click on a selected key collapses the selection to it
    }

    private func applyMarquee(_ r: NSRect, base: Set<SummaryMember>, shift: Bool) {
        var props = Set<EffectProperty>()
        for row in rows where row.y < r.maxY && row.y + row.height > r.minY {
            switch row.kind {
            case .property(let p): props.insert(p)
            case .section(let s) where model.collapsedSections.contains(s): props.formUnion(s.properties)
            default: break
            }
        }
        let geo = geometry, fd = model.frameDuration
        let half = Time(fd.value, fd.timescale * 2)
        let lo = geo.time(at: r.minX, frameDuration: fd) - half
        let hi = geo.time(at: r.maxX, frameDuration: fd) + half
        model.select(shift ? Array(base) : [], extend: false)
        model.selectKeys(in: lo ... hi, properties: props, extend: true)
    }

    // MARK: Zoom

    public override func magnify(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        model.zoom(by: KeyframeZoomInput.magnifyFactor(event.magnification), around: geometry.seconds(atX: x))
    }

    public override func scrollWheel(with event: NSEvent) {
        switch KeyframeZoomInput.scroll(event) {
        case .zoom(let f): model.zoom(by: f, around: geometry.seconds(atX: convert(event.locationInWindow, from: nil).x))
        case .pan(let pts): model.panViewport(bySeconds: -Double(pts) / max(geometry.pointsPerSecond, 1e-6))
        case .none: super.scrollWheel(with: event)
        }
    }

    public override func keyDown(with event: NSEvent) {
        if KeyframeZoomInput.key(event, model: model) { return }
        switch event.keyCode {
        case 51, 117: model.deleteSelectionOrEffect()
        default: super.keyDown(with: event)
        }
    }

    // MARK: Easing menu (same entries as the graph view)

    public override func menu(for event: NSEvent) -> NSMenu? {
        let h = hit(at: convert(event.locationInWindow, from: nil))
        if h != .none, !isSelected(h) { select(h, extend: false) }
        return makeEasingMenu()
    }

    public func makeEasingMenu() -> NSMenu {
        let has = !model.selection.isEmpty
        let spec = EasingMenuSpec(library: model.easingLibrary, side: easeSide, hasSelection: has)
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
        menu.addItem(.separator())
        let del = NSMenuItem(title: "Delete Keyframes", action: #selector(deleteKeys(_:)), keyEquivalent: "")
        del.target = self; del.isEnabled = has
        menu.addItem(del)
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
        if let c = sender.representedObject as? EasingCurve { model.applyEasing(c, side: easeSide) }
    }
    @objc private func saveCurve(_ sender: NSMenuItem) {
        guard let name = namePrompt("Curve")?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return }
        model.saveCurveFromSelection(name: name)
    }
    @objc private func deleteKeys(_ sender: NSMenuItem) { model.deleteSelection() }

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

extension PropertyTrack {
    /// Id, clip-local time and glyph of every key (for drawing).
    var glyphs: [(id: UUID, time: Time, glyph: KeyGlyph)] {
        switch self {
        case .scalar(let t): KeyGlyph.glyphs(of: t)
        case .vector(let t): KeyGlyph.glyphs(of: t)
        }
    }
}

enum KeyGlyphDrawing {
    /// One closed path, fill only.
    static func path(_ shape: KeyShape, at c: NSPoint, size: CGFloat) -> NSBezierPath {
        if shape == .circle { return NSBezierPath(ovalIn: shape.bounds(at: c, size: size)) }
        let pts = shape.corners(at: c, size: size)
        let path = NSBezierPath()
        path.move(to: pts[0])
        for p in pts.dropFirst() { path.line(to: p) }
        path.close()
        return path
    }

    static func draw(_ glyph: KeyGlyph, at c: NSPoint, size: CGFloat, fill: NSColor) {
        fill.setFill()
        path(glyph.shape, at: c, size: size).fill()
    }
}
