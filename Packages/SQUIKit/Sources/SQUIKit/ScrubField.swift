import AppKit
import CoreGraphics

/// Scrubbable numeric value (design artifact v11, sq.css `.st .num.w`): capsule 22 high, `field` fill, accent value text,
/// hover 1 px white .18 edge, keyboard focus / typing = inner 1.5 px accent line on an accent tint. Drag horizontally to
/// change, click to type.
///
/// One gesture = one `onBegin` ... `onChange`* ... `onEnd` triple, so callers make exactly one undo step.
/// Drag: pixels * `step`, Shift x10, Option or Command x0.1 (fine); the pointer is hidden and locked while dragging.
/// Click (no drag): inline NSTextField; Enter commits, Esc cancels, Up/Down step. Left/Right/Up/Down step
/// when the field itself has focus. Double-click resets (R25, DECISIONS "Interaction rules"). Esc during a drag, an
/// arrow burst or a wheel burst cancels it: the value goes back to where the gesture started.
/// Scroll wheel: only with Option held while hovered or focused (Option+Shift x10, Option+Cmd x0.1), one burst = one
/// undo step; without Option the event goes on so the panel scrolls.
public final class ScrubField: NSControl, NSTextFieldDelegate, KeyClaiming {
    // MARK: Configuration
    public var value: Double = 0 {
        didSet { if !isDragging { needsDisplay = true } }
    }
    public var range: ClosedRange<Double> = -Double.greatestFiniteMagnitude...Double.greatestFiniteMagnitude
    /// Value change per dragged pixel (before modifiers).
    public var step: Double = 1
    public var unit: String = "" { didSet { needsDisplay = true } }
    /// Dialog rule (board: `unit('characters')` after `fld`): the unit sits to the right of the capsule, outside it. The capsule
    /// shows the bare number; the unit is still accepted when typed. `SQDialog.formRow` and `NumericSlider` draw the unit.
    public var unitOutside = false { didSet { needsDisplay = true } }
    /// Inline caption inside the capsule ("Letter", "Line"): drawn in t3 at the left, the value stays at the right.
    public var prefix: String = "" { didSet { needsDisplay = true } }
    /// Plain number: no capsule at rest, the value right-aligned in accent (Appearance rows). The capsule shows while editing.
    /// Rest fill override: dialog rows put a number field beside popups and want the popup's `fill`, not the darker `field` well.
    public var restFill: NSColor? { didSet { needsDisplay = true } }
    public var isPlain = false { didSet { needsDisplay = true } }
    public var decimals: Int = 0 { didSet { needsDisplay = true } }
    /// Overrides the default number+unit formatting (e.g. timecode).
    public var valueFormatter: (@MainActor (Double) -> String)?
    /// Overrides the default text parsing; return nil to reject.
    public var valueParser: (@MainActor (String) -> Double?)?

    // MARK: Callbacks
    public var onBegin: (@MainActor () -> Void)?
    public var onChange: (@MainActor (Double) -> Void)?
    public var onEnd: (@MainActor (Double) -> Void)?
    /// Esc during a drag / arrow / wheel gesture: called with the restored start value instead of `onEnd` (the caller
    /// drops the gesture's undo step). Without it the field restores through `onChange` + `onEnd`.
    public var onCancel: (@MainActor (Double) -> Void)?
    /// R25: double-click resets. With `onReset` the caller owns the reset (keyframes, several fields); otherwise a field
    /// with a `defaultValue` goes through begin / change / end as one undo step.
    public var defaultValue: Double?
    public var onReset: (@MainActor () -> Void)?
    /// Every value of a pointer drag, at event rate (for a coupled display such as NumericSlider's slider). `onChange`
    /// (and the target/action) get the drag's values at most once per display frame (K6, `LiveDragCoalescer`).
    public var onLiveValue: (@MainActor (Double) -> Void)?
    /// Hands drag values to `onChange` / the action at display rate; the last one is flushed before `onEnd`.
    private(set) lazy var liveCoalescer = LiveDragCoalescer { [weak self] v in
        guard let self else { return }
        onChange?(v)
        sendAction(action, to: target)
    }

    /// The property has keyframes (F11: the animate ring is a row control; the field only mirrors the state through this flag).
    /// The design draws every scrubbable value in `accent`, so the flag no longer changes the color.
    public var isAnimated = false { didSet { if oldValue != isAnimated { needsDisplay = true } } }
    /// Settings board: the value in the plain label color instead of accent.
    public var valueTint: NSColor? { didSet { needsDisplay = true } }
    var valueColor: NSColor { curveTint != nil ? Theme.black(0.9) : (valueTint ?? Theme.Colors.accent) }
    /// Dialog look (board `NB`): value in accent, the unit after it in `label3`; right aligned in a capsule (one rule for every number field), left only for plain Controls values.
    public var leadingText = false { didSet { needsDisplay = true } }
    /// Multi-select with differing values: the field is empty (no number), typing starts from an empty editor and any
    /// committed value is sent even when it equals `value`; a drag starts from `value`.
    public var isMixed = false { didSet { if oldValue != isMixed { needsDisplay = true } } }
    /// Graph Editor: the field is filled with its property's curve color (After Effects color chip).
    public var curveTint: NSColor? { didSet { if oldValue != curveTint { needsDisplay = true } } }

    // MARK: State
    public private(set) var isDragging = false
    public private(set) var isEditing = false
    private var editor: NSTextField?
    private var clickMonitor: Any?
    private var pressStart: NSPoint = .zero
    private var dragStartValue = 0.0
    private var accumulatedDX = 0.0
    private var pressed = false
    private var hovering = false
    private var tracking: NSTrackingArea?
    private var cursorHidden = false
    private var burst = StepBurst()
    private var burstTimer: Timer?
    private var wheel = ScrubMath.WheelAccumulator()
    /// Value when the open gesture (drag or burst) began; Esc returns to it.
    private var gestureStart: Double?
    private static let dragThreshold: CGFloat = 3

    public override var acceptsFirstResponder: Bool { true }
    public var claimsArrowKeys: Bool { !isEditing }
    public override var isFlipped: Bool { true }
    public override var intrinsicContentSize: NSSize {
        NSSize(width: 64, height: Theme.Metrics.capsule)
    }

    public override init(frame: NSRect) { super.init(frame: frame); setup() }
    public required init?(coder: NSCoder) { super.init(coder: coder); setup() }
    private func setup() {
        focusRingType = .none
        setAccessibilityRole(.incrementor)
    }

    deinit { MainActor.assumeIsolated { restorePointer(); removeClickMonitor(); burstTimer?.invalidate() } }

    // MARK: Text
    public var displayText: String {
        if let valueFormatter { return valueFormatter(value) }
        return ScrubMath.format(value, decimals: decimals, unit: unitOutside ? "" : unit)
    }

    /// Typed text on commit: simple maths (`+10`, `*2`, `1080/2`) unless a custom parser (timecode) is set.
    private func commitValue(_ text: String) -> Double? {
        if valueParser != nil { return parse(text) }
        return ScrubMath.evaluate(text, unit: unit, current: isMixed ? 0 : value, negativeAllowed: range.lowerBound < 0)
    }

    private func parse(_ text: String) -> Double? {
        if let valueParser { return valueParser(text) }
        return ScrubMath.parse(text, unit: unit)
    }

    // MARK: Geometry
    private var textRect: NSRect { bounds }

    // MARK: Drawing
    public override func draw(_ dirtyRect: NSRect) {
        let focused = window?.firstResponder === self || isEditing
        let h = min(Theme.Metrics.capsule, bounds.height)
        let box = NSRect(x: 0, y: ((bounds.height - h) / 2).rounded(), width: bounds.width, height: h)
        let dim = isEnabled ? 1 : Theme.State.disabledAlpha
        NSGraphicsContext.current?.saveGraphicsState()
        defer { NSGraphicsContext.current?.restoreGraphicsState() }
        let body = ControlShape.capsule(box)
        let chrome = !isPlain || isEditing
        if chrome {
            let fill = curveTint ?? restFill ?? Theme.Colors.field
            fill.withAlphaComponent(fill.alphaComponent * dim).setFill(); body.fill()
            if isEditing, curveTint == nil { Theme.Colors.accentTint.setFill(); body.fill() }
            // Design v7: no frame at rest; 1 px `fieldEdgeHover` on hover, inner 1.5 px accent line when focused.
            if hovering, isEnabled, !focused {
                let hover = ControlShape.capsule(box.insetBy(dx: 0.5, dy: 0.5))
                Theme.Colors.fieldEdgeHover.setStroke()
                hover.lineWidth = 1
                hover.stroke()
            }
            if focused { ControlShape.drawFocusLine(in: box, radius: ControlShape.radius(box)) }
        }

        if !isEditing, !isMixed {
            if leadingText {
                // Value in accent, a trailing non-numeric unit word ("dB", "%", "ms") in label3 (board `.hv` / `.un`).
                var valueText = displayText, unitText = ""
                let parts = valueText.split(separator: " ", maxSplits: 1).map(String.init)
                if parts.count == 2, Double(parts[0].replacingOccurrences(of: ",", with: ".")) != nil, Double(parts[1]) == nil {
                    valueText = parts[0]; unitText = parts[1]
                }
                let attrs: [NSAttributedString.Key: Any] = [.font: isPlain ? Theme.Typography.tabularBody : Theme.Typography.body, .foregroundColor: valueColor.withAlphaComponent(valueColor.alphaComponent * dim)]
                let v = valueText as NSString
                let sz = v.size(withAttributes: attrs)
                let ua: [NSAttributedString.Key: Any] = [.font: Theme.Typography.body, .foregroundColor: Theme.Colors.label3.withAlphaComponent(Theme.Colors.label3.alphaComponent * dim)]
                let uw = unitText.isEmpty ? 0 : (unitText as NSString).size(withAttributes: ua).width + 3
                // Plain (Controls grid): no capsule, the number starts on the field's own left edge. Capsule fields: value and
                // unit sit together at the right edge (board `.fld.num`), in every dialog and panel alike.
                let x0: CGFloat = isPlain ? 0 : max(8, textRect.maxX - 8 - sz.width - uw)
                let y = textRect.midY - sz.height / 2
                v.draw(at: NSPoint(x: x0, y: y), withAttributes: attrs)
                if !unitText.isEmpty { (unitText as NSString).draw(at: NSPoint(x: x0 + sz.width + 3, y: y), withAttributes: ua) }
                return
            }
            if isPlain, !unit.isEmpty, valueFormatter == nil, displayText.hasSuffix(unit), prefix.isEmpty {
                // Board `.hv` + `.un`: value in accent, unit in label3 3 pt after it, the pair right aligned.
                let valueText = String(displayText.dropLast(unit.count)).trimmingCharacters(in: .whitespaces) as NSString
                let va: [NSAttributedString.Key: Any] = [.font: Theme.Typography.tabularBody, .foregroundColor: valueColor.withAlphaComponent(valueColor.alphaComponent * dim)]
                let ua: [NSAttributedString.Key: Any] = [.font: Theme.Typography.body, .foregroundColor: Theme.Colors.label3.withAlphaComponent(Theme.Colors.label3.alphaComponent * dim)]
                let us = unit as NSString
                let vs = valueText.size(withAttributes: va), uz = us.size(withAttributes: ua)
                let x = leadingText ? textRect.minX : textRect.maxX - uz.width - 3 - vs.width, y = textRect.midY - vs.height / 2
                valueText.draw(at: NSPoint(x: x, y: y), withAttributes: va)
                us.draw(at: NSPoint(x: x + vs.width + 3, y: y), withAttributes: ua)
                return
            }
            let para = NSMutableParagraphStyle(); para.alignment = (isPlain && leadingText) ? .left : .right; para.lineBreakMode = .byTruncatingTail
            let attrs: [NSAttributedString.Key: Any] = [
                .font: Theme.Typography.body, .foregroundColor: valueColor.withAlphaComponent(valueColor.alphaComponent * dim), .paragraphStyle: para]
            let s = displayText as NSString
            let h = s.size(withAttributes: attrs).height
            let inset: CGFloat = isPlain ? 0 : 8
            s.draw(in: NSRect(x: textRect.minX + inset, y: textRect.midY - h / 2, width: textRect.width - inset - (isPlain ? 0 : 8), height: h),
                   withAttributes: attrs)
        }
        if !prefix.isEmpty {
            let pa: [NSAttributedString.Key: Any] = [
                .font: Theme.Typography.body, .foregroundColor: Theme.Colors.label3.withAlphaComponent(dim)]
            let ps = prefix as NSString
            ps.draw(at: NSPoint(x: textRect.minX + 8, y: textRect.midY - ps.size(withAttributes: pa).height / 2), withAttributes: pa)
        }
    }

    // MARK: Accessibility
    public override func accessibilityValue() -> Any? { displayText }
    public override func accessibilityPerformIncrement() -> Bool { stepOnce(+1); return true }
    public override func accessibilityPerformDecrement() -> Bool { stepOnce(-1); return true }

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
    /// Scrolling under a resting pointer sends no mouseExited: re-read the pointer on every scroll step.
    private lazy var hoverSync = ScrollHoverSync(view: self) { [weak self] p in
        guard let self, (p != nil) != self.hovering else { return }
        self.hovering = p != nil; self.needsDisplay = true
    }
    public override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); hoverSync.attach(); hoverSync.refresh() }
    public override func resetCursorRects() {
        addCursorRect(textRect, cursor: .resizeLeftRight)
    }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Mouse: drag to scrub, click to edit
    public override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        endStepBurst()
        if isEditing { commitEditing(); return }
        let p = convert(event.locationInWindow, from: nil)
        pressStart = p
        pressed = true
        if event.clickCount == 2, canReset {
            pressed = false
            resetToDefault()
            return
        }
        dragStartValue = value
        accumulatedDX = 0
        window?.makeFirstResponder(self)
    }

    public override func mouseDragged(with event: NSEvent) {
        guard pressed else { return }
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
        applyLive(v)
    }

    public override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        if isDragging { endDrag() } else { beginEditing() }
    }

    private func beginDrag(lockPointer: Bool = true) {
        isDragging = true
        gestureStart = dragStartValue
        liveCoalescer.begin()
        onBegin?()
        guard lockPointer else { return }
        NSCursor.hide(); cursorHidden = true
        CGAssociateMouseAndMouseCursorPosition(0)
    }

    private func endDrag() {
        restorePointer()
        isDragging = false
        gestureStart = nil
        needsDisplay = true
        liveCoalescer.flush()
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

    /// A pointer-drag value: the field draws it now, the owner hears it at display rate.
    private func applyLive(_ v: Double) {
        guard v != value else { return }
        value = v
        needsDisplay = true
        onLiveValue?(v)
        liveCoalescer.submit(v)
    }

    // MARK: Keys
    public override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags
        switch event.keyCode {
        case 123, 125: stepByKey(-1, shift: mods.contains(.shift), option: mods.contains(.option) || mods.contains(.command))   // left, down
        case 124, 126: stepByKey(+1, shift: mods.contains(.shift), option: mods.contains(.option) || mods.contains(.command))   // right, up
        case 48: focusNeighbour(forward: !mods.contains(.shift))                                       // tab
        case 36, 76: beginEditing()                                                                   // return, enter
        case 53 where isDragging || burst.isOpen: cancelGesture()                                     // escape
        default: super.keyDown(with: event)
        }
    }

    public override func keyUp(with event: NSEvent) {
        if [123, 124, 125, 126].contains(event.keyCode) { endStepBurst() } else { super.keyUp(with: event) }
    }

    /// A run of arrow presses is one gesture: begin at the first, end at key-up, focus loss or 0.5 s without a press (R22).
    private func stepByKey(_ dir: Int, shift: Bool, option: Bool) {
        burstApply(ScrubMath.stepped(value, direction: dir, step: step, shift: shift, option: option, range: range))
    }

    /// One step of a burst (arrows or wheel): opens the burst on the first change, ends it after `StepBurst.idle`.
    private func burstApply(_ v: Double) {
        guard v != value else { return }
        if burst.step() { gestureStart = value; onBegin?() }
        apply(v)
        burstTimer?.invalidate()
        burstTimer = Timer.scheduledTimer(withTimeInterval: StepBurst.idle, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.endStepBurst() }
        }
    }

    /// Closes the open arrow-key burst (one `onEnd`); safe to call any time.
    func endStepBurst() {
        burstTimer?.invalidate(); burstTimer = nil
        wheel.reset()
        if burst.end() { gestureStart = nil; onEnd?(value) }
    }

    // MARK: Scroll wheel

    public override func scrollWheel(with event: NSEvent) {
        let m = event.modifierFlags
        let used = handleWheel(delta: ScrubMath.wheelDelta(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY),
                               precise: event.hasPreciseScrollingDeltas, option: m.contains(.option),
                               hovered: hovering, shift: m.contains(.shift), command: m.contains(.command))
        if !used { super.scrollWheel(with: event) }
    }

    /// True when the wheel event changed (or belongs to) this field; false = pass it on.
    private func handleWheel(delta: Double, precise: Bool, option: Bool, hovered: Bool, shift: Bool, command: Bool) -> Bool {
        let focused = window?.firstResponder === self
        guard isEnabled, !isEditing, !isDragging,
              ScrubMath.wheelAccepts(option: option, hovered: hovered, focused: focused) else { return false }
        let n = wheel.add(delta: delta, precise: precise)
        if n != 0 {
            burstApply(ScrubMath.wheelValue(value, notches: n, step: step, shift: shift, command: command, range: range))
        }
        return true
    }

    func wheelForTesting(delta: Double, precise: Bool, option: Bool, hovered: Bool,
                         shift: Bool = false, command: Bool = false) -> Bool {
        handleWheel(delta: delta, precise: precise, option: option, hovered: hovered, shift: shift, command: command)
    }

    // MARK: Cancel (Esc)

    /// Esc: closes the text editor without committing, or returns an open drag / arrow / wheel gesture to its start.
    public func cancelGesture() {
        if isEditing { cancelEditing(); return }
        guard let start = gestureStart else { return }
        var sentDuringDrag = false
        if isDragging {
            sentDuringDrag = liveCoalescer.sentInDrag
            liveCoalescer.drop()
            restorePointer()
            isDragging = false
            pressed = false
        } else {
            burstTimer?.invalidate(); burstTimer = nil
            wheel.reset()
            guard burst.end() else { gestureStart = nil; return }
        }
        gestureStart = nil
        if let onCancel {
            value = start
            needsDisplay = true
            onCancel(start)
        } else {
            if value != start { apply(start) }
            else if sentDuringDrag {    // back at the start within one frame: the owner still holds the last value it was sent
                onChange?(start)
                sendAction(action, to: target)
            }
            onEnd?(value)
        }
    }

    func beginDragForTesting() {
        pressed = true
        dragStartValue = value
        accumulatedDX = 0
        beginDrag(lockPointer: false)
    }
    func dragForTesting(pixels: Double, shift: Bool = false, option: Bool = false) {
        accumulatedDX += pixels
        applyLive(ScrubMath.value(start: dragStartValue, deltaPixels: accumulatedDX, step: step,
                              shift: shift, option: option, range: range))
    }

    func endDragForTesting() {
        pressed = false
        if isDragging { endDrag() }
    }

    /// One self-contained step (accessibility actions).
    private func stepOnce(_ dir: Int) {
        let v = ScrubMath.stepped(value, direction: dir, step: step, shift: false, option: false, range: range)
        guard v != value else { return }
        onBegin?()
        apply(v)
        onEnd?(value)
    }

    func stepForTesting(_ dir: Int) { stepByKey(dir, shift: false, option: false) }

    private var canReset: Bool { onReset != nil || defaultValue != nil }

    /// Double-click action: `onReset`, else the default value as one undo step (no step when already there).
    func resetToDefault() {
        endStepBurst()
        if let onReset { onReset(); needsDisplay = true; return }
        guard let v = ScrubMath.resetTarget(current: value, default: defaultValue, range: range) else { return }
        onBegin?()
        apply(v)
        onEnd?(value)
    }

    public override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    public override func resignFirstResponder() -> Bool {
        endStepBurst()
        if isDragging { endDrag() }
        needsDisplay = true
        return true
    }
    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        endStepBurst()
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
        endStepBurst()
        isEditing = true
        var editRect = textRect.insetBy(dx: 6, dy: 2)
        if !prefix.isEmpty {
            let w = (prefix as NSString).size(withAttributes: [.font: Theme.Typography.body]).width
            editRect = NSRect(x: textRect.minX + 8 + w + 4, y: editRect.minY, width: max(textRect.width - 16 - w - 4, 20), height: editRect.height)
        }
        let f = NSTextField(frame: editRect)
        f.font = Theme.Typography.body
        f.textColor = valueColor
        f.alignment = (isPlain && leadingText) ? .left : .right
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.usesSingleLineMode = true
        f.cell?.isScrollable = true
        f.stringValue = isMixed ? "" : valueFormatter?(value) ?? ScrubMath.format(value, decimals: decimals, unit: "")
        f.delegate = self
        addSubview(f)
        editor = f
        window?.makeFirstResponder(f)
        f.currentEditor()?.selectAll(nil)
        needsDisplay = true
        installClickMonitor()
    }

    /// A click on a view that does not take focus (a row background, the keyframe lanes) never ends the text editing by
    /// itself, so the typed value would stay uncommitted. Any mouse press outside the editor commits it.
    private func installClickMonitor() {
        removeClickMonitor()
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            nonisolated(unsafe) let e = event
            let swallow = MainActor.assumeIsolated { self?.resetForDoubleClick(e) ?? false }
            if swallow { return nil }
            MainActor.assumeIsolated { self?.commitForPress(e) }
            return e
        }
    }

    private func removeClickMonitor() {
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
    }

    /// A double-click on the field while its text editor is open (the first click opened it) resets instead (R25).
    /// True when the event was consumed.
    func resetForDoubleClick(_ event: NSEvent) -> Bool {
        guard isEditing, canReset, event.clickCount == 2, event.type == .leftMouseDown, event.window === window,
              bounds.contains(convert(event.locationInWindow, from: nil)) else { return false }
        cancelEditing()
        resetToDefault()
        return true
    }

    /// Commits the open edit when the press lands outside the editor. The event is always passed on.
    func commitForPress(_ event: NSEvent) {
        guard isEditing, let editor else { return }
        if event.window == nil || event.window === window, editor.frame.contains(convert(event.locationInWindow, from: nil)) { return }
        commitEditing()
    }

    public func commitEditing() {
        guard isEditing, let f = editor else { return }
        let text = f.stringValue
        finishEditing()
        if isMixed, text.trimmingCharacters(in: .whitespaces).isEmpty { return }     // left empty: nothing changes
        guard let v = commitValue(text) else { NSSound.beep(); return }   // invalid input: the old value stays
        let clamped = ScrubMath.clamp(v, to: range)
        guard clamped != value || isMixed else { return }
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
        removeClickMonitor()
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
