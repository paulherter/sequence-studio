import AppKit
import simd
import SQCore
import SQRender

/// The one inset and row grid of the Color page (design source sq.css `.row`, `.sec`, `.grp`, `.sl`): 12 px panel
/// inset, a 16 px chevron slot, a 100 px label column, the control, a 60 px value column.
enum ColorGrid {
    static let inset = Theme.Spacing.md
    static let chevron = Theme.Spacing.lg
    /// The chevron glyph's own box at the left of the chevron column (board: centered 5 pt past the inset).
    static let chevronGlyph = Theme.Spacing.sm + Theme.Spacing.xs
    static let label: CGFloat = 96
    /// Version 9 `.srow .val`: the number is 48 wide (the column adds the gap to the slider).
    static let value: CGFloat = 48 + Theme.Spacing.sm
    /// Slider rows: 24 pt. Rows that hold a popup, a button or a field (capsules) add Spacing.xs above and below so
    /// stacked pills never touch.
    static let row = Theme.Row.property
    static let controlRow = Theme.Metrics.quietButton + 2 * Theme.Spacing.xs
    /// Board rows with a popup (Interpret As, Project Input, the action line, a LUT row): 28 high.
    static let popupRow = Theme.Row.property + Theme.Spacing.xs
    /// Board `.btn.ic`: an icon-only button is 24 wide.
    static let iconButton = Theme.Metrics.barIconWidth
    /// A label made with `labelWithString` draws its text 2 pt inside its frame; the board places the text itself.
    static let textInset: CGFloat = 2
    /// Section header: a 25 px line under a 4 px gap, hairline on top.
    static let section: CGFloat = 25
    static let sectionGap = Theme.Spacing.xs
    static let group = Theme.Row.columnHeader
    static let slider: CGFloat = 20
    static let gap = Theme.Spacing.sm
    /// Curve boxes: 6 px above, 8 px below, the panel inset at the sides.
    static let curveTop: CGFloat = 6
    static let curveBottom = Theme.Spacing.sm
    static let rgbCurve: CGFloat = 150
    static let hueCurve: CGFloat = 90
    static let wheel: CGFloat = 96
    /// The width the Color controls' rows get in a panel `panelWidth` wide: the whole panel up to the row cap
    /// (`Theme.Inspector.maxRowWidth`), the cap beyond it.
    static func rowWidth(panelWidth: CGFloat) -> CGFloat { max(0, min(panelWidth, Theme.Inspector.maxRowWidth)) }

    static var labelX: CGFloat { inset + chevron }
    static var controlX: CGFloat { labelX + label }
}

/// Color page slider (design source `.sl`): a 2 px track with the accent fill from the left end, or from the center
/// tick for values that go both ways; Temperature and Tint show their color ramp instead. 10 px white knob. Dragging
/// anywhere on the track moves the knob (a plain click changes nothing), Shift drags coarse (x10), Option fine (x0.1),
/// Esc during a drag puts the value back, double-click resets (DECISIONS 2026-10-03 "Interaction rules"), Option+wheel
/// steps 1 % of the range (Shift x10, Cmd x0.1), arrows step. The pointer stays the arrow.
/// One drag = `onBegin` -> `onChange`* -> `onEnd` (one undo step).
@MainActor
final class LumetriSlider: NSControl, KeyClaiming {
    var minValue = 0.0 { didSet { needsDisplay = true } }
    var maxValue = 1.0 { didSet { needsDisplay = true } }
    var neutral = 0.0 { didSet { needsDisplay = true } }
    var step = 0.1
    var value = 0.0 { didSet { if value != oldValue { needsDisplay = true } } }
    var track: ColorParam.Track = .plain { didSet { needsDisplay = true } }
    override var isEnabled: Bool { didSet { needsDisplay = true } }

    var onBegin: (() -> Void)?
    var onChange: ((Double) -> Void)?
    var onEnd: (() -> Void)?
    var onReset: (() -> Void)?
    /// Esc during a drag: the host withdraws the whole gesture (replaces `onEnd`). Without it the start value is set.
    var onCancel: (() -> Void)?
    /// Hands drag values to `onChange` at display rate (K6); the last one is flushed before `onEnd`. The knob itself
    /// follows every event.
    private(set) lazy var liveCoalescer = LiveDragCoalescer { [weak self] v in self?.onChange?(v) }

    static let knob: CGFloat = 10
    private static let inset: CGFloat = knob / 2
    private var pressed = false, began = false, grabbedKnob = false
    private var pressX: CGFloat = 0
    /// Relative drag: the value and pointer x the current modifier state started from (re-anchored when it changes).
    private var anchorValue = 0.0, anchorX: CGFloat = 0
    private var anchorShift = false, anchorOption = false
    private var startValue = 0.0
    private static let dragThreshold: CGFloat = 3
    private var nudgeBurst = StepBurst()
    private var nudgeTimer: Timer?
    private var wheel = ScrubMath.WheelAccumulator()
    private var hoverArea: NSTrackingArea?
    private(set) var isHovered = false

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: ColorGrid.slider) }
    override var acceptsFirstResponder: Bool { isEnabled }
    var claimsArrowKeys: Bool { true }
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
        return Self.snap(minValue + min(max(t, 0), 1) * (maxValue - minValue), step: step, min: minValue, max: maxValue)
    }

    static func snap(_ v: Double, step: Double, min lo: Double, max hi: Double) -> Double {
        guard step > 0 else { return Swift.min(Swift.max(v, lo), hi) }
        return Swift.min(Swift.max((v / step).rounded() * step, lo), hi)
    }

    /// Relative drag from an anchor (pure): `SQSlider.dragValue` (Shift x10, Option x0.1) snapped to `step`.
    static func dragValue(anchor: Double, deltaX: Double, trackWidth: Double, min lo: Double, max hi: Double, step: Double,
                          shift: Bool, option: Bool) -> Double {
        snap(SQSlider.dragValue(start: anchor, deltaX: deltaX, trackWidth: trackWidth, min: lo, max: hi,
                                shift: shift, option: option), step: step, min: lo, max: hi)
    }

    /// The value goes both ways from its neutral (signed values): the fill starts at the center tick.
    var isCentred: Bool { Self.isCentred(min: minValue, max: maxValue, neutral: neutral) }

    static func isCentred(min lo: Double, max hi: Double, neutral: Double) -> Bool { lo < 0 && lo < neutral && neutral < hi }

    /// The accent fill on the track as (from, to) in x; nil for the color-ramp tracks (they show no fill).
    var fillSpan: (from: CGFloat, to: CGFloat)? {
        guard track == .plain else { return nil }
        let k = knobX(value)
        guard isCentred else { return (0, k) }
        let c = knobX(neutral)
        return (min(c, k), max(c, k))
    }

    // MARK: Drawing

    private var ramp: NSGradient? {
        switch track {
        case .plain: nil
        case .temperature: NSGradient(colors: Theme.Palette.whiteBalanceTemperature, atLocations: [0, 0.5, 1], colorSpace: .sRGB)
        case .tint: NSGradient(colors: Theme.Palette.whiteBalanceTint, atLocations: [0, 0.5, 1], colorSpace: .sRGB)
        case .saturation: NSGradient(colors: Theme.Palette.saturationRamp, atLocations: [0, 0.4, 0.7, 1], colorSpace: .sRGB)
        }
    }

    /// Version 9 `.sl`: a 3 pt track (5 pt for a color ramp) and a 4 x 14 bar as the thumb.
    static let trackHeight: CGFloat = 3
    static let rampHeight: CGFloat = 5
    static let thumb = NSSize(width: 4, height: 14)

    override func draw(_ dirtyRect: NSRect) {
        let y = bounds.midY.rounded()
        let th = ramp != nil ? Self.rampHeight : Self.trackHeight
        let line = NSRect(x: 0, y: y - th / 2, width: bounds.width, height: th)
        let path = NSBezierPath(roundedRect: line, xRadius: th / 2, yRadius: th / 2)
        if let ramp {
            ramp.draw(in: path, angle: 0)
            Theme.Colors.label.withAlphaComponent(0.5).setFill()
            NSRect(x: (bounds.midX - 0.5).rounded(), y: y - 4.5, width: 1, height: 9).fill()
        } else {
            Theme.Colors.fill.setFill()
            path.fill()
            if let f = fillSpan, isEnabled {
                Theme.Colors.accent.setFill()
                NSBezierPath(roundedRect: NSRect(x: f.from, y: y - th / 2, width: f.to - f.from, height: th), xRadius: th / 2, yRadius: th / 2).fill()
            }
        }
        let r = NSRect(x: (knobX(value) - Self.thumb.width / 2).rounded(), y: y - Self.thumb.height / 2, width: Self.thumb.width,
                       height: Self.thumb.height)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = Theme.Palette.sliderKnobShadow
        shadow.shadowBlurRadius = 1.5
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.set()
        (isEnabled ? Theme.Palette.sliderKnob : Theme.Colors.label3).setFill()
        NSBezierPath(roundedRect: r, xRadius: Self.thumb.width / 2, yRadius: Self.thumb.width / 2).fill()
        NSGraphicsContext.restoreGraphicsState()
        if window?.firstResponder === self, isEnabled {
            Theme.Colors.accentRing.setStroke()
            let f = NSBezierPath(roundedRect: r.insetBy(dx: -2, dy: -2), xRadius: Theme.Radius.panel, yRadius: Theme.Radius.panel)
            f.lineWidth = Theme.State.focusRingWidth
            f.stroke()
        }
    }

    // MARK: Hover (the wheel steps the slider under the pointer; the cursor stays the arrow)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        hoverArea = a
    }
    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    // MARK: Mouse and keyboard

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        endNudgeBurst()
        pressed = false; began = false
        if event.clickCount == 2 { onReset?(); return }
        let x = convert(event.locationInWindow, from: nil).x
        pressed = true
        pressX = x
        startValue = value
        grabbedKnob = abs(x - knobX(value)) <= Self.knob / 2 + 2
        anchorValue = value; anchorX = x
        anchorShift = event.modifierFlags.contains(.shift); anchorOption = event.modifierFlags.contains(.option)
        // Nothing changes on press (R25): a click must not move the value, or a double-click would first jump it.
        // The knob follows from the first drag movement on.
    }

    override func mouseDragged(with event: NSEvent) {
        guard pressed else { return }
        let x = convert(event.locationInWindow, from: nil).x
        if !grabbedKnob, !began, abs(x - pressX) < Self.dragThreshold { return }
        let shift = event.modifierFlags.contains(.shift), option = event.modifierFlags.contains(.option)
        if !grabbedKnob, !began {
            // A drag that starts on the track first jumps the knob under the pointer, then continues relative.
            set(value(atX: x))
            anchorValue = value; anchorX = x; anchorShift = shift; anchorOption = option
            return
        }
        if shift != anchorShift || option != anchorOption {
            // Re-anchor so pressing or releasing a modifier mid-drag never jumps the knob.
            anchorValue = value; anchorX = x; anchorShift = shift; anchorOption = option
        }
        set(Self.dragValue(anchor: anchorValue, deltaX: Double(x - anchorX), trackWidth: Double(max(bounds.width - 2 * Self.inset, 1)),
                           min: minValue, max: maxValue, step: step, shift: shift, option: option))
    }

    override func mouseUp(with event: NSEvent) { endDrag() }

    private func endDrag() {
        guard pressed else { return }
        pressed = false
        if began { began = false; liveCoalescer.flush(); onEnd?(); needsDisplay = true }
    }

    /// Esc during a drag: the value goes back to where the drag started and the host withdraws the gesture
    /// (`onCancel`: no undo step, nothing the drag created is left).
    func cancelDrag() {
        guard pressed else { return }
        pressed = false
        guard began else { return }
        began = false
        let sent = liveCoalescer.sentInDrag
        liveCoalescer.drop()
        let moved = value != startValue || sent
        value = startValue
        if let onCancel { onCancel() } else {
            if moved { onChange?(startValue) }
            onEnd?()
        }
        needsDisplay = true
    }

    /// A pointer-drag value: the knob moves now, the owner hears it at display rate.
    private func set(_ v: Double) {
        guard v != value else { return }
        if !began { began = true; liveCoalescer.begin(); onBegin?() }
        value = v
        liveCoalescer.submit(v)
    }

    func dragBeganForTesting() { pressed = true; began = false; startValue = value }
    func dragForTesting(to v: Double) { set(v) }
    func dragEndedForTesting() { endDrag() }

    private func nudge(_ delta: Double) {
        let v = min(max(((value + delta) / step).rounded() * step, minValue), maxValue)
        guard v != value else { return }
        value = v
        if nudgeBurst.step() { onBegin?() }
        onChange?(v)
        nudgeTimer?.invalidate()
        nudgeTimer = Timer.scheduledTimer(withTimeInterval: StepBurst.idle, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.endNudgeBurst() }
        }
    }

    /// A run of arrow presses or wheel notches is one undo step: ends at key-up, focus loss or 0.5 s idle.
    func endNudgeBurst() {
        nudgeTimer?.invalidate(); nudgeTimer = nil
        wheel.reset()
        if nudgeBurst.end() { onEnd?() }
    }

    override func scrollWheel(with event: NSEvent) {
        let m = event.modifierFlags
        guard isEnabled, !pressed,
              ScrubMath.wheelAccepts(option: m.contains(.option), hovered: isHovered, focused: window?.firstResponder === self)
        else { super.scrollWheel(with: event); return }
        let n = wheel.add(delta: ScrubMath.wheelDelta(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY),
                          precise: event.hasPreciseScrollingDeltas)
        guard n != 0 else { return }
        let v = ScrubMath.wheelValue(value, notches: n, step: (maxValue - minValue) / 100, shift: m.contains(.shift),
                                     command: m.contains(.command), range: minValue...max(minValue, maxValue))
        nudge(v - value)
    }

    override func resignFirstResponder() -> Bool { endNudgeBurst(); return super.resignFirstResponder() }

    override func keyUp(with event: NSEvent) {
        if [123, 124, 125, 126].contains(event.keyCode) { endNudgeBurst() } else { super.keyUp(with: event) }
    }

    override func keyDown(with event: NSEvent) {
        let big = (maxValue - minValue) / 20
        switch event.keyCode {
        case 53 where pressed: cancelDrag()
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

/// One slider row on the Color grid (design source `.row`): label, slider, value in the 60 px value column (type to
/// edit, Return commits, drag to scrub). No keyframe controls on the Color page (REDESIGN-ROUND-2 decision 3).
@MainActor
final class ColorParamRow: NSView {
    let param: ColorParam?
    let slider = LumetriSlider()
    let field = ScrubField()
    let label: NSTextField
    private let decimals: Int
    private let neutral: Float
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?
    /// The slider drag was canceled (Esc): ends the gesture and withdraws it.
    var onCancel: (() -> Void)?
    /// A value the user chose (slider drag or typed).
    var onSet: ((Float) -> Void)?
    var onReset: (() -> Void)?

    static let titleWidth = ColorGrid.label

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: ColorGrid.row) }

    // The value texts are portable (`ColorValueText`, shared with the draw-list Color page).
    nonisolated static func text(_ v: Double, decimals: Int) -> String { ColorValueText.text(v, decimals: decimals) }
    nonisolated static func editText(_ v: Double, decimals: Int) -> String { ColorValueText.editText(v, decimals: decimals) }
    nonisolated static func signedText(_ v: Double, decimals: Int) -> String { ColorValueText.signedText(v, decimals: decimals) }
    nonisolated static func shownDecimals(range: ClosedRange<Float>, decimals: Int) -> Int {
        ColorValueText.shownDecimals(range: range, decimals: decimals)
    }
    nonisolated static func number(_ s: String) -> Double? { ColorValueText.number(s) }

    init(_ p: ColorParam?, title: String? = nil, range: ClosedRange<Float>? = nil, neutral: Float = 0, decimals: Int = 1) {
        param = p
        self.decimals = p?.decimals ?? decimals
        self.neutral = p?.neutral ?? neutral
        let r = p?.range ?? range ?? 0...100
        label = NSTextField(labelWithString: title ?? p?.title ?? "")
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: ColorGrid.row))
        label.font = Theme.Typography.body
        label.textColor = Theme.Colors.label2
        label.lineBreakMode = .byTruncatingTail

        slider.minValue = Double(r.lowerBound); slider.maxValue = Double(r.upperBound)
        slider.neutral = Double(self.neutral); slider.value = Double(self.neutral)
        slider.step = 1 / pow(10, Double(self.decimals))
        slider.track = p?.track ?? .plain
        slider.setAccessibilityLabel(label.stringValue)
        slider.onBegin = { [weak self] in self?.onBegin?() }
        slider.onEnd = { [weak self] in self?.onEnd?() }
        slider.onCancel = { [weak self] in self?.onCancel?() }
        slider.onChange = { [weak self] v in self?.onSet?(Float(v)) }
        slider.onReset = { [weak self] in self?.onReset?() }

        // Value: drag to scrub (Shift x10, Option x0.1), click to type, double-click resets, arrows step. One gesture = one undo step.
        field.isPlain = true    // version 9 `.srow .val`: plain numbers in the label color; the capsule shows while typing
        field.valueTint = Theme.Colors.label
        field.range = Double(r.lowerBound)...Double(r.upperBound)
        field.decimals = self.decimals
        let d = self.decimals, shown = Self.shownDecimals(range: r, decimals: self.decimals)
        field.valueFormatter = { [weak field] v in
            field?.isEditing == true ? Self.editText(v, decimals: d) : Self.text(v, decimals: shown)
        }
        field.valueParser = { Self.number($0) }
        field.step = max((Double(r.upperBound) - Double(r.lowerBound)) / 400, slider.step)
        field.value = Double(self.neutral)
        field.onBegin = { [weak self] in self?.onBegin?() }
        field.onChange = { [weak self] v in self?.onSet?(Float(v)) }
        field.onEnd = { [weak self] _ in self?.onEnd?() }
        field.defaultValue = Double(self.neutral)
        field.onReset = { [weak self] in self?.onReset?() }
        field.setAccessibilityLabel(label.stringValue + " value")

        for v in [label, slider, field] as [NSView] { addSubview(v) }
        heightAnchor.constraint(equalToConstant: ColorGrid.row).isActive = true
        show(self.neutral)
        if p == nil { setActive(false) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func layout() {
        super.layout()
        let h = bounds.height
        let lh = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: ColorGrid.labelX - ColorGrid.textInset, y: ((h - lh) / 2).rounded(),
                             width: ColorGrid.label - ColorGrid.gap, height: lh)
        let fh = min(field.intrinsicContentSize.height, h)
        let fx = bounds.width - ColorGrid.inset - ColorGrid.value + ColorGrid.gap
        field.frame = NSRect(x: fx, y: ((h - fh) / 2).rounded(), width: ColorGrid.value - ColorGrid.gap, height: fh)
        slider.frame = NSRect(x: ColorGrid.controlX, y: ((h - ColorGrid.slider) / 2).rounded(),
                              width: max(fx - ColorGrid.gap - ColorGrid.controlX, 0), height: ColorGrid.slider)
    }

    func show(_ v: Float) {
        if slider.value != Double(v) { slider.value = Double(v) }
        if !field.isEditing && !field.isDragging { field.value = Double(v) }
    }

    /// Intensity-without-LUT rows are dimmed and cannot be edited.
    private(set) var isActive = true

    func setActive(_ on: Bool) {
        isActive = on
        slider.isEnabled = on
        field.isEnabled = on
        alphaValue = on ? 1 : Theme.State.disabledAlpha
    }
}

/// A row with a label and controls on the Color grid (design source `.row` holding a popup, a button or a field: 28
/// high). The controls fill the control and value columns left to right, 8 px apart; the first one stretches when
/// `stretchFirst` is set, a trailing label takes the rest.
@MainActor
final class ColorControlRow: NSView {
    let label: NSTextField
    private let controls: [NSView]
    private let stretchFirst: Bool
    /// The rows above the sections have no chevron slot: the label starts at the panel inset with a 96 px column.
    private let top: Bool
    private let height: CGFloat

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height) }

    init(title: String, controls: [NSView], stretchFirst: Bool = true, top: Bool = false, height: CGFloat = ColorGrid.controlRow) {
        label = NSTextField(labelWithString: title)
        self.controls = controls
        self.stretchFirst = stretchFirst
        self.top = top
        self.height = height
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: height))
        label.font = Theme.Typography.body
        label.textColor = Theme.Colors.label2
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        for c in controls { addSubview(c) }
        heightAnchor.constraint(equalToConstant: height).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Board `.btn.ic`: icon-only buttons are 24 wide; everything else keeps its own size.
    private static func size(of c: NSView) -> NSSize {
        var s = c.sqLayoutSize
        if let b = c as? SQButton, b.title.isEmpty { s.width = ColorGrid.iconButton }
        return s
    }

    /// Where the controls start.
    var controlX: CGFloat { top ? ColorGrid.inset + ColorGrid.label - ColorGrid.sectionGap : ColorGrid.controlX }

    override func layout() {
        super.layout()
        let h = bounds.height
        let lx = top ? ColorGrid.inset : ColorGrid.labelX
        let cx = controlX
        let lh = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: lx - ColorGrid.textInset, y: ((h - lh) / 2).rounded(), width: cx - lx - ColorGrid.gap, height: lh)
        let right = bounds.width - ColorGrid.inset
        let fixed = controls.dropFirst().reduce(CGFloat(0)) { $0 + Self.size(of: $1).width + ColorGrid.gap }
        var x = cx
        for (i, c) in controls.enumerated() {
            let s = Self.size(of: c)
            let ch = s.height > 0 ? min(s.height, h) : h
            var w = s.width
            if i == 0, stretchFirst { w = max(right - fixed - cx, 0) }
            else if i == controls.count - 1, c is NSTextField { w = max(right - x, 0) }
            c.frame = NSRect(x: x, y: ((h - ch) / 2).rounded(), width: w, height: ch)
            x += w + ColorGrid.gap
        }
    }
}

/// Section header (design source `.sec`): hairline on top, chevron left, title, enable checkbox right. A click on the
/// line folds the section; the title dims when the section is off.
@MainActor
final class ColorSectionHeader: NSView {
    let chevron = NSImageView()
    let title: NSTextField
    let toggle = SQCheckbox(target: nil, action: nil)
    /// Version 9: what a folded section holds ("Luma", "Off"), quiet, at the right end.
    let summary = NSTextField(labelWithString: "")
    /// Version 9 has no enable box in the header: the switch is in the header's right-click menu (`onMenu`).
    var showsToggle = false { didSet { needsLayout = true } }
    /// A control at the right end (Basic: the white balance picker).
    var accessory: NSView? {
        didSet { oldValue?.removeFromSuperview(); if let accessory { addSubview(accessory) }; needsLayout = true }
    }
    var onToggleOpen: (() -> Void)?
    /// Right-click on the line: the screen point for the section's menu.
    var onMenu: ((NSPoint) -> Void)?
    private(set) var isOpen = true
    private var isOn = true
    private var summaryText = ""

    override var isFlipped: Bool { true }
    static let height = ColorGrid.sectionGap + ColorGrid.section
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }

    init(title text: String) {
        title = NSTextField(labelWithString: text)
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: Self.height))
        chevron.contentTintColor = Theme.Colors.label3
        chevron.imageScaling = .scaleNone
        title.font = Theme.Typography.bodyStrong
        title.textColor = Theme.Colors.label
        title.lineBreakMode = .byTruncatingTail
        toggle.setAccessibilityLabel("Enable \(text)")
        summary.font = Theme.Typography.caption
        summary.textColor = Theme.Colors.label3
        summary.alignment = .right
        summary.lineBreakMode = .byTruncatingTail
        for v in [chevron, title, summary, toggle] as [NSView] { addSubview(v) }
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        setAccessibilityRole(.button)
        setAccessibilityLabel(text)
        setOpen(true)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func layout() {
        super.layout()
        let top = ColorGrid.sectionGap, h = ColorGrid.section
        chevron.frame = NSRect(x: ColorGrid.inset, y: top, width: ColorGrid.chevronGlyph, height: h)
        var right = bounds.width - ColorGrid.inset
        toggle.isHidden = !showsToggle
        if showsToggle {
            let box = toggle.intrinsicContentSize
            right -= Theme.Spacing.xxs + box.width
            toggle.frame = NSRect(x: right, y: top + ((h - box.height) / 2).rounded(), width: box.width, height: box.height)
            right -= ColorGrid.gap
        }
        if let accessory {
            let s = NSSize(width: ColorGrid.iconButton, height: Theme.Metrics.quietButton)
            right -= s.width
            accessory.frame = NSRect(x: right, y: top + ((h - s.height) / 2).rounded(), width: s.width, height: s.height)
            right -= ColorGrid.gap
        }
        let th = ceil(title.intrinsicContentSize.height)
        let tw = min(ceil(title.attributedStringValue.size().width) + 2 * ColorGrid.textInset + 2, max(right - ColorGrid.labelX, 0))
        title.frame = NSRect(x: ColorGrid.labelX - ColorGrid.textInset, y: top + ((h - th) / 2).rounded(), width: tw, height: th)
        let sx = title.frame.maxX + ColorGrid.gap
        let sh = ceil(summary.intrinsicContentSize.height)
        summary.frame = NSRect(x: sx, y: top + ((h - sh) / 2).rounded(), width: max(right - sx, 0), height: sh)
    }

    /// The folded section's text; an off section reads "Off".
    func setSummary(_ text: String) {
        summaryText = text
        applySummary()
    }

    private func applySummary() {
        let s = isOn ? (isOpen ? "" : summaryText) : "Off"
        if summary.stringValue != s { summary.stringValue = s }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let onMenu, let window else { super.rightMouseDown(with: event); return }
        onMenu(window.convertPoint(toScreen: event.locationInWindow))
    }

    func setOpen(_ open: Bool) {
        isOpen = open
        chevron.image = Theme.symbol(open ? .chevronDown : .chevronRight, size: 8)
        setAccessibilityValue(open ? "expanded" : "collapsed")
        applySummary()
    }

    /// Mirrors the section switch; the title dims to `label3` when the section is off.
    func setOn(_ on: Bool) {
        toggle.state = on ? .on : .off
        title.textColor = on ? Theme.Colors.label : Theme.Colors.label3
        isOn = on
        applySummary()
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if bounds.contains(p) && !(showsToggle && toggle.frame.insetBy(dx: -4, dy: -4).contains(p)) { onToggleOpen?() }
    }

    override func accessibilityPerformPress() -> Bool { onToggleOpen?(); return true }
}

/// Group label inside a section (design source `.grp`): 22 high, small caps in `label3`, hairline on top except for
/// the first line of a section. Not collapsible.
@MainActor
final class ColorGroupLabel: NSView {
    let title: String
    var hasRule = true { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: ColorGrid.group) }

    init(title: String) {
        self.title = title
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: ColorGrid.group))
        heightAnchor.constraint(equalToConstant: ColorGrid.group).isActive = true
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func draw(_ dirtyRect: NSRect) {
        if hasRule {
            Theme.Separator.hairline.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: Theme.Separator.width).fill()
        }
        let font = Theme.Typography.captionStrong
        let s = NSAttributedString(string: title.uppercased(), attributes: [
            .font: font, .foregroundColor: Theme.Colors.label3, .kern: font.pointSize * 0.04])
        let h = ceil(s.size().height)
        s.draw(at: NSPoint(x: ColorGrid.inset, y: ((bounds.height - h) / 2).rounded()))
    }
}

/// Rows under a group label ("Color", "Light", "Adjustments", "RGB Curves", "Hue Saturation Curves").
@MainActor
final class ColorGroupView: NSStackView {
    let header: ColorGroupLabel
    let content = NSStackView()

    init(title: String) {
        header = ColorGroupLabel(title: title)
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 0
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 0
        addArrangedSubview(header)
        addArrangedSubview(content)
        header.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        content.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}

/// LUT popup of one effect (Source LUT or Look LUT). `picks` mirrors the menu items.
@MainActor
final class LUTPopup: SQPopup {
    enum Pick { case choice(ColorInspectorModel.LUTChoice?), chooseFile, addToLibrary, inert }
    /// Stars the selected library LUT.
    var star: NSButton?
    /// Amber chip shown when the LUT's name expects another color space.
    var mismatchChip: NSImageView?
    /// Clears the slot (None: the first effect's Input LUT falls back to the built-in conversion).
    var clear: SQButton?
    var effect = 0
    var slot = ColorLUTSlot.input
    var picks: [Pick] = []
}

/// The four curve channel dots (master, red, green, blue): 9 px, 10 px apart, centered (design source `.cdot`).
@MainActor
final class ChannelDots: NSControl {
    var selected = 0 { didSet { if selected != oldValue { needsDisplay = true } } }
    var onSelect: ((Int) -> Void)?
    private static let colors: [NSColor] = Theme.Palette.channelDots
    private static let names = ["Master", "Red", "Green", "Blue"]
    static let d: CGFloat = 9
    static let gap: CGFloat = 10
    /// The dots with room for the selection ring above and below.
    static let height: CGFloat = d + 10

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel("Curve channel")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func rect(_ i: Int) -> NSRect {
        let total = 4 * Self.d + 3 * Self.gap
        let x0 = ((bounds.width - total) / 2).rounded()
        return NSRect(x: x0 + CGFloat(i) * (Self.d + Self.gap), y: 6, width: Self.d, height: Self.d)
    }

    override func draw(_ dirtyRect: NSRect) {
        for i in 0..<4 {
            let r = rect(i)
            Self.colors[i].setFill()
            NSBezierPath(ovalIn: r).fill()
            if i == selected {
                Theme.Colors.label.setStroke()
                let ring = NSBezierPath(ovalIn: r.insetBy(dx: -2.5, dy: -2.5))
                ring.lineWidth = 1
                ring.stroke()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = (0..<4).first(where: { rect($0).insetBy(dx: -Self.gap / 2, dy: -6).contains(p) }) {
            selected = i
            onSelect?(i)
        }
    }

    override func accessibilityValue() -> Any? { Self.names[selected] }
}

/// Thumbnail of a look: the SQRender `LookThumbnail` test picture (sky, skin, six chips, gray ramp) run through the look
/// LUT. A real clip frame would need the source frame at the playhead; this keeps the preview cheap and stable. Shared by
/// the Color inspector look browser and the Library's LUT tiles (one cache, rendered off the main thread, CPU only).
@MainActor
public enum ColorLookPreview {
    /// Rendered thumbnails keyed by path + modification date; least recently used entries are evicted.
    private static var cache: [String: NSImage] = [:]
    private static var order: [String] = []        // oldest first
    static let cacheLimit = 256
    /// Posted on the main actor when background renders added thumbnails; userInfo `paths` lists the LUT paths stored.
    public static let thumbnailsReady = Notification.Name("sq.lutThumbnailsReady")
    private static var pending = Set<String>()
    private static var queue: [(path: String, key: String)] = []
    private static var running = false
    /// Keys whose file could not be read or parsed: never queued again (until `invalidate`), so a broken LUT is tried once.
    private static var failed = Set<String>()
    /// Cache key per path, so a tile configure does not stat the file every time (`invalidate` drops it).
    private static var keys: [String: String] = [:]
    /// Background render attempts per LUT path (tests).
    private(set) static var renderAttempts: [String: Int] = [:]
    /// True while background renders are queued or running (tests).
    static var isIdle: Bool { !running && queue.isEmpty }

    static func cacheKey(_ path: String?) -> String {
        guard let path else { return "" }
        if let k = keys[path] { return k }
        let date = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let k = "\(path)|\(date)"
        keys[path] = k
        return k
    }

    private static func lookup(_ key: String) -> NSImage? {
        guard let hit = cache[key] else { return nil }
        if let i = order.lastIndex(of: key) { order.remove(at: i); order.append(key) }
        return hit
    }

    private static func store(_ img: NSImage, _ key: String) {
        if cache[key] == nil { order.append(key) }
        cache[key] = img
        while order.count > cacheLimit { cache[order.removeFirst()] = nil }
    }

    /// Drops cached thumbnails of this file (after a LUT was removed or replaced).
    static func invalidate(path: String) {
        for k in order where k.hasPrefix(path + "|") { cache[k] = nil }
        order.removeAll { $0.hasPrefix(path + "|") }
        failed = failed.filter { !$0.hasPrefix(path + "|") }
        keys[path] = nil
    }

    /// Synchronous render for the single large preview.
    static func image(forLookPath path: String?) -> NSImage {
        let key = cacheKey(path)
        if let hit = lookup(key) { return hit }
        var lut: CubeLUT?
        if let path, let text = try? String(contentsOfFile: path, encoding: .utf8) { lut = try? CubeLUT.parse(text) }
        let img = render(lut: lut)
        store(img, key)
        return img
    }

    /// Cached thumbnail, or nil while it is still being rendered off the main thread (then `onThumbnailsReady` fires).
    public static func thumbnail(forLookPath path: String) -> NSImage? {
        let key = cacheKey(path)
        if let hit = lookup(key) { return hit }
        guard !failed.contains(key) else { return nil }
        if pending.insert(key).inserted { queue.append((path, key)); startWorker() }
        return nil
    }

    private final class Box: @unchecked Sendable { let image: CGImage?; init(_ i: CGImage?) { image = i } }

    private static func announce(_ paths: [String]) {
        NotificationCenter.default.post(name: thumbnailsReady, object: nil, userInfo: ["paths": paths])
    }

    private static func startWorker() {
        guard !running else { return }
        running = true
        Task { @MainActor in
            var stored: [String] = []
            while !queue.isEmpty {
                let job = queue.removeFirst()
                renderAttempts[job.path, default: 0] += 1
                let box = await Task.detached(priority: .utility) { () -> Box in
                    guard let text = try? String(contentsOfFile: job.path, encoding: .utf8), let lut = try? CubeLUT.parse(text)
                    else { return Box(nil) }
                    return Box(renderCG(lut: lut, width: 200, height: 112))     // 2x pixels: sharp on Retina and in Library tiles
                }.value
                pending.remove(job.key)
                // Only stored thumbnails are announced: a failure is remembered and posts nothing (a post makes the views
                // ask again, which would re-queue a broken file forever).
                guard let cg = box.image else { failed.insert(job.key); continue }
                store(NSImage(cgImage: cg, size: NSSize(width: 100, height: 56)), job.key)
                stored.append(job.path)
                if stored.count == 12 { announce(stored); stored = [] }
            }
            running = false
            if !stored.isEmpty { announce(stored) }
        }
    }

    static func render(lut: CubeLUT?, width: Int = 100, height: Int = 56) -> NSImage {
        NSImage(cgImage: renderCG(lut: lut, width: width, height: height), size: NSSize(width: width, height: height))
    }

    /// C3: the shared procedural test picture (sky, skin, six chips, gray ramp) through the look, CPU only (no GPU time).
    nonisolated static func renderCG(lut: CubeLUT?, width: Int, height: Int) -> CGImage {
        let bytes = LookThumbnail.render(lut: lut, width: width, height: height)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: cs,
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                         decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        return cg
    }
}
