import AppKit
import SQCore
import SQUIKit

/// v87 Color range mask, line 1: "Color" (the picked color), Inverted and delete. A drag in the color panel is one undo step:
/// it ends when the well deactivates, the row goes away, or after 2 s without a change.
final class ColorRangeMaskRow: RowBackground, RowUpdating, ControlsRowProbing {
    let maskID: ClipMask.ID
    let model: EffectControlsModel
    private let label = makeLabel("Color")
    private let well = SQColorWell()
    private let invert = SQCheckbox(title: "Inverted", target: nil, action: nil)
    private var remove: IconButton!
    private var gesturing = false
    private var idleTimer: Timer?

    var rowProbe: ControlsRowProbe {
        ControlsRowProbe(label: label.frame, controls: [well.frame, invert.frame], tail: remove.frame)
    }

    init(maskID: ClipMask.ID, model: EffectControlsModel) {
        self.maskID = maskID; self.model = model
        super.init(frame: .zero)
        well.target = self; well.action = #selector(colorChanged)
        well.onClose = { [weak self] in self?.finishGesture() }
        well.setAccessibilityLabel("Mask Color")
        well.sqToolTip = Tooltip.text("The color the mask keeps", shortcut: nil)
        invert.font = Theme.Typography.body
        invert.controlSize = .small
        invert.target = self; invert.action = #selector(inverted)
        invert.sqToolTip = Tooltip.text("Keep everything except this color", shortcut: nil)
        invert.setAccessibilityLabel("Invert Color Range Mask")
        remove = IconButton(symbol: .trash, label: "Delete Mask") { [weak model] in model?.removeMask(maskID) }
        for v in [label, well, invert, remove!] as [NSView] { addSubview(v) }
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let grid = ControlsGrid(width: bounds.width), h = bounds.height
        grid.place(label, height: h)
        remove.frame = grid.controlFrame(x: grid.resetX, width: ControlsGrid.resetWidth, height: h)
        well.frame = grid.controlFrame(x: ControlsGrid.valueX, width: 44, height: h)
        let x = well.frame.maxX + ControlsGrid.gap
        invert.frame = grid.controlFrame(x: x, width: max(remove.frame.minX - ControlsGrid.gap - x, 0), height: h)
    }

    @objc private func colorChanged() {
        guard let c = Theme.ColorBridge.effectColor(well.color, alpha: 1)?.clamped, let key = model.colorRange(of: maskID) else { return }
        if !gesturing { model.beginGesture(); gesturing = true }
        model.setMaskColorRange(maskID, ColorRangeKey(red: c.red, green: c.green, blue: c.blue,
                                                      tolerance: key.tolerance, softness: key.softness))
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishGesture() }
        }
    }

    private func finishGesture() {
        idleTimer?.invalidate(); idleTimer = nil
        guard gesturing else { return }
        gesturing = false
        model.endGesture()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { finishGesture() }
        super.viewWillMove(toWindow: newWindow)
    }

    @objc private func inverted() { model.setMaskInverted(maskID, invert.state == .on) }

    func update() {
        guard let m = model.clip?.mask(maskID) else { return }
        setAccessibilityLabel(m.name)
        let k = m.colorRange
        let cur = well.color.usingColorSpace(.sRGB)
        let same = cur.map { abs($0.redComponent - k.red) < 1e-3 && abs($0.greenComponent - k.green) < 1e-3
            && abs($0.blueComponent - k.blue) < 1e-3 } ?? false
        if !same { well.color = Theme.ColorBridge.srgb(k.red, k.green, k.blue) }
        invert.state = m.inverted ? .on : .off
        let on = model.isBlendGroupEnabled && m.enabled
        well.isEnabled = on; invert.isEnabled = on
    }
}

/// v87 Color range mask: the Tolerance or Softness line (a percent scrub field; a drag is one undo step).
final class ColorRangeAmountRow: RowBackground, RowUpdating, ControlsRowProbing {
    let maskID: ClipMask.ID
    let model: EffectControlsModel
    let soft: Bool
    private let label: NSTextField
    private let field = ScrubField(frame: .zero)

    var rowProbe: ControlsRowProbe { ControlsRowProbe(label: label.frame, controls: [field.frame]) }

    init(maskID: ClipMask.ID, soft: Bool, model: EffectControlsModel) {
        self.maskID = maskID; self.soft = soft; self.model = model
        let title = soft ? "Softness" : "Tolerance"
        label = makeLabel(title)
        super.init(frame: .zero)
        field.range = 0...100; field.step = 1; field.decimals = 0; field.unit = "%"
        field.defaultValue = soft ? ColorRangeKey.default.softness * 100 : ColorRangeKey.default.tolerance * 100
        field.isPlain = true
        field.setAccessibilityLabel(title)
        field.sqToolTip = Tooltip.text(soft ? "How gradually the mask fades out beyond the tolerance"
                                            : "How far from the picked color still counts as the color", shortcut: nil)
        field.onBegin = { [weak model] in model?.beginGesture() }
        field.onChange = { [weak self] v in self?.set(v) }
        field.onEnd = { [weak model] _ in model?.endGesture() }
        addSubview(label); addSubview(field)
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let grid = ControlsGrid(width: bounds.width), h = bounds.height
        grid.place(label, height: h)
        field.frame = grid.valueFrame(0, height: h)
    }

    private func set(_ percent: Double) {
        guard let k = model.colorRange(of: maskID) else { return }
        let v = min(max(percent, 0), 100) / 100
        model.setMaskColorRange(maskID, ColorRangeKey(red: k.red, green: k.green, blue: k.blue,
                                                      tolerance: soft ? k.tolerance : v, softness: soft ? v : k.softness))
    }

    func update() {
        guard let m = model.clip?.mask(maskID) else { return }
        let v = (soft ? m.colorRange.softness : m.colorRange.tolerance) * 100
        if abs(field.value - v) > 1e-9 { field.value = v }
        field.isEnabled = model.isBlendGroupEnabled && m.enabled
    }
}
