import AppKit

extension SQColorValue {
    public var nsColor: NSColor {
        let c = rgb
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: a)
    }

    public init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? color
        self.init(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent), a: Double(c.alphaComponent))
    }
}

/// Saturation/brightness field (140 high, radius 6, 10 pt ring knob) and the hue / opacity bars (10 high capsule,
/// 14 pt white knob that overhangs the bar by 2 pt), all drawn with gradients. Bars are 14 high so the knob is hit-testable.
private final class SQColorSlider: NSView {
    enum Kind { case hue, alpha, satBright }
    static let barHeight: CGFloat = 10
    static let barKnob: CGFloat = 14
    static let fieldHeight: CGFloat = 140
    static let fieldRadius: CGFloat = 6
    static let fieldKnob: CGFloat = 10

    let kind: Kind
    var value: SQColorValue { didSet { needsDisplay = true } }
    var onChange: ((SQColorValue) -> Void)?
    override var isFlipped: Bool { true }

    init(kind: Kind, value: SQColorValue) {
        self.kind = kind; self.value = value
        super.init(frame: .zero)
        setAccessibilityRole(.slider)
        setAccessibilityLabel(kind == .hue ? "Hue" : kind == .alpha ? "Opacity" : "Saturation and brightness")
    }
    required init?(coder: NSCoder) { fatalError() }

    private var trackRect: CGRect {
        kind == .satBright ? bounds : CGRect(x: 0, y: (bounds.height - Self.barHeight) / 2, width: bounds.width, height: Self.barHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = trackRect
        let radius = kind == .satBright ? Self.fieldRadius : Self.barHeight / 2
        let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        switch kind {
        case .hue:
            let cols = (0...6).map { SQColorValue(h: Double($0) / 6, s: 1, b: 1).nsColor }
            NSGradient(colors: cols)?.draw(in: r, angle: 0)
        case .alpha:
            let sq: CGFloat = 4
            for y in 0..<Int(ceil(r.height / sq)) { for x in 0..<Int(ceil(r.width / sq)) {
                (((x + y) % 2 == 0) ? Theme.Palette.checker.dark : Theme.Palette.checker.light).setFill()
                CGRect(x: r.minX + CGFloat(x) * sq, y: r.minY + CGFloat(y) * sq, width: sq, height: sq).fill()
            } }
            var c = value; c.a = 0
            var o = value; o.a = 1
            NSGradient(starting: c.nsColor, ending: o.nsColor)?.draw(in: r, angle: 0)
        case .satBright:
            SQColorValue(h: value.h, s: 1, b: 1).nsColor.setFill(); r.fill()
            NSGradient(starting: Theme.OnPicture.stroke, ending: Theme.OnPicture.stroke.withAlphaComponent(0))?.draw(in: r, angle: 0)
            NSGradient(starting: Theme.black(0), ending: Theme.black(1))?.draw(in: r, angle: -90)
        }
        NSGraphicsContext.restoreGraphicsState()
        // Knob.
        if kind == .satBright {
            let p = CGPoint(x: value.s * r.width, y: (1 - value.b) * r.height)
            let kr = CGRect(x: p.x - Self.fieldKnob / 2, y: p.y - Self.fieldKnob / 2, width: Self.fieldKnob, height: Self.fieldKnob)
            Theme.OnPicture.shadow.setStroke()
            let outer = NSBezierPath(ovalIn: kr.insetBy(dx: -1, dy: -1)); outer.lineWidth = 1; outer.stroke()
            Theme.OnPicture.stroke.setStroke()
            let ring = NSBezierPath(ovalIn: kr); ring.lineWidth = 2; ring.stroke()
        } else {
            let half = Self.barKnob / 2
            let t = kind == .hue ? value.h : value.a
            let cx = half + t * max(bounds.width - Self.barKnob, 0)
            let kr = CGRect(x: cx - half, y: bounds.midY - half, width: Self.barKnob, height: Self.barKnob)
            NSGraphicsContext.saveGraphicsState()
            let sh = NSShadow()
            sh.shadowColor = Theme.black(0.9); sh.shadowBlurRadius = 3; sh.shadowOffset = NSSize(width: 0, height: -1)
            sh.set()
            Theme.OnPicture.stroke.setFill()
            NSBezierPath(ovalIn: kr).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    override func mouseDown(with event: NSEvent) { update(event) }
    override func mouseDragged(with event: NSEvent) { update(event) }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func update(_ e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        var v = value
        if kind == .satBright {
            v.s = min(max(p.x / max(bounds.width, 1), 0), 1)
            v.b = 1 - min(max(p.y / max(bounds.height, 1), 0), 1)
        } else {
            let half = Self.barKnob / 2
            let x = min(max((p.x - half) / max(bounds.width - Self.barKnob, 1), 0), 1)
            if kind == .hue { v.h = min(x, 0.9999) } else { v.a = x }
        }
        value = v
        onChange?(v)
    }

    override func keyDown(with event: NSEvent) {
        let step = event.modifierFlags.contains(.shift) ? 0.1 : 0.01
        var v = value
        switch (event.keyCode, kind) {
        case (123, .hue): v.h = max(0, v.h - step)
        case (124, .hue): v.h = min(0.9999, v.h + step)
        case (123, .alpha): v.a = max(0, v.a - step)
        case (124, .alpha): v.a = min(1, v.a + step)
        case (123, .satBright): v.s = max(0, v.s - step)
        case (124, .satBright): v.s = min(1, v.s + step)
        case (125, .satBright): v.b = max(0, v.b - step)
        case (126, .satBright): v.b = min(1, v.b + step)
        default: super.keyDown(with: event); return
        }
        value = v
        onChange?(v)
    }
}

/// Color pill (38 x 20 for the well and the picker's preview): checkerboard under a translucent color, hairline edge.
private final class SQColorPill: NSView {
    var color: NSColor = .white { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        let p = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        NSGraphicsContext.saveGraphicsState()
        p.addClip()
        if color.alphaComponent < 1 {
            let sq: CGFloat = 5
            for y in 0..<Int(ceil(r.height / sq)) { for x in 0..<Int(ceil(r.width / sq)) {
                (((x + y) % 2 == 0) ? Theme.Palette.checker.dark : Theme.Palette.checker.light).setFill()
                CGRect(x: CGFloat(x) * sq, y: CGFloat(y) * sq, width: sq, height: sq).fill()
            } }
        }
        color.setFill(); r.fill()
        NSGraphicsContext.restoreGraphicsState()
        Theme.Colors.fieldEdge.setStroke()
        let e = NSBezierPath(roundedRect: r.insetBy(dx: 0.25, dy: 0.25), xRadius: r.height / 2, yRadius: r.height / 2)
        e.lineWidth = 0.5; e.stroke()
    }
}

/// Capsule (22 high) with a dimmed "#" and the hex digits.
private final class SQHexCapsule: NSView {
    let field = NSTextField()
    private let hashLabel = NSTextField(labelWithString: "#")
    var isFocused = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        hashLabel.font = Theme.Typography.body; hashLabel.textColor = Theme.Colors.label3
        field.isBordered = false; field.isBezeled = false; field.drawsBackground = false; field.focusRingType = .none
        field.font = Theme.Typography.body; field.textColor = Theme.Colors.label
        field.setAccessibilityLabel("Hex color")
        addSubview(hashLabel); addSubview(field)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let h = hashLabel.fittingSize.height, fh = field.fittingSize.height
        hashLabel.frame = CGRect(x: 8, y: ((bounds.height - h) / 2).rounded(), width: 8, height: h)
        field.frame = CGRect(x: 17, y: ((bounds.height - fh) / 2).rounded(), width: bounds.width - 17 - 8, height: fh)
    }
    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        Theme.Colors.field.setFill(); p.fill()
        let e = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        (isFocused ? Theme.State.focusRing : Theme.Colors.fieldEdge).setStroke()
        e.lineWidth = isFocused ? 1 : 0.5; e.stroke()
    }
}

/// Row of 16 pt recent-color dots (6 pt gap). Click picks.
private final class SQRecentDots: NSView {
    static let dot: CGFloat = 16
    static let gap: CGFloat = 6
    var colors: [SQColorValue] = [] { didSet { needsDisplay = true } }
    var onPick: ((SQColorValue) -> Void)?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        for (i, c) in colors.enumerated() {
            let r = CGRect(x: CGFloat(i) * (Self.dot + Self.gap), y: 0, width: Self.dot, height: Self.dot)
            c.nsColor.setFill(); NSBezierPath(ovalIn: r).fill()
            Theme.Colors.fieldEdge.setStroke()
            let e = NSBezierPath(ovalIn: r.insetBy(dx: 0.25, dy: 0.25)); e.lineWidth = 0.5; e.stroke()
        }
    }
    override func mouseDown(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        let i = Int(x / (Self.dot + Self.gap))
        if x >= 0, i < colors.count, x - CGFloat(i) * (Self.dot + Self.gap) <= Self.dot { onPick?(colors[i]) }
    }
}

/// Own flat color picker (replaces NSColorPanel), laid out as the Dialogs board: 232 wide, 12 padding, 10 gaps;
/// color field, hue bar, optional opacity bar, pill + hex capsule + eyedropper, then "Recent" with up to six dots.
@MainActor
public final class SQColorPickerView: NSView, NSTextFieldDelegate {
    public static let width: CGFloat = 232
    private static let pad: CGFloat = 12
    private static let gap: CGFloat = 10

    public var onChange: ((NSColor) -> Void)?
    /// The eyedropper started (true) or ended (false): the host popover must not close while the loupe is active.
    public var onEyedropperActive: ((Bool) -> Void)?
    public let showsAlpha: Bool
    public private(set) var value: SQColorValue

    private let defaults: UserDefaults
    private let square: SQColorSlider
    private let hue: SQColorSlider
    private let alpha: SQColorSlider
    private let hexBox = SQHexCapsule()
    private let pill = SQColorPill()
    private let dropper: SQButton
    private let recentCaption = NSTextField(labelWithString: "Recent")
    private let recentDots = SQRecentDots()
    private var loupe: SQLoupe?
    private var changed = false
    public override var isFlipped: Bool { true }

    public init(color: NSColor, showsAlpha: Bool = false, defaults: UserDefaults = .standard) {
        let v = SQColorValue(color)
        self.value = v; self.showsAlpha = showsAlpha; self.defaults = defaults
        square = SQColorSlider(kind: .satBright, value: v)
        hue = SQColorSlider(kind: .hue, value: v)
        alpha = SQColorSlider(kind: .alpha, value: v)
        dropper = SQButton(symbol: .eyedropper, label: "Pick color from screen", target: nil, action: nil)
        super.init(frame: .zero)
        let w = Self.width - 2 * Self.pad, p = Self.pad, g = Self.gap
        var y = p
        square.frame = CGRect(x: p, y: y, width: w, height: SQColorSlider.fieldHeight); y += SQColorSlider.fieldHeight + g
        let overhang = (SQColorSlider.barKnob - SQColorSlider.barHeight) / 2
        hue.frame = CGRect(x: p, y: y - overhang, width: w, height: SQColorSlider.barKnob); y += SQColorSlider.barHeight + g
        addSubview(square); addSubview(hue)
        if showsAlpha {
            alpha.frame = CGRect(x: p, y: y - overhang, width: w, height: SQColorSlider.barKnob); y += SQColorSlider.barHeight + g
            addSubview(alpha)
        }
        // Row: pill, hex capsule (flexible), eyedropper (24 wide, icon style).
        let rowH = Theme.Metrics.pushButton
        let iconW = Theme.Metrics.barIconWidth
        pill.frame = CGRect(x: p, y: y + (rowH - Theme.Row.swatch.height) / 2, width: Theme.Row.swatch.width, height: Theme.Row.swatch.height)
        let hexX = p + Theme.Row.swatch.width + 8
        hexBox.frame = CGRect(x: hexX, y: y, width: p + w - iconW - 8 - hexX, height: rowH)
        dropper.boxHeight = rowH
        dropper.frame = CGRect(x: p + w - iconW, y: y, width: iconW, height: rowH)
        dropper.target = self; dropper.action = #selector(startEyedropper)
        hexBox.field.delegate = self
        addSubview(pill); addSubview(hexBox); addSubview(dropper)
        y += rowH
        // Recents.
        recentCaption.font = Theme.Typography.caption; recentCaption.textColor = Theme.Colors.label3
        recentCaption.frame = CGRect(x: p, y: y + g, width: w, height: 13)
        recentDots.frame = CGRect(x: p, y: y + g + 13 + g, width: w, height: SQRecentDots.dot)
        recentDots.onPick = { [weak self] c in
            guard let self else { return }
            var n = c; if !self.showsAlpha { n.a = 1 }
            self.apply(n, fromHex: false)
        }
        addSubview(recentCaption); addSubview(recentDots)
        frame.size = CGSize(width: Self.width, height: y + p)
        for s in [square, hue, alpha] { s.onChange = { [weak self] v in self?.apply(v, fromHex: false) } }
        refreshRecents()
        refresh(fromHex: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    public override var intrinsicContentSize: NSSize { frame.size }

    /// Reloads the recent dots from defaults and resizes the view (the section is hidden while empty).
    public func refreshRecents() {
        let list = SQColorRecents.load(defaults).compactMap { SQColorValue.parse(hex: $0) }
        recentDots.colors = list
        let hidden = list.isEmpty
        recentCaption.isHidden = hidden; recentDots.isHidden = hidden
        let h = hidden ? hexBox.frame.maxY + Self.pad : recentDots.frame.maxY + Self.pad
        if abs(frame.height - h) > 0.5 { frame.size.height = h }
    }

    /// Remembers the current color in the recent row (call when a color gesture ends); no-op when nothing changed.
    public func commitRecent() {
        guard changed else { return }
        changed = false
        SQColorRecents.remember(value, in: defaults)
    }

    public func setColor(_ c: NSColor) {
        value = SQColorValue(c)
        refresh(fromHex: false)
    }

    private func apply(_ v: SQColorValue, fromHex: Bool) {
        value = v
        changed = true
        refresh(fromHex: fromHex)
        onChange?(v.nsColor)
    }

    private func refresh(fromHex: Bool) {
        for s in [square, hue, alpha] { s.value = value }
        pill.color = value.nsColor
        if !fromHex { hexBox.field.stringValue = value.hex }
    }

    public func controlTextDidBeginEditing(_ obj: Notification) { hexBox.isFocused = true }

    public func controlTextDidChange(_ obj: Notification) {
        if let v = SQColorValue.parse(hex: hexBox.field.stringValue, keepingAlpha: value.a) { apply(v, fromHex: true) }
    }

    public func controlTextDidEndEditing(_ obj: Notification) {
        hexBox.isFocused = false
        hexBox.field.stringValue = value.hex
        commitRecent()
    }

    @objc private func startEyedropper() {
        guard loupe == nil else { return }
        onEyedropperActive?(true)
        loupe = SQLoupe.begin(onPick: { [weak self] picked in
            guard let self else { return }
            var v = picked; v.a = self.value.a
            self.loupe = nil
            self.apply(v, fromHex: false)
            self.commitRecent()
            self.onEyedropperActive?(false)
        }, onCancel: { [weak self] in
            self?.loupe = nil
            self?.onEyedropperActive?(false)
        })
    }
}

/// Color swatch control (replaces NSColorWell): click opens an `SQPopover` with the flat picker.
/// Same surface as NSColorWell for callers: `color`, `isEnabled`, `target`/`action`.
@MainActor
public final class SQColorWell: NSControl {
    public var showsAlpha = false
    /// The picker popover closed (a color gesture is over).
    public var onClose: (() -> Void)?
    public var onOpen: (() -> Void)?
    /// True while the picker popover is open (NSColorWell parity).
    public var isActive: Bool { popover?.isShown == true }
    public var color: NSColor = .white { didSet { needsDisplay = true; if !fromPicker { picker?.setColor(color) } } }
    /// Multi-select, the selected items use different colors: an empty swatch with a dash (like a mixed checkbox).
    /// Picking a color sets it on all of them; the picker opens on `color`.
    public var isMixed = false {
        didSet { if oldValue != isMixed { needsDisplay = true; setAccessibilityValueDescription(isMixed ? "Mixed" : nil) } }
    }
    public override var isEnabled: Bool { didSet { needsDisplay = true } }
    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { isEnabled }
    public override var intrinsicContentSize: NSSize { Theme.Row.swatch }

    private var popover: SQPopover?
    private var picker: SQColorPickerView?
    private var hovered = false
    private var fromPicker = false

    public override init(frame: NSRect) { super.init(frame: frame); commonInit() }
    public required init?(coder: NSCoder) { super.init(coder: coder); commonInit() }
    private func commonInit() { setAccessibilityRole(.colorWell) }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        removeOwnTrackingAreas()
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    public override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    public override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    public override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let p = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        NSGraphicsContext.saveGraphicsState()
        p.addClip()
        if isMixed {
            Theme.Colors.field.setFill(); r.fill()
            NSGraphicsContext.restoreGraphicsState()
            let dash = NSRect(x: r.midX - 4, y: r.midY - 0.75, width: 8, height: 1.5)
            (isEnabled ? Theme.Colors.label2 : Theme.Colors.label3).setFill()
            dash.fill()
            (hovered && isEnabled ? Theme.Colors.label2 : Theme.Colors.fieldEdge).setStroke()
            p.lineWidth = 1
            p.stroke()
            return
        }
        if color.alphaComponent < 1 {
            let sq: CGFloat = 5
            for y in 0..<Int(ceil(r.height / sq)) { for x in 0..<Int(ceil(r.width / sq)) {
                (((x + y) % 2 == 0) ? Theme.Palette.checker.dark : Theme.Palette.checker.light).setFill()
                CGRect(x: CGFloat(x) * sq, y: CGFloat(y) * sq, width: sq, height: sq).fill()
            } }
        }
        color.withAlphaComponent(isEnabled ? color.alphaComponent : color.alphaComponent * Theme.State.disabledAlpha).setFill()
        r.fill()
        NSGraphicsContext.restoreGraphicsState()
        (hovered && isEnabled ? Theme.Colors.label2 : Theme.Colors.fieldEdge).setStroke()
        p.lineWidth = 1
        p.stroke()
    }

    public override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        onOpen?()
        if popover?.isShown == true { popover?.close(); return }
        open()
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func keyDown(with event: NSEvent) {
        if isEnabled, event.keyCode == 36 || event.keyCode == 49 { open() } else { super.keyDown(with: event) }
    }

    private func open() {
        let pk = SQColorPickerView(color: color, showsAlpha: showsAlpha)
        pk.onChange = { [weak self] c in
            guard let self else { return }
            self.fromPicker = true; self.color = c; self.fromPicker = false
            _ = self.sendAction(self.action, to: self.target)
        }
        picker = pk
        let pop = SQPopover(contentView: pk)
        // The loupe's clicks land outside the popover: keep it open while the eyedropper runs.
        pk.onEyedropperActive = { [weak pop] active in pop?.mode = active ? .applicationDefined : .transient }
        pop.onClose = { [weak self] in self?.picker?.commitRecent(); self?.picker = nil; self?.popover = nil; self?.onClose?() }
        popover = pop
        pop.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }
}
