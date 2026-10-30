import Foundation
import SQUIKit

/// The scrub number field of the portable UI: a translation of SQUIKit's `ScrubField` (same `ScrubMath`, same gesture
/// rules, same look). Drag scrubs (Shift x10, Option/Command x0.1), a click types, a double-click resets, Enter
/// commits, Esc cancels typing or returns the open gesture to its start, arrows and the Option-wheel step.
/// Instead of the AppKit callbacks it returns `Event`s the owner applies (EffectControlsModel's begin / set / end).
public struct ScrubFieldControl: Sendable {
    // MARK: Configuration (ScrubField's public vars)
    public var value: Double
    public var step: Double = 1
    public var range: ClosedRange<Double> = -1_000_000...1_000_000
    public var decimals = 0
    public var unit = ""
    public var defaultValue: Double?
    /// Controls grid fields: no capsule at rest, the number in accent.
    public var isPlain = false
    public var isEnabled = true
    public var isMixed = false
    public var leadingText = false
    /// Value text color (`valueTint`); nil = accent for plain fields, label otherwise.
    public var valueTint: DrawColor?
    public var valueFormatter: (@Sendable (Double) -> String)?
    public var valueParser: (@Sendable (String) -> Double?)?

    // MARK: State
    public private(set) var isDragging = false
    public private(set) var editor: TextEditState?
    public var isEditing: Bool { editor != nil }
    public var hovering = false
    private var pressed = false
    private var pressStartX: Float = 0
    private var lastX: Float = 0
    private var dragStartValue = 0.0
    private var accumulatedDX = 0.0
    private var burst = StepBurst()
    private var burstLast: Double = 0
    private var wheel = ScrubMath.WheelAccumulator()
    private var gestureStart: Double?
    /// Pixels of travel before a press becomes a drag (ScrubField.dragThreshold, in points times the scale).
    public static let dragThreshold: Float = 3

    public enum Event: Sendable, Equatable {
        /// A gesture opened (drag, arrow / wheel burst, typed commit, reset): the owner begins one undo step.
        case begin
        /// A drag value (draw now, apply at display rate).
        case live(Double)
        /// A committed value (arrow, wheel, typed, reset).
        case change(Double)
        /// The gesture closed with this value.
        case end(Double)
        /// Esc during a gesture: back to the start value, no undo step.
        case cancel(Double)
    }

    public init(value: Double) { self.value = value }

    public var displayText: String {
        if let valueFormatter { return valueFormatter(value) }
        return ScrubMath.format(value, decimals: decimals, unit: unit)
    }
    var canReset: Bool { defaultValue != nil }

    // MARK: Mouse
    /// `x` in pixels of the host; `clickCount` from the host's click counter.
    public mutating func mouseDown(x: Float, clickCount: Int) -> [Event] {
        guard isEnabled else { return [] }
        var out = endStepBurst()
        if isEditing {
            if clickCount == 2, canReset { editor = nil; return out + resetToDefault() }
            return out + commitEditing()
        }
        pressStartX = x; lastX = x
        pressed = true
        if clickCount == 2, canReset { pressed = false; out += resetToDefault(); return out }
        dragStartValue = value
        accumulatedDX = 0
        return out
    }

    /// `scale`: device pixels per point (the Mac scrubs per point).
    public mutating func mouseDragged(x: Float, modifiers: InputModifiers, scale: Float = 1) -> [Event] {
        guard pressed else { return [] }
        var out: [Event] = []
        if !isDragging {
            // Like the Mac's event.deltaX: the event that crosses the threshold counts with its own travel.
            guard abs(x - pressStartX) >= Self.dragThreshold * scale else { lastX = x; return [] }
            isDragging = true
            gestureStart = dragStartValue
            accumulatedDX = 0
            out.append(.begin)
            HostRequests.current.pointerLock = true     // the Mac ScrubField hides and pins the pointer while scrubbing
        }
        accumulatedDX += Double((x - lastX) / scale)
        lastX = x
        let v = ScrubMath.value(start: dragStartValue, deltaPixels: accumulatedDX, step: step,
                                shift: modifiers.contains(.shift),
                                option: modifiers.contains(.option) || modifiers.contains(.command), range: range)
        if v != value { value = v; out.append(.live(v)) }
        return out
    }

    public mutating func mouseUp() -> [Event] {
        guard pressed else { return [] }
        pressed = false
        if isDragging {
            isDragging = false
            HostRequests.current.pointerLock = false
            gestureStart = nil
            return [.end(value)]
        }
        beginEditing()
        return []
    }

    // MARK: Keys
    public mutating func key(_ k: InputKey, modifiers: InputModifiers, now: Double) -> [Event] {
        if var e = editor {
            switch e.handle(k, modifiers: modifiers) {
            case .commit: editor = e; return commitEditing()
            case .cancel: editor = nil; return []
            default: editor = e; return []
            }
        }
        let shift = modifiers.contains(.shift), option = modifiers.contains(.option) || modifiers.contains(.command)
        switch k {
        case .left, .down: return burstApply(ScrubMath.stepped(value, direction: -1, step: step, shift: shift, option: option, range: range), now: now)
        case .right, .up: return burstApply(ScrubMath.stepped(value, direction: +1, step: step, shift: shift, option: option, range: range), now: now)
        case .enter: beginEditing(); return []
        case .escape: return cancelGesture()
        default: return []
        }
    }

    /// The Mac ends a burst on key-up or after `StepBurst.idle` without a press; the host calls this every frame.
    public mutating func tick(now: Double) -> [Event] {
        guard burst.isOpen, now - burstLast >= StepBurst.idle else { return [] }
        return endStepBurst()
    }

    /// True when the wheel event belongs to this field.
    /// A host gesture (`ScrollGesture.published`) wins over `delta` / `precise`: the Mac ScrubField reads the raw
    /// `scrollingDelta` (Shift turns a wheel sideways) and the device kind; a pinch is no wheel.
    public mutating func scroll(delta: Double, precise: Bool, modifiers: InputModifiers, focused: Bool, now: Double) -> (used: Bool, events: [Event]) {
        var delta = delta, precise = precise
        if let g = ScrollGesture.published {
            guard g.isScroll else { return (false, []) }
            delta = ScrubMath.wheelDelta(deltaX: g.deltaX, deltaY: g.deltaY)
            precise = g.precise
        }
        guard isEnabled, !isEditing, !isDragging,
              ScrubMath.wheelAccepts(option: modifiers.contains(.option), hovered: hovering, focused: focused) else { return (false, []) }
        let n = wheel.add(delta: delta, precise: precise)
        guard n != 0 else { return (true, []) }
        return (true, burstApply(ScrubMath.wheelValue(value, notches: n, step: step, shift: modifiers.contains(.shift),
                                                       command: modifiers.contains(.command), range: range), now: now))
    }

    private mutating func burstApply(_ v: Double, now: Double) -> [Event] {
        guard v != value else { return [] }
        var out: [Event] = []
        if burst.step() { gestureStart = value; out.append(.begin) }
        burstLast = now
        value = v
        out.append(.change(v))
        return out
    }

    public mutating func endStepBurst() -> [Event] {
        wheel.reset()
        guard burst.end() else { return [] }
        gestureStart = nil
        return [.end(value)]
    }

    /// Esc: closes the editor without committing, or returns an open drag / burst to its start.
    public mutating func cancelGesture() -> [Event] {
        if isEditing { editor = nil; return [] }
        guard let start = gestureStart else { return [] }
        if isDragging { isDragging = false; pressed = false; HostRequests.current.pointerLock = false }
        else {
            wheel.reset()
            guard burst.end() else { gestureStart = nil; return [] }
        }
        gestureStart = nil
        value = start
        return [.cancel(start)]
    }

    public mutating func resetToDefault() -> [Event] {
        var out = endStepBurst()
        guard let v = ScrubMath.resetTarget(current: value, default: defaultValue, range: range) else { return out }
        value = v
        out += [.begin, .change(v), .end(v)]
        return out
    }

    // MARK: Typing
    public mutating func beginEditing() {
        guard editor == nil, isEnabled else { return }
        editor = TextEditState(isMixed ? "" : valueFormatter?(value) ?? ScrubMath.format(value, decimals: decimals, unit: ""))
    }

    /// Commits the typed text: simple maths (`+10`, `*2`) unless a parser is set; invalid text keeps the old value.
    public mutating func commitEditing() -> [Event] {
        guard let e = editor else { return [] }
        editor = nil
        let text = e.string
        if isMixed, text.trimmingCharacters(in: .whitespaces).isEmpty { return [] }
        let parsed: Double? = valueParser.map { $0(text) }
            ?? ScrubMath.evaluate(text, unit: unit, current: isMixed ? 0 : value, negativeAllowed: range.lowerBound < 0)
        guard let v = parsed else { return [] }
        let clamped = ScrubMath.clamp(v, to: range)
        guard clamped != value || isMixed else { return [] }
        value = clamped
        return [.begin, .change(clamped), .end(clamped)]
    }

    /// Focus moved away (a click elsewhere, Tab): commit typing, close a drag or burst.
    public mutating func resignFocus() -> [Event] {
        var out = endStepBurst()
        if isEditing { out += commitEditing() }
        if isDragging {
            isDragging = false; pressed = false; gestureStart = nil; out.append(.end(value))
            HostRequests.current.pointerLock = false
        }
        return out
    }

    // MARK: Drawing (ScrubField.draw)
    public func draw(_ c: inout Canvas, in bounds: CGRect, theme t: DrawTheme, focused: Bool) {
        let h = min(CGFloat(InspectorTokens.capsule), bounds.height)
        let box = CGRect(x: bounds.minX, y: bounds.minY + ((bounds.height - h) / 2).rounded(), width: bounds.width, height: h)
        let dim: Float = isEnabled ? 1 : InspectorTokens.disabledAlpha
        let radius = InspectorTokens.radius(box)
        let chrome = !isPlain || isEditing
        if chrome {
            let fill = t.field
            c.fill(roundedRect: box, radius: radius, fill.alpha(fill.a * dim))
            if isEditing { c.fill(roundedRect: box, radius: radius, t.accentTint) }
            if hovering, isEnabled, !focused, !isEditing {
                c.stroke(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), radius: radius - 0.5, width: 1, t.fieldEdgeHover)
            }
            if focused || isEditing { InspectorDraw.focusLine(&c, box, radius: radius, t) }
        }
        let valueColor = valueTint ?? (isPlain ? t.accent : t.label)
        let size = CGFloat(DrawTheme.TypeSize.body)
        if let e = editor {
            InspectorDraw.editText(&c, e, in: box.insetBy(dx: 6, dy: 0), fontSize: size, color: t.label,
                                   alignRight: !(isPlain && leadingText), t)
            return
        }
        guard !isMixed else {
            c.draw("\u{2013}", in: box, fontSize: size, t.label3, align: isPlain ? .left : .right, inset: isPlain ? 0 : 8)
            return
        }
        // Value in accent and a trailing unit in label3, 3 pt apart (board `.hv` / `.un`).
        var valueText = displayText, unitText = ""
        if isPlain, !unit.isEmpty, valueFormatter == nil, valueText.hasSuffix(unit) {
            valueText = String(valueText.dropLast(unit.count)).trimmingCharacters(in: .whitespaces); unitText = unit
        } else if leadingText {
            let parts = valueText.split(separator: " ", maxSplits: 1).map(String.init)
            if parts.count == 2, Double(parts[0].replacingOccurrences(of: ",", with: ".")) != nil, Double(parts[1]) == nil {
                valueText = parts[0]; unitText = parts[1]
            }
        }
        let vw = c.size(of: valueText, fontSize: size).width
        let uw = unitText.isEmpty ? 0 : c.size(of: unitText, fontSize: size).width + 3
        let x0: CGFloat
        if isPlain { x0 = leadingText ? box.minX : box.maxX - uw - vw }
        else { x0 = leadingText ? box.minX + 8 : max(box.minX + 8, box.maxX - 8 - vw - uw) }
        let line = CGRect(x: x0, y: box.minY, width: vw + 1, height: box.height)
        c.draw(valueText, in: line, fontSize: size, valueColor.alpha(valueColor.a * dim))
        if !unitText.isEmpty {
            c.draw(unitText, in: CGRect(x: x0 + vw + 3, y: box.minY, width: uw + 1, height: box.height), fontSize: size,
                   t.label3.alpha(t.label3.a * dim))
        }
    }
}

/// Counts clicks like the Mac's `clickCount`: a press within `interval` seconds and `slop` pixels of the last one adds one.
public struct ClickCounter: Sendable {
    public static let interval = 0.5
    public static let slop: Float = 4
    private var lastTime = -1.0, lastX: Float = 0, lastY: Float = 0, count = 0
    public init() {}
    public mutating func press(x: Float, y: Float, now: Double) -> Int {
        if lastTime >= 0, now - lastTime <= Self.interval, abs(x - lastX) <= Self.slop, abs(y - lastY) <= Self.slop { count += 1 }
        else { count = 1 }
        lastTime = now; lastX = x; lastY = y
        return count
    }
}
