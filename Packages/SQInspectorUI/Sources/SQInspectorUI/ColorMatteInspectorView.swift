import AppKit
import SQCore

/// The Color Matte section of Controls: one Color row. The swatch opens the SQ color picker; every change of the drag
/// goes out live (`onColorChange`) and the host folds one picker session into one undo step. Rows on `ControlsGrid`.
@MainActor
public final class ColorMatteInspectorView: NSView {
    /// A new color, live while the picker is dragged.
    public var onColorChange: ((ColorMatteColor) -> Void)?
    /// A new picker session starts (the next change is a new undo step).
    public var onGestureStart: (() -> Void)?

    let well = SQColorWell(frame: .zero)
    private let hex = NSTextField(labelWithString: "")

    public override var isFlipped: Bool { true }

    public init() {
        super.init(frame: .zero)
        well.setAccessibilityLabel("Color Matte color")
        well.target = self
        well.action = #selector(picked)
        well.onOpen = { [weak self] in self?.onGestureStart?() }
        well.onClose = { [weak self] in self?.onGestureStart?() }
        well.setContentHuggingPriority(.required, for: .horizontal)
        hex.font = Theme.Typography.body
        hex.textColor = Theme.Colors.label2
        hex.lineBreakMode = .byTruncatingTail
        hex.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = ControlsRows.stack([
            TextBlockRow(label: "Color", controls: [well, hex, ControlsRows.spacer()]),
        ])
        addSubview(stack)
        ControlsRows.pin(stack, in: self)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Shows `c` without reporting a change. Ignored while the picker is open: it owns the color then.
    public func show(_ c: ColorMatteColor) {
        hex.stringValue = Self.hexString(c)
        guard !well.isActive else { return }
        well.color = SQColorValue(r: Double(c.r) / 255, g: Double(c.g) / 255, b: Double(c.b) / 255).nsColor
    }

    static func hexString(_ c: ColorMatteColor) -> String {
        String(format: "#%02X%02X%02X", c.r, c.g, c.b)
    }

    static func matteColor(_ color: NSColor) -> ColorMatteColor {
        let v = SQColorValue(color).rgb
        func b(_ x: Double) -> UInt8 { UInt8((min(max(x, 0), 1) * 255).rounded()) }
        return ColorMatteColor(r: b(v.r), g: b(v.g), b: b(v.b))
    }

    @objc private func picked() {
        let c = Self.matteColor(well.color)
        hex.stringValue = Self.hexString(c)
        onColorChange?(c)
    }
}
