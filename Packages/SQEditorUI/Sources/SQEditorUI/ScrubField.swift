import AppKit
import CoreGraphics

/// Keyframe state shown by the animate diamond (DESIGN.md: animate diamond toggle).
public enum ScrubKeyframeState: Sendable, Equatable {
    case none       // property not animated: hollow diamond
    case onKey      // playhead on a keyframe: filled accent diamond
    case between    // animated, playhead between keys: accent outline diamond
}

/// Scrubbable numeric value: accent text, drag horizontally to change, click to type.
///
/// One gesture = one `onBegin` ... `onChange`* ... `onEnd` triple, so callers make exactly one undo step.
/// Drag: pixels * `step`, Shift x10, Option or Command x0.1 (fine); the pointer is hidden and locked while dragging.
/// Click (no drag): inline NSTextField; Enter commits, Esc cancels, Up/Down step. Left/Right/Up/Down step
/// when the field itself has focus.
public final class ScrubField: NSControl, NSTextFieldDelegate {
    // MARK: Configuration
    public var value: Double = 0 {
        didSet { if !isDragging { needsDisplay = true } }
    }
    public var range: ClosedRange<Double> = -Double.greatestFiniteMagnitude...Double.greatestFiniteMagnitude
    /// Value change per dragged pixel (before modifiers).
    public var step: Double = 1
    public var unit: String = "" { didSet { needsDisplay = true } }
    public var decimals: Int = 0 { didSet { needsDisplay = true } }
    /// Overrides the default number+unit formatting (e.g. timecode).
    public var valueFormatter: (@MainActor (Double) -> String)?
    /// Overrides the default text parsing; return nil to reject.
    public var valueParser: (@MainActor (String) -> Double?)?

    // MARK: Callbacks
    public var onBegin: (@MainActor () -> Void)?
    public var onChange: (@MainActor (Double) -> Void)?
    public var onEnd: (@MainActor (Double) -> Void)?

    // MARK: Keyframe diamond
    /// nil hides the diamond.
    public var keyframeState: ScrubKeyframeState? { didSet { needsDisplay = true; needsLayout = true } }
    public var onKeyframeToggle: (@MainActor () -> Void)?

    // MARK: State
    public private(set) var isDragging = false
    public private(set) var isEditing = false
    private var editor: NSTextField?
    private var pressStart: NSPoint = .zero
    private var dragStartValue = 0.0
    private var accumulatedDX = 0.0
    private var pressed = false
    private var pressedOnDiamond = false
    private var hovering = false
    private var tracking: NSTrackingArea?
    private var cursorHidden = false
    private static let dragThreshold: CGFloat = 3
    private static let diamondWidth: CGFloat = 18

    public override var acceptsFirstResponder: Bool { true }
    public override var isFlipped: Bool { true }
    public override var intrinsicContentSize: NSSize {
        NSSize(width: 64 + (keyframeState == nil ? 0 : Self.diamondWidth), height: Theme.Metrics.controlHeight)
    }

    public override init(frame: NSRect) { super.init(frame: frame); setup() }
    public required init?(coder: NSCoder) { super.init(coder: coder); setup() }
    private func setup() {
        focusRingType = .none
        setAccessibilityRole(.incrementor)
    }

    deinit { MainActor.assumeIsolated { restorePointer() } }

    // MARK: Text
    public var displayText: String {
        if let valueFormatter { return valueFormatter(value) }
        return ScrubMath.format(value, decimals: decimals, unit: unit)
    }

    private func parse(_ text: String) -> Double? {
        if let valueParser { return valueParser(text) }
        return ScrubMath.parse(text, unit: unit)
    }

    // MARK: Geometry
    private var diamondRect: NSRect {
        guard keyframeState != nil else { return .zero }
        return NSRect(x: bounds.maxX - Self.diamondWidth, y: 0, width: Self.diamondWidth, height: bounds.height)
    }
    private var textRect: NSRect {
        var r = bounds
        if keyframeState != nil { r.size.width -= Self.diamondWidth }
        return r
    }

    // MARK: Drawing
    public override func draw(_ dirtyRect: NSRect) {
        let body = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: Theme.Radius.field, yRadius: Theme.Radius.field)
        Theme.Colors.field.setFill(); body.fill()
        let focused = window?.firstResponder === self || isEditing
        (focused ? Theme.Colors.accentRing : (hovering ? Theme.Colors.fillPressed : Theme.Colors.fieldEdge)).setStroke()
        body.lineWidth = focused ? 2 : 1
        body.stroke()

        if !isEditing {
            let para = NSMutableParagraphStyle(); para.alignment = .center; para.lineBreakMode = .byTruncatingTail
            let attrs: [NSAttributedString.Key: Any] = [
                .font: Theme.Fonts.small, .foregroundColor: Theme.Colors.accent, .paragraphStyle: para]
            let s = displayText as NSString
            let h = s.size(withAttributes: attrs).height
            s.draw(in: NSRect(x: textRect.minX + 4, y: textRect.midY - h / 2, width: textRect.width - 8, height: h),
                   withAttributes: attrs)
        }
        if let state = keyframeState { drawDiamond(state, in: diamondRect) }
    }

    private func drawDiamond(_ state: ScrubKeyframeState, in r: NSRect) {
        let c = NSPoint(x: r.midX, y: r.midY), h: CGFloat = 4.5
        let p = NSBezierPath()
        p.move(to: NSPoint(x: c.x, y: c.y - h)); p.line(to: NSPoint(x: c.x + h, y: c.y))
        p.line(to: NSPoint(x: c.x, y: c.y + h)); p.line(to: NSPoint(x: c.x - h, y: c.y)); p.close()
        switch state {
        case .none:
            Theme.Colors.label3.setStroke(); p.lineWidth = 1; p.stroke()
        case .between:
            Theme.Colors.accent.setStroke(); p.lineWidth = 1.25; p.stroke()
        case .onKey:
            Theme.Colors.accent.setFill(); p.fill()
        }
    }

    // MARK: Accessibility
    public override func accessibilityValue() -> Any? { displayText }
    public override func accessibilityPerformIncrement() -> Bool { stepByKey(+1, shift: false, option: false); return true }
    public override func accessibilityPerformDecrement() -> Bool { stepByKey(-1, shift: false, option: false); return true }

    // MARK: Tracking
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    public override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    public override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    public override func resetCursorRects() {
        addCursorRect(textRect, cursor: .resizeLeftRight)
        if keyframeState != nil { addCursorRect(diamondRect, cursor: .arrow) }
    }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Mouse: drag to scrub, click to edit
    public override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if isEditing { commitEditing(); return }
        let p = convert(event.locationInWindow, from: nil)
        pressStart = p
        pressed = true
        pressedOnDiamond = keyframeState != nil && diamondRect.contains(p)
        dragStartValue = value
        accumulatedDX = 0
        window?.makeFirstResponder(self)
    }

    public override func mouseDragged(with event: NSEvent) {
        guard pressed, !pressedOnDiamond else { return }
        if !isDragging {
            let p = convert(event.locationInWindow, from: nil)
            guard abs(p.x - pressStart.x) >= Self.dragThreshold else { return }
            beginDrag()
            accumulatedDX = 0
        }
        // Raw deltas keep coming while the pointer is locked.
        accumulatedDX += Double(event.deltaX)
        let mods = event.modifierFlags
        let v = ScrubMath.value(start: dragStartValue, deltaPixels: accumulatedDX, step: step,
                                shift: mods.contains(.shift), option: mods.contains(.option) || mods.contains(.command), range: range)
        apply(v)
    }

    public override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        if pressedOnDiamond {
            if diamondRect.contains(convert(event.locationInWindow, from: nil)) { onKeyframeToggle?() }
            pressedOnDiamond = false
            return
        }
        if isDragging { endDrag() } else { beginEditing() }
    }

    private func beginDrag() {
        isDragging = true
        onBegin?()
        NSCursor.hide(); cursorHidden = true
        CGAssociateMouseAndMouseCursorPosition(0)
    }

    private func endDrag() {
        restorePointer()
        isDragging = false
        needsDisplay = true
        onEnd?(value)
    }

    /// Always safe to call: re-associates the mouse and unhides the cursor exactly once.
    private func restorePointer() {
        CGAssociateMouseAndMouseCursorPosition(1)
        if cursorHidden { NSCursor.unhide(); cursorHidden = false }
    }

    private func apply(_ v: Double) {
        guard v != value else { return }
        value = v
        needsDisplay = true
        onChange?(v)
        sendAction(action, to: target)
    }

    // MARK: Keys
    public override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags
        switch event.keyCode {
        case 123, 125: stepByKey(-1, shift: mods.contains(.shift), option: mods.contains(.option) || mods.contains(.command))   // left, down
        case 124, 126: stepByKey(+1, shift: mods.contains(.shift), option: mods.contains(.option) || mods.contains(.command))   // right, up
        case 48: focusNeighbour(forward: !mods.contains(.shift))                                       // tab
        case 36, 76: beginEditing()                                                                   // return, enter
        default: super.keyDown(with: event)
        }
    }

    /// One arrow-key step is its own begin/changed/ended triple (one undo step).
    private func stepByKey(_ dir: Int, shift: Bool, option: Bool) {
        let v = ScrubMath.stepped(value, direction: dir, step: step, shift: shift, option: option, range: range)
        guard v != value else { return }
        onBegin?()
        apply(v)
        onEnd?(value)
    }

    public override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    public override func resignFirstResponder() -> Bool {
        if isDragging { endDrag() }
        needsDisplay = true
        return true
    }
    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        if isDragging { endDrag() }
        super.viewWillMove(toWindow: newWindow)
    }

    // MARK: Tab order

    /// The next (or previous) visible field in reading order among the fields that share this one's scroll view or window.
    public static func neighbour(of field: ScrubField, in fields: [ScrubField], forward: Bool) -> ScrubField? {
        func origin(_ f: ScrubField) -> (CGFloat, CGFloat) {
            let r = f.convert(f.bounds, to: nil)
            return (-r.maxY.rounded(), r.minX)          // window y points up: top rows first
        }
        let ordered = fields.filter { !$0.isHiddenOrHasHiddenAncestor }.sorted { a, b in
            let (ay, ax) = origin(a), (by, bx) = origin(b)
            return ay != by ? ay < by : ax < bx
        }
        guard let i = ordered.firstIndex(where: { $0 === field }), ordered.count > 1 else { return nil }
        return ordered[(i + (forward ? 1 : ordered.count - 1)) % ordered.count]
    }

    private static func fields(in root: NSView) -> [ScrubField] {
        var out: [ScrubField] = []
        func walk(_ v: NSView) { if let f = v as? ScrubField { out.append(f) }; v.subviews.forEach(walk) }
        walk(root)
        return out
    }

    func focusNeighbour(forward: Bool, editing: Bool = false) {
        guard let root = enclosingScrollView ?? window?.contentView,
              let next = Self.neighbour(of: self, in: Self.fields(in: root), forward: forward) else { return }
        window?.makeFirstResponder(next)
        if editing { next.beginEditing() }
    }

    // MARK: Text editing
    public func beginEditing() {
        guard !isEditing, window != nil else { return }
        isEditing = true
        let f = NSTextField(frame: textRect.insetBy(dx: 2, dy: 2))
        f.font = Theme.Fonts.small
        f.textColor = Theme.Colors.accent
        f.alignment = .center
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.usesSingleLineMode = true
        f.cell?.isScrollable = true
        f.stringValue = valueFormatter?(value) ?? ScrubMath.format(value, decimals: decimals, unit: "")
        f.delegate = self
        addSubview(f)
        editor = f
        window?.makeFirstResponder(f)
        f.currentEditor()?.selectAll(nil)
        needsDisplay = true
    }

    public func commitEditing() {
        guard isEditing, let f = editor else { return }
        let text = f.stringValue
        finishEditing()
        guard let v = parse(text) else { NSSound.beep(); return }
        let clamped = ScrubMath.clamp(v, to: range)
        guard clamped != value else { return }
        onBegin?()
        apply(clamped)
        onEnd?(value)
    }

    public func cancelEditing() {
        guard isEditing else { return }
        finishEditing()
    }

    private func finishEditing() {
        isEditing = false
        let f = editor
        editor = nil
        f?.delegate = nil
        f?.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)):
            commitEditing(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancelEditing(); return true
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            // Tab commits and opens the next field for typing, like Premiere's value fields.
            let forward = sel == #selector(NSResponder.insertTab(_:))
            commitEditing()
            focusNeighbour(forward: forward, editing: true)
            return true
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)):
            // Step the text in place; committed on Enter / focus loss.
            let dir = sel == #selector(NSResponder.moveUp(_:)) ? 1 : -1
            let mods = NSApp.currentEvent?.modifierFlags ?? []
            let current = parse(textView.string) ?? value
            let v = ScrubMath.stepped(current, direction: dir, step: step,
                                      shift: mods.contains(.shift), option: mods.contains(.option), range: range)
            textView.string = valueFormatter?(v) ?? ScrubMath.format(v, decimals: decimals, unit: "")
            textView.selectAll(nil)
            return true
        default:
            return false
        }
    }

    public func controlTextDidEndEditing(_ obj: Notification) {
        // Focus left the editor (click elsewhere / Tab): commit, unless Esc/Enter already closed it.
        if isEditing { commitEditing() }
    }
}
