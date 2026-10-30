import AppKit

/// Slider plus coupled number field (INTERACTION-AUDIT "Slider + field"): an `SQSlider` that fills the width and a
/// `ScrubField` of `fieldWidth` on the right. Both follow the number rules (drag/Shift/Option, double-click reset,
/// Esc cancel, Option + wheel), stay in sync, and report one `onBegin` / `onChange`* / `onEnd` triple per gesture
/// from either part, so the caller makes exactly one undo step.
public final class NumericSlider: NSView {
    public static let fieldWidth: CGFloat = 52

    /// Width of the field and gap to the slider; the dialogs of the board use 72 and 12.
    public var fieldWidth: CGFloat = NumericSlider.fieldWidth { didSet { needsLayout = true } }
    public var gap: CGFloat = Theme.Spacing.sm { didSet { needsLayout = true } }

    /// Inspector rows: the number field sits first, on the grid's value column, and the track fills the rest
    /// (every numeric value of a panel then starts at one x, like the plain number rows).
    public var fieldLeading = false { didSet { if oldValue != fieldLeading { needsLayout = true } } }

    public let slider: SQSlider
    public let field: ScrubField

    public var onBegin: (@MainActor () -> Void)?
    public var onChange: (@MainActor (Double) -> Void)?
    public var onEnd: (@MainActor (Double) -> Void)?

    public var value: Double {
        get { field.value }
        set {
            let v = ScrubMath.clamp(newValue, to: range)
            field.value = v
            slider.doubleValue = v
        }
    }
    public var range: ClosedRange<Double> {
        didSet {
            field.range = range
            slider.minValue = range.lowerBound; slider.maxValue = range.upperBound
            value = field.value
        }
    }
    public var defaultValue: Double? {
        didSet { field.defaultValue = defaultValue; slider.defaultValue = defaultValue }
    }
    /// Field drag step per pixel / arrow step.
    public var step: Double {
        get { field.step }
        set { field.step = newValue }
    }
    public var decimals: Int {
        get { field.decimals }
        set { field.decimals = newValue }
    }
    public var unit: String {
        get { field.unit }
        set { field.unit = newValue; unitLabel.text = newValue; needsLayout = true }
    }
    /// Dialog rule (board `unit(...)` after `fld`): the unit sits right of the field, outside its capsule. A fixed column of
    /// at least `unitColumn` is reserved even for an empty unit, so every slider row of a dialog keeps one field edge.
    public var unitOutside = false {
        didSet {
            guard oldValue != unitOutside else { return }
            field.unitOutside = unitOutside
            if unitOutside { addSubview(unitLabel) } else { unitLabel.removeFromSuperview() }
            needsLayout = true
        }
    }
    /// Narrowest unit column; wide enough for "ms", "dB", "Hz", "s", "%".
    public static let unitColumn: CGFloat = 24
    public let unitLabel = SQUnitLabel("")
    public var isEnabled = true {
        didSet { field.isEnabled = isEnabled; slider.isEnabled = isEnabled; field.needsDisplay = true }
    }

    public init(value: Double, range: ClosedRange<Double>, defaultValue: Double? = nil, step: Double = 1,
                decimals: Int = 0, unit: String = "") {
        self.range = range
        slider = SQSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound)
        field = ScrubField()
        super.init(frame: .zero)
        field.isPlain = true
        field.range = range
        field.value = ScrubMath.clamp(value, to: range)
        field.step = step
        field.decimals = decimals
        field.unit = unit
        unitLabel.text = unit
        self.defaultValue = defaultValue
        field.defaultValue = defaultValue
        slider.defaultValue = defaultValue
        addSubview(slider)
        addSubview(field)
        wire()
    }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }

    private func wire() {
        field.onBegin = { [weak self] in self?.onBegin?() }
        field.onChange = { [weak self] v in
            guard let self else { return }
            slider.doubleValue = v
            onChange?(v)
        }
        field.onEnd = { [weak self] v in
            guard let self else { return }
            slider.doubleValue = v
            onEnd?(v)
        }
        field.onCancel = { [weak self] v in
            guard let self else { return }
            slider.doubleValue = v
            onChange?(v)
            onEnd?(v)
        }
        // K6: the partner follows every drag event; the owner hears the drag at display rate (onChange).
        field.onLiveValue = { [weak self] v in self?.slider.doubleValue = v }
        slider.onLiveValue = { [weak self] v in self?.field.value = v }
        slider.onBegin = { [weak self] in self?.onBegin?() }
        slider.onChange = { [weak self] v in
            guard let self else { return }
            field.value = v
            onChange?(v)
        }
        slider.onEnd = { [weak self] v in
            guard let self else { return }
            field.value = v
            onEnd?(v)
        }
    }

    public override var isFlipped: Bool { true }
    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Theme.Row.control) }

    public override func layout() {
        super.layout()
        let h = Theme.Row.control
        let y = ((bounds.height - h) / 2).rounded()
        let fw = min(fieldWidth, bounds.width)
        if fieldLeading {
            field.frame = NSRect(x: 0, y: y, width: fw, height: h)
            let x = fw + gap
            slider.frame = NSRect(x: x, y: y, width: max(bounds.width - x, 0), height: h)
            return
        }
        var right = bounds.width
        if unitOutside {
            let uw = max(Self.unitColumn, SQUnitLabel.width(of: unit))
            let size = unitLabel.intrinsicContentSize
            unitLabel.frame = NSRect(x: right - uw, y: y + ((h - size.height) / 2).rounded(), width: size.width, height: size.height)
            right -= uw + SQDialogMetrics.controlGap
        }
        field.frame = NSRect(x: max(right - fw, 0), y: y, width: fw, height: h)
        slider.frame = NSRect(x: 0, y: y, width: max(right - fw - gap, 0), height: h)
    }
}
