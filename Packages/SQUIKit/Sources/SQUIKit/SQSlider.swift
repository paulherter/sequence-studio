import AppKit

/// Slider (design artifact v11, sq.css `.sl`): 2 px `fill` track, `accent` filled part, 10 px light knob with a soft shadow.
/// Hover brightens the knob, pressed turns the filled part white; disabled is drawn at `disabledAlpha`; keyboard focus is the
/// inner 1.5 px accent line. The pointer stays the normal arrow everywhere (DECISIONS "arrow cursor on sliders"). Replaces NSSlider.
/// Mirrors the NSSlider bits the app uses (`minValue`, `maxValue`, `doubleValue`, `isContinuous`, target/action).
///
/// Number rules (DECISIONS 2026-10-03 "Interaction rules", same as `ScrubField`): a press off the thumb jumps there, then
/// the drag is relative to the press (Shift x10, Option x0.1, a modifier change re-bases so the thumb never jumps);
/// double-click resets to `defaultValue`; Esc during the drag returns to the start; Option + scroll wheel steps 1 % of
/// the range (Shift x10, Cmd x0.1) as one undo step per burst. One gesture = one `onBegin` / `onChange`* / `onEnd` triple; target/action still fire.
open class SQSlider: NSControl {
    public var minValue: Double = 0 { didSet { needsDisplay = true } }
    public var maxValue: Double = 1 { didSet { needsDisplay = true } }
    open override var doubleValue: Double {
        get { storedValue }
        set { storedValue = Self.clamp(newValue, minValue, maxValue); needsDisplay = true }
    }
    /// Double-click target (nil = no reset).
    public var defaultValue: Double?
    public var onBegin: (@MainActor () -> Void)?
    public var onChange: (@MainActor (Double) -> Void)?
    public var onEnd: (@MainActor (Double) -> Void)?
    /// Every value of a pointer drag, at event rate (for a coupled display such as NumericSlider's field). `onChange`
    /// (and a continuous target/action) get the drag's values at most once per display frame (K6, `LiveDragCoalescer`).
    public var onLiveValue: (@MainActor (Double) -> Void)?
    /// Hands drag values to `onChange` / the action at display rate; the last one is flushed before `onEnd`.
    private(set) lazy var liveCoalescer = LiveDragCoalescer { [weak self] v in
        guard let self else { return }
        onChange?(v)
        if isContinuous { sendAction(action, to: target) }
    }

    private var storedValue: Double = 0
    var isDragging = false { didSet { needsDisplay = true } }
    var isHovered = false { didSet { if oldValue != isHovered { needsDisplay = true } } }
    private var hoverArea: NSTrackingArea?
    private var burst = StepBurst()
    private var burstTimer: Timer?
    private var wheel = ScrubMath.WheelAccumulator()
    private let thumb = Theme.Metrics.sliderKnob
    /// Press hit area around the thumb: a press inside it grabs the thumb instead of jumping.
    private let halo: CGFloat = 16

    public convenience init(value: Double, minValue: Double, maxValue: Double, target: AnyObject? = nil, action: Selector? = nil) {
        self.init(frame: .zero)
        self.minValue = minValue; self.maxValue = maxValue
        self.doubleValue = value
        self.target = target; self.action = action
    }
    public override init(frame: NSRect) {
        super.init(frame: frame)
        isContinuous = true
        focusRingType = .none
        setAccessibilityRole(.slider)
    }
    public required init?(coder: NSCoder) { fatalError() }

    deinit { MainActor.assumeIsolated { burstTimer?.invalidate() } }

    public static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }
    /// Value for an x position inside a track of `width` with a thumb of `thumb` points.
    public static func value(atX x: CGFloat, width: CGFloat, thumb: CGFloat, min lo: Double, max hi: Double) -> Double {
        let span = Swift.max(width - thumb, 1)
        let f = Double(Swift.min(Swift.max((x - thumb / 2) / span, 0), 1))
        return lo + f * (hi - lo)
    }
    static func fraction(_ v: Double, _ lo: Double, _ hi: Double) -> Double { hi > lo ? clamp((v - lo) / (hi - lo), 0, 1) : 0 }

    /// Relative drag: `deltaX` points over a `trackWidth` track move the full range once (x1), Shift x10, Option x0.1.
    public static func dragValue(start: Double, deltaX: Double, trackWidth: Double, min lo: Double, max hi: Double,
                                 shift: Bool, option: Bool) -> Double {
        guard trackWidth > 0, hi > lo else { return clamp(start, lo, hi) }
        let perPoint = (hi - lo) / trackWidth * ScrubMath.multiplier(shift: shift, option: option)
        return clamp(start + deltaX * perPoint, lo, hi)
    }

    open override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 16) }
    open override var acceptsFirstResponder: Bool { false }
    open override var isEnabled: Bool { didSet { needsDisplay = true } }
    open override func accessibilityValue() -> Any? { storedValue }

    // MARK: Geometry

    private var thumbCentreX: CGFloat {
        thumb / 2 + CGFloat(Self.fraction(storedValue, minValue, maxValue)) * (bounds.width - thumb)
    }
    private var thumbRect: NSRect {
        NSRect(x: thumbCentreX - halo / 2, y: bounds.midY - halo / 2, width: halo, height: halo)
    }

    // MARK: Hover + cursor

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

    // MARK: Value changes

    private func set(_ v: Double) {
        let c = Self.clamp(v, minValue, maxValue)
        guard c != storedValue else { return }
        doubleValue = c
        onChange?(c)
        if isContinuous { sendAction(action, to: target) }
    }

    /// A pointer-drag value: the thumb moves now, the owner hears it at display rate.
    private func setLive(_ v: Double) {
        let c = Self.clamp(v, minValue, maxValue)
        guard c != storedValue else { return }
        doubleValue = c
        onLiveValue?(c)
        liveCoalescer.submit(c)
    }

    /// Double-click action: `defaultValue` as one gesture (nothing when already there).
    public func resetToDefault() {
        endStepBurst()
        guard let v = ScrubMath.resetTarget(current: storedValue, default: defaultValue, range: minValue...max(minValue, maxValue))
        else { return }
        onBegin?()
        set(v)
        onEnd?(storedValue)
        if !isContinuous { sendAction(action, to: target) }
    }

    // MARK: Mouse

    open override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        endStepBurst()
        if event.clickCount == 2, defaultValue != nil { resetToDefault(); return }
        let p = convert(event.locationInWindow, from: nil)
        trackBegan()
        if !thumbRect.contains(p) {
            trackMoved(to: Self.value(atX: p.x, width: bounds.width, thumb: thumb, min: minValue, max: maxValue))
        }
        var base = storedValue, baseX = p.x
        var mods = event.modifierFlags
        var cancelled = false
        while let e = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown, .flagsChanged]) {
            if e.type == .leftMouseUp { break }
            if e.type == .keyDown {
                if e.keyCode == 53 { cancelled = true; break }      // Esc: back to the start
                continue
            }
            let x = convert(e.locationInWindow, from: nil).x
            if e.type == .flagsChanged {
                // Re-base on a modifier change so the thumb does not jump to the new rate.
                mods = e.modifierFlags; base = storedValue; baseX = x
                continue
            }
            mods = e.modifierFlags
            trackMoved(to: Self.dragValue(start: base, deltaX: Double(x - baseX), trackWidth: Double(bounds.width - thumb),
                                          min: minValue, max: maxValue,
                                          shift: mods.contains(.shift), option: mods.contains(.option)))
        }
        trackEnded(cancelled: cancelled)
    }

    /// Value when the open pointer drag began (Esc returns to it).
    private var trackStart = 0.0

    /// Pointer drag, step by step (the tracking loop above; tests drive it directly). One `onBegin` ... `onEnd`.
    func trackBegan() {
        trackStart = storedValue
        liveCoalescer.begin()
        onBegin?()
        isDragging = true
    }

    func trackMoved(to v: Double) { setLive(v) }

    func trackEnded(cancelled: Bool) {
        if cancelled {
            let sent = liveCoalescer.sentInDrag
            liveCoalescer.drop()
            if storedValue != trackStart { set(trackStart) }
            else if sent {      // moved back to the start inside one frame: the owner still holds the last sent value
                onChange?(trackStart)
                if isContinuous { sendAction(action, to: target) }
            }
        } else {
            liveCoalescer.flush()
        }
        isDragging = false
        onEnd?(storedValue)
        if !isContinuous { sendAction(action, to: target) }
    }

    // MARK: Scroll wheel (Option only, so panels still scroll)

    open override func scrollWheel(with event: NSEvent) {
        let m = event.modifierFlags
        guard isEnabled, ScrubMath.wheelAccepts(option: m.contains(.option), hovered: isHovered, focused: false) else {
            super.scrollWheel(with: event); return
        }
        let n = wheel.add(delta: ScrubMath.wheelDelta(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY),
                          precise: event.hasPreciseScrollingDeltas)
        guard n != 0 else { return }
        let v = ScrubMath.wheelValue(storedValue, notches: n, step: (maxValue - minValue) / 100,
                                     shift: m.contains(.shift), command: m.contains(.command), range: minValue...max(minValue, maxValue))
        guard v != storedValue else { return }
        if burst.step() { onBegin?() }
        set(v)
        burstTimer?.invalidate()
        burstTimer = Timer.scheduledTimer(withTimeInterval: StepBurst.idle, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.endStepBurst() }
        }
    }

    /// Closes an open wheel burst (one `onEnd`); safe to call any time.
    func endStepBurst() {
        burstTimer?.invalidate(); burstTimer = nil
        wheel.reset()
        if burst.end() {
            onEnd?(storedValue)
            if !isContinuous { sendAction(action, to: target) }
        }
    }

    // MARK: Drawing

    open override func draw(_ dirtyRect: NSRect) {
        let cx = thumbCentreX
        let dim = isEnabled ? 1 : Theme.State.disabledAlpha
        let trackH = Theme.Metrics.sliderTrack
        let track = NSRect(x: 0, y: (bounds.midY - trackH / 2).rounded(), width: bounds.width, height: trackH)
        Theme.Colors.fill.withAlphaComponent(Theme.Colors.fill.alphaComponent * dim).setFill()
        NSBezierPath(roundedRect: track, xRadius: trackH / 2, yRadius: trackH / 2).fill()
        let filled = isDragging ? Theme.Colors.label : Theme.Colors.accent
        filled.withAlphaComponent(filled.alphaComponent * dim).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: track.minY, width: cx, height: trackH), xRadius: trackH / 2, yRadius: trackH / 2).fill()
        let knob = NSRect(x: cx - thumb / 2, y: bounds.midY - thumb / 2, width: thumb, height: thumb)
        if isEnabled {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = Theme.black(0.6)
            shadow.shadowBlurRadius = 1.5
            shadow.shadowOffset = NSSize(width: 0, height: isFlipped ? 0.5 : -0.5)
            shadow.set()
            (isHovered || isDragging ? Theme.Colors.sliderKnobActive : Theme.Colors.sliderKnob).setFill()
            NSBezierPath(ovalIn: knob).fill()
            NSGraphicsContext.restoreGraphicsState()
        } else {
            Theme.Colors.sliderKnob.withAlphaComponent(dim).setFill()
            NSBezierPath(ovalIn: knob).fill()
        }
        if ControlShape.isFocused(self) { ControlShape.drawFocusLine(in: bounds, radius: Theme.Radius.control) }
    }
}
