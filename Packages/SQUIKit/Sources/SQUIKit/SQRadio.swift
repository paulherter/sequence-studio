import AppKit

/// Pure keyboard logic of a radio group (arrows move the selection inside the group, skipping disabled radios, wrapping).
public enum SQRadioLogic {
    public enum Direction: Sendable { case previous, next }

    /// Index to select after an arrow key, or nil when no radio is enabled. `enabled[i]` = radio i accepts input.
    public static func step(from index: Int?, direction: Direction, enabled: [Bool]) -> Int? {
        let n = enabled.count
        guard n > 0, enabled.contains(true) else { return nil }
        let delta = direction == .next ? 1 : -1
        var i = index ?? (direction == .next ? -1 : n)
        for _ in 0..<n {
            i = ((i + delta) % n + n) % n
            if enabled[i] { return i }
        }
        return nil
    }
}

/// Keeps exactly one radio of a set selected. Holds its radios weakly.
@MainActor
public final class SQRadioGroup {
    private struct Weak { weak var radio: SQRadio? }
    private var members: [Weak] = []
    public var onChange: (@MainActor (Int?) -> Void)?

    public init() {}

    public var radios: [SQRadio] { members.compactMap(\.radio) }
    public var selectedIndex: Int? { radios.firstIndex { $0.isSelected } }

    public func add(_ radio: SQRadio) {
        members.removeAll { $0.radio == nil || $0.radio === radio }
        members.append(Weak(radio: radio))
        radio.group = self
    }

    /// Selects `index` and clears the others; nil clears all.
    public func select(_ index: Int?, notify: Bool = true) {
        let all = radios
        for (i, r) in all.enumerated() { r.setSelected(i == index) }
        if notify { onChange?(index) }
    }

    func radioPressed(_ radio: SQRadio) {
        guard let i = radios.firstIndex(where: { $0 === radio }) else { return }
        select(i)
    }

    func move(from radio: SQRadio, _ direction: SQRadioLogic.Direction) {
        let all = radios
        let from = all.firstIndex { $0 === radio }
        guard let to = SQRadioLogic.step(from: from, direction: direction, enabled: all.map(\.isEnabled)) else { return }
        select(to)
        all[to].window?.makeFirstResponder(all[to])
    }

    /// Builds a group from titles, one radio each, `selected` pre-selected.
    public static func make(titles: [String], selected: Int? = nil, onChange: (@MainActor (Int?) -> Void)? = nil) -> (SQRadioGroup, [SQRadio]) {
        let g = SQRadioGroup()
        let rs = titles.map { SQRadio(title: $0) }
        rs.forEach(g.add)
        g.select(selected, notify: false)
        g.onChange = onChange
        return (g, rs)
    }
}

/// Radio: 14 pt ring + 6 pt dot (sq.css `.chk.rad`). Off: fill + 0.5 edge. On: fill + 1.5 accent ring + accent dot.
/// Hover and pressed lighten the box; disabled draws at `disabledAlpha`; keyboard focus draws the focus ring.
/// Space selects, arrows move inside the group.
open class SQRadio: NSControl {
    public static let boxSize: CGFloat = 14
    public static let dotSize: CGFloat = 6
    public static let labelGap: CGFloat = 6

    public var title: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    public private(set) var isSelected = false { didSet { if oldValue != isSelected { needsDisplay = true } } }
    public weak var group: SQRadioGroup?
    public var onSelect: (@MainActor () -> Void)?

    open override var isEnabled: Bool { didSet { needsDisplay = true } }
    private(set) var isHovered = false { didSet { needsDisplay = true } }
    private(set) var isPressed = false { didSet { needsDisplay = true } }
    var isFocused = false { didSet { needsDisplay = true } }
    private var hoverArea: NSTrackingArea?

    public init(title: String = "") {
        self.title = title
        super.init(frame: .zero)
        setAccessibilityRole(.radioButton)
    }
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setSelected(_ on: Bool) { isSelected = on }

    /// Selects this radio (through its group when it has one).
    public func select() {
        guard isEnabled, !isSelected else { return }
        if let group { group.radioPressed(self) } else { isSelected = true }
        onSelect?()
        sendAction(action, to: target)
    }

    // MARK: Layout

    open override var intrinsicContentSize: NSSize {
        let b = Self.boxSize
        guard !title.isEmpty else { return NSSize(width: b, height: b) }
        let w = (title as NSString).size(withAttributes: [.font: Theme.Typography.body]).width
        return NSSize(width: ceil(b + Self.labelGap + w), height: max(b, Theme.Row.control))
    }
    open override func sizeToFit() { setFrameSize(intrinsicContentSize) }

    var boxRect: NSRect {
        let b = Self.boxSize
        return NSRect(x: 0, y: ((bounds.height - b) / 2).rounded(), width: b, height: b)
    }

    // MARK: Drawing

    /// Box fill per state (pure for tests): rest `fill`, hover `fillHover`, pressed `fillPressed`.
    static func boxFill(hovered: Bool, pressed: Bool) -> NSColor {
        pressed ? Theme.State.pressed : hovered ? Theme.State.controlHover : Theme.State.controlRest
    }

    open override func draw(_ dirtyRect: NSRect) {
        let alpha: CGFloat = isEnabled ? 1 : Theme.State.disabledAlpha
        let box = boxRect
        let fill = Self.boxFill(hovered: isHovered && isEnabled, pressed: isPressed && isEnabled)
        fill.withAlphaComponent(fill.alphaComponent * alpha).setFill()
        NSBezierPath(ovalIn: box).fill()
        if isSelected {
            Theme.Colors.accent.withAlphaComponent(alpha).setStroke()
            let ring = NSBezierPath(ovalIn: box.insetBy(dx: 0.75, dy: 0.75))
            ring.lineWidth = 1.5
            ring.stroke()
            Theme.Colors.accent.withAlphaComponent(alpha).setFill()
            let d = Self.dotSize
            NSBezierPath(ovalIn: NSRect(x: box.midX - d / 2, y: box.midY - d / 2, width: d, height: d)).fill()
        } else {
            Theme.Colors.fieldEdge.withAlphaComponent(Theme.Colors.fieldEdge.alphaComponent * alpha).setStroke()
            let ring = NSBezierPath(ovalIn: box.insetBy(dx: 0.25, dy: 0.25))
            ring.lineWidth = 0.5
            ring.stroke()
        }
        if isFocused || ControlShape.forcedFocus {
            // Board `.foc`: the inner 1.5 px accent line, like every other control (no outer halo).
            Theme.State.focusLine.setStroke()
            let w = Theme.State.focusLineWidth
            let r = NSBezierPath(ovalIn: box.insetBy(dx: w / 2, dy: w / 2))
            r.lineWidth = w
            r.stroke()
        }
        guard !title.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Theme.Typography.body,
            .foregroundColor: isEnabled ? Theme.Colors.label : Theme.State.disabledText,
        ]
        let ts = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: NSPoint(x: Self.boxSize + Self.labelGap, y: ((bounds.height - ts.height) / 2).rounded()),
                                 withAttributes: attrs)
    }

    // MARK: Mouse

    open override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(a)
        hoverArea = a
    }
    open override func mouseEntered(with event: NSEvent) { isHovered = true }
    open override func mouseExited(with event: NSEvent) { isHovered = false }
    open override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        var inside = true
        while let e = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            inside = bounds.contains(convert(e.locationInWindow, from: nil))
            isPressed = inside
            if e.type == .leftMouseUp { break }
        }
        isPressed = false
        if inside { select() }
    }

    // MARK: Keyboard

    open override var acceptsFirstResponder: Bool { isEnabled }
    open override func becomeFirstResponder() -> Bool { isFocused = true; return super.becomeFirstResponder() }
    open override func resignFirstResponder() -> Bool { isFocused = false; return super.resignFirstResponder() }
    open override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: select()                                   // space
        case 123, 126: group?.move(from: self, .previous)   // left, up
        case 124, 125: group?.move(from: self, .next)       // right, down
        default: super.keyDown(with: event)
        }
    }

    open override func isAccessibilityElement() -> Bool { true }
    open override func accessibilityLabel() -> String? { title }
    open override func accessibilityValue() -> Any? { isSelected ? 1 : 0 }
    open override func accessibilityPerformPress() -> Bool { select(); return true }
}
