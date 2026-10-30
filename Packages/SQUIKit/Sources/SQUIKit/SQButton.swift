import AppKit

/// Push button (design artifact v11, sq.css `.btn`): flat custom-drawn capsule, 22 high, padding 11,
/// fill `fill` (.11), hover `fillHover` (.16), pressed `fillPressed` (.22), 11 pt `label` text, no border, no shadow.
/// A drop-in NSButton subclass (target/action, keyEquivalent, `title`, `image` keep working), so it survives
/// macOS bezel changes. `style = .accent` is the one filled-blue variant (Export); `.icon` has no fill at rest.
open class SQButton: NSButton {
    public enum Style: Sendable { case standard, accent, icon }

    public var style: Style = .standard { didSet { needsDisplay = true; invalidateIntrinsicContentSize() } }
    /// Fixed height; the default is `Theme.Metrics.quietButton` (22, capsule).
    public var boxHeight: CGFloat = Theme.Metrics.quietButton { didSet { invalidateIntrinsicContentSize() } }
    /// Corner radius override (dialog buttons use 8, design B `.btn`); `nil` keeps the control radius.
    public var cornerRadius: CGFloat? { didSet { needsDisplay = true } }
    public var horizontalPadding: CGFloat = 11 { didSet { invalidateIntrinsicContentSize() } }
    /// Replaces the blue of the `.accent` style (the Support button uses `Colors.support`).
    public var accentFillOverride: NSColor? { didSet { needsDisplay = true } }
    var isHovered = false { didSet { if oldValue != isHovered { needsDisplay = true } } }
    private var hoverArea: NSTrackingArea?

    public convenience init(title: String, target: AnyObject?, action: Selector?, style: Style) {
        self.init(frame: .zero)
        self.title = SQL10n.string(title)
        self.target = target
        self.action = action
        self.style = style
    }
    // `SQButton(title:target:action:)` is NSButton's own convenience init and gives the `.standard` style.

    /// Icon-only button (`style = .icon`), symbol at the V1 Quiet weight.
    public convenience init(symbol: SQIcon, label: String, target: AnyObject?, action: Selector?, size: CGFloat = 13) {
        self.init(frame: .zero)
        self.title = ""
        self.image = Theme.symbol(symbol, size: size, label: label)
        self.imagePosition = .imageOnly
        self.target = target
        self.action = action
        self.style = .icon
        self.toolTip = label
        setAccessibilityLabel(label)
    }

    /// Every button tip is the SQ tooltip (`SQTooltip`), never the system one: `toolTip =` keeps working at all call sites.
    public override var toolTip: String? {
        get { sqToolTip }
        set { sqToolTip = newValue }
    }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        isBordered = false
        bezelStyle = .smallSquare
        setButtonType(.momentaryPushIn)
        font = Theme.Typography.body
        focusRingType = .none
    }

    // Writing these from existing call sites must not bring the system bezel back.
    open override var bezelStyle: NSButton.BezelStyle {
        get { super.bezelStyle }
        set { super.bezelStyle = .smallSquare }
    }
    open override var isBordered: Bool {
        get { super.isBordered }
        set { super.isBordered = false }
    }

    open override var title: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    open override var image: NSImage? { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    open override var isEnabled: Bool { didSet { needsDisplay = true } }
    open override var isHighlighted: Bool { didSet { needsDisplay = true } }
    open override var state: NSControl.StateValue { didSet { needsDisplay = true } }
    /// True after `setButtonType(.pushOnPushOff / .toggle / .onOff)`: the `.on` state draws pressed.
    private(set) var isToggle = false
    open override func setButtonType(_ type: NSButton.ButtonType) {
        super.setButtonType(type)
        isToggle = type == .pushOnPushOff || type == .toggle || type == .onOff
    }

    /// Title font (11 pt). NSButton's own convenience inits reset `font` to 13 pt, so the button keeps its own.
    public var quietFont: NSFont = Theme.Typography.body { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var textFont: NSFont { quietFont }

    open override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(contentWidth + horizontalPadding * 2), height: boxHeight)
    }

    var contentWidth: CGFloat {
        var w: CGFloat = 0
        if let image, imagePosition != .noImage { w += image.size.width }
        if !title.isEmpty, imagePosition != .imageOnly {
            if w > 0 { w += 5 }
            w += (title as NSString).size(withAttributes: [.font: textFont]).width
        }
        return w
    }

    /// Fits the custom-drawn box (the cell's own size would be the system control's).
    open override func sizeToFit() { setFrameSize(intrinsicContentSize) }

    open override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        hoverArea = a
    }
    open override func mouseEntered(with event: NSEvent) { isHovered = true }
    open override func mouseExited(with event: NSEvent) { isHovered = false }

    /// The box the control draws in (vertically centered, `boxHeight` high).
    var boxRect: NSRect {
        let h = min(boxHeight, bounds.height)
        return NSRect(x: 0, y: ((bounds.height - h) / 2).rounded(), width: bounds.width, height: h)
    }

    var fillColor: NSColor? {
        let pressed = isHighlighted || (isToggle && state == .on && style != .accent)
        switch style {
        case .accent:
            if let c = accentFillOverride {
                if isHighlighted { return c.blended(withFraction: 0.2, of: .black) ?? c }
                return isHovered && isEnabled ? (c.blended(withFraction: 0.15, of: .white) ?? c) : c
            }
            // The one primary button: `accf` at rest (sq.css `.btn.pri`), brighter `accent` on hover, darker pressed.
            if isHighlighted { return Theme.Colors.accentFill.blended(withFraction: 0.2, of: .black) ?? Theme.Colors.accentFill }
            return isHovered && isEnabled ? Theme.Colors.accent : Theme.Colors.accentFill
        case .standard:
            return pressed ? Theme.Colors.fillPressed : (isHovered && isEnabled ? Theme.Colors.fillHover : Theme.Colors.fill)
        case .icon:
            return nil   // States board: an icon button has no fill in any state (hover/pressed only change the glyph)
        }
    }

    var foreground: NSColor {
        if style == .accent { return isEnabled ? Theme.State.onAccent : Theme.State.onAccent.withAlphaComponent(Theme.State.disabledAlpha) }
        if let contentTintColor { return contentTintColor }
        return isEnabled ? Theme.Colors.label : Theme.Colors.label.withAlphaComponent(Theme.Colors.label.alphaComponent * Theme.State.disabledAlpha)
    }

    open override func draw(_ dirtyRect: NSRect) {
        let box = boxRect
        if let fill = fillColor {
            fill.withAlphaComponent(fill.alphaComponent * (isEnabled ? 1 : Theme.State.disabledAlpha)).setFill()
            let r = cornerRadius ?? ControlShape.radius(box)
            NSBezierPath(roundedRect: box, xRadius: r, yRadius: r).fill()
        }
        drawContent(in: box)
        if ControlShape.isFocused(self) { ControlShape.drawFocusLine(in: box, radius: cornerRadius ?? ControlShape.radius(box)) }
    }

    func drawContent(in box: NSRect) {
        let fg = foreground
        let showsTitle = !title.isEmpty && imagePosition != .imageOnly
        var x = box.midX - contentWidth / 2
        if let image, imagePosition != .noImage {
            let s = image.size
            let r = NSRect(x: x.rounded(), y: (box.midY - s.height / 2).rounded(), width: s.width, height: s.height)
            Self.tinted(image, fg).draw(in: r, from: .zero, operation: .sourceOver, fraction: 1,
                                        respectFlipped: true, hints: nil)
            x += s.width + 5
        }
        if showsTitle {
            let attrs: [NSAttributedString.Key: Any] = [.font: textFont, .foregroundColor: fg]
            let ts = (title as NSString).size(withAttributes: attrs)
            (title as NSString).draw(at: NSPoint(x: x.rounded(), y: (box.midY - ts.height / 2).rounded()),
                                     withAttributes: attrs)
        }
    }

    /// A template image drawn in `color` (symbols are templates; bitmaps draw unchanged).
    static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        guard image.isTemplate else { return image }
        let out = NSImage(size: image.size, flipped: false) { r in
            image.draw(in: r)
            color.set()
            r.fill(using: .sourceAtop)
            return true
        }
        return out
    }
}
