import AppKit
import simd
import SSCore
import SSRender

/// Lumetri-style slider: thin track with a gap around a round knob. Click jumps, drag follows, double-click resets.
/// Temperature and Tint get a coloured track. One drag = `onBegin` -> `onChange`* -> `onEnd` (one undo step).
@MainActor
final class LumetriSlider: NSControl {
    var minValue = 0.0, maxValue = 1.0, neutral = 0.0
    var step = 0.1
    var value = 0.0 { didSet { if value != oldValue { needsDisplay = true } } }
    var track: ColorParam.Track = .plain { didSet { needsDisplay = true } }
    override var isEnabled: Bool { didSet { needsDisplay = true } }

    var onBegin: (() -> Void)?
    var onChange: ((Double) -> Void)?
    var onEnd: (() -> Void)?
    var onReset: (() -> Void)?

    private static let knob: CGFloat = 11
    private static let inset: CGFloat = 6
    private var dragging = false
    private var dragOffset: CGFloat = 0

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 18) }
    override var acceptsFirstResponder: Bool { isEnabled }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.slider)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func knobX(_ v: Double) -> CGFloat {
        let span = max(maxValue - minValue, .leastNonzeroMagnitude)
        return Self.inset + CGFloat((v - minValue) / span) * max(bounds.width - 2 * Self.inset, 1)
    }

    func value(atX x: CGFloat) -> Double {
        let t = Double((x - Self.inset) / max(bounds.width - 2 * Self.inset, 1))
        let v = minValue + min(max(t, 0), 1) * (maxValue - minValue)
        return min(max((v / step).rounded() * step, minValue), maxValue)
    }

    // MARK: Drawing

    private var gradient: NSGradient {
        switch track {
        case .plain:
            let c = Theme.white(0.30)
            return NSGradient(starting: c, ending: c) ?? NSGradient(colors: [c])!
        case .temperature:
            return NSGradient(colors: [Theme.hex(0x2F7BE8), Theme.white(0.40), Theme.hex(0xE8901E)],
                              atLocations: [0, 0.5, 1], colorSpace: .sRGB) ?? NSGradient(colors: [Theme.white(0.3)])!
        case .tint:
            return NSGradient(colors: [Theme.hex(0x22D63A), Theme.white(0.40), Theme.hex(0xE61FD8)],
                              atLocations: [0, 0.5, 1], colorSpace: .sRGB) ?? NSGradient(colors: [Theme.white(0.3)])!
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let y = bounds.midY
        let kx = knobX(value)
        let gap = Self.knob / 2 + 3
        let x0 = Self.inset - 4, x1 = bounds.width - Self.inset + 4
        NSGraphicsContext.saveGraphicsState()
        let clip = NSBezierPath()
        clip.appendRect(NSRect(x: x0, y: y - 1, width: max(kx - gap - x0, 0), height: 2))
        clip.appendRect(NSRect(x: kx + gap, y: y - 1, width: max(x1 - kx - gap, 0), height: 2))
        clip.addClip()
        gradient.draw(in: NSRect(x: x0, y: y - 1, width: x1 - x0, height: 2), angle: 0)
        NSGraphicsContext.restoreGraphicsState()

        let r = NSRect(x: kx - Self.knob / 2, y: y - Self.knob / 2, width: Self.knob, height: Self.knob).insetBy(dx: 1, dy: 1)
        let ring = NSBezierPath(ovalIn: r)
        Theme.Colors.panel.setFill()
        ring.fill()
        (isEnabled ? Theme.white(0.72) : Theme.white(0.30)).setStroke()
        ring.lineWidth = 2
        ring.stroke()
        if window?.firstResponder === self, isEnabled {
            Theme.Colors.accentRing.setStroke()
            let f = NSBezierPath(ovalIn: r.insetBy(dx: -2.5, dy: -2.5))
            f.lineWidth = 1.5
            f.stroke()
        }
    }

    // MARK: Mouse and keyboard

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        if event.clickCount == 2 { onReset?(); return }
        let x = convert(event.locationInWindow, from: nil).x
        let kx = knobX(value)
        dragOffset = abs(x - kx) <= Self.knob / 2 + 2 ? x - kx : 0   // grab the knob where it is, else jump there
        dragging = true
        onBegin?()
        update(event)
    }

    override func mouseDragged(with event: NSEvent) { if dragging { update(event) } }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        onEnd?()
    }

    private func update(_ event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x - dragOffset
        let v = value(atX: x)
        if v != value { value = v; onChange?(v) }
    }

    private func nudge(_ delta: Double) {
        let v = min(max(((value + delta) / step).rounded() * step, minValue), maxValue)
        guard v != value else { return }
        value = v
        onBegin?(); onChange?(v); onEnd?()
    }

    override func keyDown(with event: NSEvent) {
        let big = (maxValue - minValue) / 20
        switch event.keyCode {
        case 123, 125: nudge(-(event.modifierFlags.contains(.shift) ? big : step))
        case 124, 126: nudge(event.modifierFlags.contains(.shift) ? big : step)
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityValue() -> Any? { value }
    override func accessibilityMinValue() -> Any? { minValue }
    override func accessibilityMaxValue() -> Any? { maxValue }
    override func accessibilityPerformIncrement() -> Bool { nudge((maxValue - minValue) / 20); return true }
    override func accessibilityPerformDecrement() -> Bool { nudge(-(maxValue - minValue) / 20); return true }
}

/// One Lumetri row: title, slider, right-aligned value in the accent colour (type to edit, Return commits).
@MainActor
final class ColorParamRow: NSStackView {
    let param: ColorParam?
    let slider = LumetriSlider()
    let field = NSTextField(string: "")
    private let decimals: Int
    private let neutral: Float
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?
    /// A value the user chose (slider drag or typed).
    var onSet: ((Float) -> Void)?
    var onReset: (() -> Void)?

    static let titleWidth: CGFloat = 96

    /// `param == nil` = a disabled placeholder row (feature not built yet).
    init(_ p: ColorParam?, title: String? = nil, range: ClosedRange<Float>? = nil, neutral: Float = 0, decimals: Int = 1) {
        param = p
        self.decimals = p?.decimals ?? decimals
        self.neutral = p?.neutral ?? neutral
        let r = p?.range ?? range ?? 0...100
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: title ?? p?.title ?? "")
        label.font = Theme.Fonts.small
        label.textColor = Theme.Colors.label2
        label.lineBreakMode = .byTruncatingTail
        label.widthAnchor.constraint(equalToConstant: Self.titleWidth).isActive = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        slider.minValue = Double(r.lowerBound); slider.maxValue = Double(r.upperBound)
        slider.neutral = Double(self.neutral); slider.value = Double(self.neutral)
        slider.step = 1 / pow(10, Double(self.decimals))
        slider.track = p?.track ?? .plain
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.setAccessibilityLabel(label.stringValue)
        slider.onBegin = { [weak self] in self?.onBegin?() }
        slider.onEnd = { [weak self] in self?.onEnd?() }
        slider.onChange = { [weak self] v in self?.onSet?(Float(v)) }
        slider.onReset = { [weak self] in self?.onReset?() }

        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Theme.Fonts.small
        field.textColor = Theme.Colors.accent
        field.alignment = .right
        field.target = self
        field.action = #selector(fieldEntered)
        field.widthAnchor.constraint(equalToConstant: 48).isActive = true
        field.setAccessibilityLabel(label.stringValue + " value")

        setViews([label, slider, field], in: .leading)
        orientation = .horizontal
        alignment = .centerY
        spacing = Theme.Spacing.sm
        heightAnchor.constraint(equalToConstant: 22).isActive = true
        show(self.neutral)
        if p == nil { setActive(false) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func fieldEntered() {
        let text = field.stringValue.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        guard let v = Float(text) else { show(Float(slider.value)); return }
        onBegin?()
        onSet?(v)
        onEnd?()
    }

    func show(_ v: Float) {
        if slider.value != Double(v) { slider.value = Double(v) }
        if field.currentEditor() == nil { field.stringValue = String(format: "%.\(decimals)f", v) }
    }

    /// Placeholder and intensity-without-LUT rows are dimmed and cannot be edited.
    func setActive(_ on: Bool) {
        slider.isEnabled = on
        field.isEditable = on
        field.isSelectable = on
        alphaValue = on ? 1 : 0.4
    }
}

/// Collapsible header: chevron + title, optional switch on the right (sections) or none (sub-groups).
@MainActor
final class ColorSectionHeader: NSStackView {
    let chevron = NSImageView()
    let title: NSTextField
    let toggle = NSSwitch()
    var onToggleOpen: (() -> Void)?
    private let hasSwitch: Bool

    init(title text: String, isGroup: Bool) {
        hasSwitch = !isGroup
        title = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        chevron.contentTintColor = Theme.Colors.label2
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.widthAnchor.constraint(equalToConstant: 12).isActive = true
        title.font = isGroup ? Theme.Fonts.small : Theme.Fonts.bodyTitle
        title.textColor = isGroup ? Theme.Colors.label2 : Theme.Colors.label
        var views: [NSView] = [chevron, title, NSView()]
        if hasSwitch {
            toggle.controlSize = .small
            toggle.setAccessibilityLabel("Enable \(text)")
            views.append(toggle)
        }
        setViews(views, in: .leading)
        orientation = .horizontal
        alignment = .centerY
        spacing = Theme.Spacing.sm
        edgeInsets = NSEdgeInsets(top: 0, left: Theme.Spacing.md, bottom: 0, right: Theme.Spacing.md)
        heightAnchor.constraint(equalToConstant: isGroup ? 24 : 34).isActive = true
        setAccessibilityRole(.button)
        setAccessibilityLabel(text)
        setOpen(true)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func setOpen(_ open: Bool) {
        chevron.image = NSImage(systemSymbolName: open ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        setAccessibilityValue(open ? "expanded" : "collapsed")
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if bounds.contains(p) && !(hasSwitch && toggle.frame.contains(p)) { onToggleOpen?() }
    }

    override func accessibilityPerformPress() -> Bool { onToggleOpen?(); return true }
}

/// Group of rows under a sub-header ("Color", "Light", "Adjustments").
@MainActor
final class ColorGroupView: NSStackView {
    let header: ColorSectionHeader
    let content = NSStackView()

    init(title: String) {
        header = ColorSectionHeader(title: title, isGroup: true)
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = Theme.Spacing.xxs
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = Theme.Spacing.xxs
        content.edgeInsets = NSEdgeInsets(top: 0, left: Theme.Spacing.lg, bottom: Theme.Spacing.xs, right: 0)
        addArrangedSubview(header)
        addArrangedSubview(content)
        header.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        content.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func setOpen(_ open: Bool) {
        header.setOpen(open)
        content.isHidden = !open
    }
}

/// LUT popup of one effect (Input LUT or Creative look). `picks` mirrors the menu items.
@MainActor
final class LUTPopup: NSPopUpButton {
    enum Pick { case choice(ColorInspectorModel.LUTChoice?), chooseFile }
    var effect = 0
    var slot = ColorLUTSlot.input
    var picks: [Pick] = []
}

/// The four curve channel dots (white = master, red, green, blue) of Premiere's RGB Curves.
@MainActor
final class ChannelDots: NSControl {
    var selected = 0 { didSet { if selected != oldValue { needsDisplay = true } } }
    var onSelect: ((Int) -> Void)?
    private static let colors: [NSColor] = [Theme.white(0.92), Theme.hex(0x8A0F0F), Theme.hex(0x0F7A1A), Theme.hex(0x0A1FA8)]
    private static let names = ["Master", "Red", "Green", "Blue"]
    private static let d: CGFloat = 18, gap: CGFloat = 14

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 4 * Self.d + 3 * Self.gap + 8, height: 26) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel("Curve channel")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func rect(_ i: Int) -> NSRect {
        let total = 4 * Self.d + 3 * Self.gap
        let x0 = (bounds.width - total) / 2
        return NSRect(x: x0 + CGFloat(i) * (Self.d + Self.gap), y: (bounds.height - Self.d) / 2, width: Self.d, height: Self.d)
    }

    override func draw(_ dirtyRect: NSRect) {
        for i in 0..<4 {
            let r = rect(i)
            Self.colors[i].setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 2, dy: 2)).fill()
            if i == selected {
                Theme.Colors.accent.setStroke()
                let ring = NSBezierPath(ovalIn: r.insetBy(dx: 0.75, dy: 0.75))
                ring.lineWidth = 1.5
                ring.stroke()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = (0..<4).first(where: { rect($0).insetBy(dx: -Self.gap / 2, dy: -4).contains(p) }) {
            selected = i
            onSelect?(i)
        }
    }

    override func accessibilityValue() -> Any? { Self.names[selected] }
}

/// Look thumbnail with previous / next arrows (Premiere's Creative look preview).
@MainActor
final class LookPreviewView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var onStep: ((Int) -> Void)?
    private let prev = NSButton(), next = NSButton()

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 200, height: 112) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for (b, name, label, dir) in [(prev, "chevron.left", "Previous look", -1), (next, "chevron.right", "Next look", 1)] {
            b.image = NSImage(systemSymbolName: name, accessibilityDescription: label)
            b.isBordered = false
            b.imagePosition = .imageOnly
            b.contentTintColor = .white
            b.wantsLayer = true
            b.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
            b.tag = dir
            b.target = self
            b.action = #selector(step(_:))
            b.toolTip = label
            b.translatesAutoresizingMaskIntoConstraints = false
            addSubview(b)
            b.widthAnchor.constraint(equalToConstant: 22).isActive = true
            b.heightAnchor.constraint(equalToConstant: 38).isActive = true
            b.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        }
        prev.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
        next.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
        setAccessibilityLabel("Look preview")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func step(_ b: NSButton) { onStep?(b.tag) }

    func setStepping(_ on: Bool) { prev.isHidden = !on; next.isHidden = !on }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3)
        Theme.Colors.field.setFill()
        path.fill()
        guard let image else { return }
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Thumbnail of a look: a synthetic test picture (hue sweep, skin-ish patches, grey ramp) run through the look LUT.
/// A real clip frame would need the source frame at the playhead; this keeps the preview cheap and stable.
@MainActor
enum ColorLookPreview {
    private static var cache: [String: NSImage] = [:]

    static func image(forLookPath path: String?) -> NSImage {
        let key = path ?? ""
        if let hit = cache[key] { return hit }
        var lut: CubeLUT?
        if let path, let text = try? String(contentsOfFile: path, encoding: .utf8) { lut = try? CubeLUT.parse(text) }
        let img = render(lut: lut)
        if cache.count > 64 { cache.removeAll() }
        cache[key] = img
        return img
    }

    static func render(lut: CubeLUT?, width: Int = 100, height: Int = 56) -> NSImage {
        let pipe = lut.map { ColorPipeline(source: .rec709, ops: [.conversion(nil), .look($0, intensity: 1)]) }
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let u = Float(x) / Float(width - 1), v = Float(y) / Float(height - 1)
                var rgb: SIMD3<Float>
                if v < 0.55 {                        // hue sweep, fading to the top
                    rgb = hsv(h: u, s: 0.55 + 0.35 * (1 - v / 0.55), v: 0.35 + 0.6 * (v / 0.55))
                } else if v < 0.8 {                  // skin-ish and foliage patches
                    let patches: [SIMD3<Float>] = [[0.82, 0.62, 0.50], [0.62, 0.42, 0.32], [0.30, 0.46, 0.22], [0.25, 0.36, 0.62], [0.9, 0.85, 0.78]]
                    rgb = patches[min(Int(u * Float(patches.count)), patches.count - 1)]
                } else {                             // grey ramp
                    rgb = SIMD3(repeating: u)
                }
                if let pipe { rgb = TransferFunctions.bt709OETF(simd_clamp(pipe.process(rgb), .zero, SIMD3(repeating: 1))) }
                let i = (y * width + x) * 4
                bytes[i] = UInt8(min(max(rgb.x, 0), 1) * 255 + 0.5)
                bytes[i + 1] = UInt8(min(max(rgb.y, 0), 1) * 255 + 0.5)
                bytes[i + 2] = UInt8(min(max(rgb.z, 0), 1) * 255 + 0.5)
            }
        }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: cs,
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                         decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        return NSImage(cgImage: cg, size: NSSize(width: width, height: height))
    }

    private static func hsv(h: Float, s: Float, v: Float) -> SIMD3<Float> {
        let k = SIMD3<Float>(1, 2.0 / 3, 1.0 / 3)
        let p = SIMD3<Float>((abs((h + k.x).truncatingRemainder(dividingBy: 1) * 6 - 3)),
                             (abs((h + k.y).truncatingRemainder(dividingBy: 1) * 6 - 3)),
                             (abs((h + k.z).truncatingRemainder(dividingBy: 1) * 6 - 3)))
        return v * (SIMD3(repeating: 1 - s) + s * simd_clamp(p - SIMD3(repeating: 1), .zero, SIMD3(repeating: 1)))
    }
}
