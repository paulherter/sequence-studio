import AppKit

/// Keyframe toggle (design B v7 `i-kf`): an outlined diamond with a center dot, drawn with NSBezierPath, not a symbol.
/// - Off (not animated): diamond stroke and dot `label3` (dim), hover `label2`.
/// - Animated (has keys): diamond stroke and dot `accent`.
/// - On a key (playhead on a keyframe): diamond filled `accent`, dot white.
/// The click goes to `onToggle` (the owner asks before deleting keys).
public final class KeyframeToggleView: NSControl {
    public var keyState: ScrubKeyframeState = .none {
        didSet { if oldValue != keyState { needsDisplay = true; updateAccessibility() } }
    }
    public var onToggle: (@MainActor () -> Void)?
    var onContextMenu: ((NSEvent) -> Void)?
    public override func rightMouseDown(with event: NSEvent) { onContextMenu?(event) }
    private var hovering = false { didSet { if oldValue != hovering { needsDisplay = true } } }
    private var hoverArea: NSTrackingArea?

    public static let slot: CGFloat = 14
    public static let circleDiameter: CGFloat = 10
    public static let diamondSize: CGFloat = 4

    public init(label: String, onToggle: (@MainActor () -> Void)? = nil) {
        self.onToggle = onToggle
        super.init(frame: .zero)
        sqToolTip = label
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(label)
        updateAccessibility()
    }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }
    public override var intrinsicContentSize: NSSize { NSSize(width: Self.slot, height: Self.slot) }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        hoverArea = a
    }
    public override func mouseEntered(with event: NSEvent) { hovering = true }
    public override func mouseExited(with event: NSEvent) { hovering = false }

    /// Scrolling under a resting pointer sends no mouseExited: re-read the pointer on every scroll step (`ScrollHoverSync`).
    private lazy var hoverSync = ScrollHoverSync(view: self) { [weak self] p in self?.hovering = p != nil }
    public override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); hoverSync.attach(); hoverSync.refresh() }
    public override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        onToggle?()
    }
    public override func accessibilityPerformPress() -> Bool { onToggle?(); return true }

    public override func draw(_ dirtyRect: NSRect) {
        Self.drawRing(keyState, hovering: hovering && isEnabled, centre: NSPoint(x: bounds.midX, y: bounds.midY))
    }

    /// Corner-to-corner size of the toggle diamond and the radius of its center dot (24 px icon scaled to the 14 px slot).
    public static let toggleDiamond: CGFloat = 10
    public static let dotRadius: CGFloat = 1.2

    /// The diamond at `center`; shared with the scrub field so both read the same.
    public static func drawRing(_ state: ScrubKeyframeState, hovering: Bool, centre c: NSPoint) {
        let diamond = diamondPath(centre: c, size: toggleDiamond)
        let r = dotRadius
        let dot = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        diamond.lineWidth = 1.2
        diamond.lineJoinStyle = .round
        switch state {
        case .none:
            let tint = hovering ? Theme.Colors.label2 : Theme.Colors.label3
            tint.setStroke(); diamond.stroke()
            tint.setFill(); dot.fill()
        case .between:
            Theme.Colors.accent.setStroke(); diamond.stroke()
            Theme.Colors.accent.setFill(); dot.fill()
        case .onKey:
            Theme.Colors.accent.setFill(); diamond.fill()
            Theme.Colors.accent.setStroke(); diamond.stroke()
            NSColor.white.setFill(); dot.fill()
        }
    }

    /// A diamond `size` pt wide (corner to corner) at `center`; also used by the key button of the rows.
    public static func diamondPath(centre c: NSPoint, size: CGFloat) -> NSBezierPath {
        let h = size / 2
        let p = NSBezierPath()
        p.move(to: NSPoint(x: c.x, y: c.y - h)); p.line(to: NSPoint(x: c.x + h, y: c.y))
        p.line(to: NSPoint(x: c.x, y: c.y + h)); p.line(to: NSPoint(x: c.x - h, y: c.y)); p.close()
        return p
    }

    /// The diamond with its center dot as a template image (key button of the rows): filled with the dot cut out on a
    /// key, outlined with a dot otherwise.
    public static func diamondImage(filled: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
            let c = NSPoint(x: r.midX, y: r.midY)
            let p = diamondPath(centre: c, size: 9)
            p.lineWidth = 1.1
            p.lineJoinStyle = .round
            let d: CGFloat = 1.1
            let dot = NSBezierPath(ovalIn: NSRect(x: c.x - d, y: c.y - d, width: d * 2, height: d * 2))
            NSColor.black.set()
            if filled {
                p.fill(); p.stroke()
                NSGraphicsContext.current?.compositingOperation = .clear
                dot.fill()
            } else {
                p.stroke(); dot.fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    private func updateAccessibility() {
        setAccessibilityValue(keyState == .none ? 0 : 1)
    }
}
