import AppKit
import SQCore
import SQUIKit

/// Building blocks of the Pro Step tabs (version 9 `color.html`: `.frm`, `.tsub`, `.chips`, `.rrow`).

/// Version 9 `.frm`: a row of controls from the panel inset, 8 pt apart; the first one stretches when asked.
@MainActor
final class ColorFormRow: NSView {
    private let controls: [NSView]
    private let stretchFirst: Bool

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: ColorGrid.controlRow) }

    init(controls: [NSView], stretchFirst: Bool = false) {
        self.controls = controls
        self.stretchFirst = stretchFirst
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: ColorGrid.controlRow))
        for c in controls { addSubview(c) }
        heightAnchor.constraint(equalToConstant: ColorGrid.controlRow).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func layout() {
        super.layout()
        let h = bounds.height
        let right = bounds.width - ColorGrid.inset
        let fixed = controls.dropFirst().reduce(CGFloat(0)) { $0 + $1.sqLayoutSize.width + ColorGrid.gap }
        var x = ColorGrid.inset
        for (i, c) in controls.enumerated() {
            let s = c.sqLayoutSize
            let ch = s.height > 0 ? min(s.height, h) : h
            let w = i == 0 && stretchFirst ? max(right - fixed - x, 0) : s.width
            c.frame = NSRect(x: x, y: ((h - ch) / 2).rounded(), width: w, height: ch)
            x += w + ColorGrid.gap
        }
    }
}

/// Version 9 `.tsub`: a quiet caption under a tab's controls; wraps to the panel width.
@MainActor
final class ColorFootnote: NSView {
    private let label: NSTextField
    private var wrapped: CGFloat = 0

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: wrapped) }

    init(_ text: String) {
        label = NSTextField(wrappingLabelWithString: text)
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 40))
        label.font = Theme.Typography.caption
        label.textColor = Theme.Colors.label3
        label.isSelectable = false
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func layout() {
        super.layout()
        let w = max(bounds.width - 2 * ColorGrid.inset, 0)
        let h = ceil(label.sizeThatFits(NSSize(width: w, height: .greatestFiniteMagnitude)).height)
        label.frame = NSRect(x: ColorGrid.inset, y: Theme.Spacing.sm, width: w, height: h)
        let total = h + Theme.Spacing.sm + Theme.Spacing.sm
        if total != wrapped { wrapped = total; invalidateIntrinsicContentSize() }
    }
}

/// Version 9 `.chips.tight`: a few choices as quiet pills, the selected one filled (-1 = none).
@MainActor
final class ColorChips: NSControl {
    var selected = 0 { didSet { if selected != oldValue { needsDisplay = true } } }
    var onSelect: ((Int) -> Void)?
    private let titles: [String]
    private static let padding = Theme.Spacing.sm + Theme.Spacing.xxs
    private static let gap = Theme.Spacing.xxs
    private static let height = Theme.Metrics.quietButton

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: rects().last.map(\.maxX) ?? 0, height: Self.height) }

    init(titles: [String], label: String) {
        self.titles = titles
        super.init(frame: .zero)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel(label)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func attributed(_ i: Int, selected: Bool) -> NSAttributedString {
        NSAttributedString(string: titles[i], attributes: [
            .font: Theme.Typography.body, .foregroundColor: selected ? Theme.Colors.label : Theme.Colors.label2])
    }

    private func rects() -> [NSRect] {
        var x: CGFloat = 0
        return titles.indices.map { i in
            let w = ceil(attributed(i, selected: false).size().width) + 2 * Self.padding
            defer { x += w + Self.gap }
            return NSRect(x: x, y: 0, width: w, height: Self.height)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        for (i, r) in rects().enumerated() {
            let on = i == selected
            if on {
                Theme.Colors.selection.setFill()
                NSBezierPath(roundedRect: r, xRadius: Theme.Radius.control, yRadius: Theme.Radius.control).fill()
            }
            let s = attributed(i, selected: on)
            let sz = s.size()
            s.draw(at: NSPoint(x: r.minX + ((r.width - sz.width) / 2).rounded(), y: ((r.height - sz.height) / 2).rounded()))
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let p = convert(event.locationInWindow, from: nil)
        if let i = rects().firstIndex(where: { $0.insetBy(dx: -Self.gap / 2, dy: 0).contains(p) }) {
            selected = i
            onSelect?(i)
        }
    }

    override func accessibilityValue() -> Any? { titles.indices.contains(selected) ? titles[selected] : "" }
}

/// Version 9 `.rrow` + `.rng`: a range on a colored track (Hue, Saturation, Luma). A white frame marks the range; drag
/// inside it to move, drag an edge to resize, click outside to center it there. The value reads "low – high".
@MainActor
final class ColorRangeRow: NSView {
    typealias Kind = StepRangeKind

    let kind: Kind
    let label: NSTextField
    private let valueLabel = NSTextField(labelWithString: "")
    private let maximum: Double
    private(set) var low = 0.0
    private(set) var high = 0.0
    private(set) var isActive = true
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?
    /// A new range (already clamped and ordered).
    var onChange: ((Double, Double) -> Void)?

    private enum Drag { case low, high, move(offset: Double, width: Double) }
    private var drag: Drag?

    static let rowHeight: CGFloat = 34
    static let trackHeight: CGFloat = 14
    private static let handle: CGFloat = 4

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.rowHeight) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(kind: Kind, title: String, maximum: Double) {
        self.kind = kind
        self.maximum = maximum
        label = NSTextField(labelWithString: title)
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: Self.rowHeight))
        label.font = Theme.Typography.body
        label.textColor = Theme.Colors.label2
        valueLabel.font = Theme.Typography.caption
        valueLabel.textColor = Theme.Colors.label
        valueLabel.alignment = .right
        addSubview(label)
        addSubview(valueLabel)
        heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
        setAccessibilityRole(.slider)
        setAccessibilityLabel(title)
        show(low: 0, high: maximum)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func show(low: Double, high: Double) {
        guard drag == nil else { return }
        self.low = min(max(low, 0), maximum)
        self.high = min(max(high, self.low), maximum)
        valueLabel.stringValue = "\(Int(self.low.rounded())) \u{2013} \(Int(self.high.rounded()))"
        needsDisplay = true
    }

    func setActive(_ on: Bool) {
        isActive = on
        alphaValue = on ? 1 : Theme.State.disabledAlpha
    }

    private var track: NSRect {
        let right = bounds.width - ColorGrid.inset - ColorGrid.value
        let x = ColorGrid.controlX
        return NSRect(x: x, y: ((bounds.height - Self.trackHeight) / 2).rounded(), width: max(right - x, 1), height: Self.trackHeight)
    }

    override func layout() {
        super.layout()
        let lh = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: ColorGrid.labelX - ColorGrid.textInset, y: ((bounds.height - lh) / 2).rounded(),
                             width: ColorGrid.label - ColorGrid.gap, height: lh)
        let vh = ceil(valueLabel.intrinsicContentSize.height)
        let x = bounds.width - ColorGrid.inset - ColorGrid.value
        valueLabel.frame = NSRect(x: x, y: ((bounds.height - vh) / 2).rounded(), width: ColorGrid.value, height: vh)
    }

    private func gradient() -> NSGradient {
        let bridge = Theme.ColorBridge.self
        switch kind {
        case .hue:
            let colors = (0...12).map { bridge.hsb(CGFloat($0) / 12, 0.5, 0.62) }
            return NSGradient(colors: colors) ?? NSGradient(starting: colors[0], ending: colors[12])!
        case .saturation:
            return NSGradient(starting: bridge.hsb(0.08, 0, 0.45), ending: bridge.hsb(0.08, 0.8, 0.7))!
        case .luma:
            return NSGradient(starting: bridge.hsb(0, 0, 0.08), ending: bridge.hsb(0, 0, 0.95))!
        }
    }

    private func x(_ v: Double) -> CGFloat { track.minX + CGFloat(v / maximum) * track.width }
    private func value(at x: CGFloat) -> Double { min(max(Double((x - track.minX) / track.width) * maximum, 0), maximum) }

    override func draw(_ dirtyRect: NSRect) {
        let t = track
        let path = NSBezierPath(roundedRect: t, xRadius: Theme.Radius.small, yRadius: Theme.Radius.small)
        gradient().draw(in: path, angle: 0)
        let sel = NSRect(x: x(low), y: t.minY - 3, width: max(x(high) - x(low), 0), height: t.height + 6)
        Theme.Colors.label.setStroke()
        let frame = NSBezierPath(roundedRect: sel, xRadius: Theme.Radius.small, yRadius: Theme.Radius.small)
        frame.lineWidth = 1.5
        frame.stroke()
        Theme.Colors.label.setFill()
        for edge in [sel.minX, sel.maxX] {
            NSBezierPath(roundedRect: NSRect(x: edge - Self.handle / 2, y: t.minY - 4, width: Self.handle, height: t.height + 8),
                         xRadius: Theme.Radius.small, yRadius: Theme.Radius.small).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isActive else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard track.insetBy(dx: -6, dy: -10).contains(p) else { return }
        let edge: CGFloat = 6
        if abs(p.x - x(low)) <= edge, abs(p.x - x(low)) <= abs(p.x - x(high)) { drag = .low }
        else if abs(p.x - x(high)) <= edge { drag = .high }
        else {
            let v = value(at: p.x)
            let w = high - low
            if v >= low, v <= high { drag = .move(offset: v - low, width: w) }
            else { drag = .move(offset: w / 2, width: w) }
        }
        onBegin?()
        apply(p.x)
    }

    override func mouseDragged(with event: NSEvent) {
        guard drag != nil else { return }
        apply(convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) {
        guard drag != nil else { return }
        drag = nil
        onEnd?()
    }

    private func apply(_ px: CGFloat) {
        guard let drag else { return }
        let v = value(at: px)
        var lo = low, hi = high
        switch drag {
        case .low: lo = min(v, high)
        case .high: hi = max(v, low)
        case .move(let offset, let width):
            lo = min(max(v - offset, 0), maximum - width)
            hi = lo + width
        }
        low = lo; high = hi
        valueLabel.stringValue = "\(Int(lo.rounded())) \u{2013} \(Int(hi.rounded()))"
        needsDisplay = true
        onChange?(lo, hi)
    }

    override func accessibilityValue() -> Any? { valueLabel.stringValue }
}

// MARK: Range mapping

extension ColorRangeRow {
    nonisolated static func pair(_ kind: Kind) -> (ColorRangeParam, ColorRangeParam) { StepRangeKind.pair(kind) }
    nonisolated static func bounds(_ kind: Kind, first: Double, second: Double) -> (Double, Double) {
        StepRangeKind.bounds(kind, first: first, second: second)
    }
    nonisolated static func params(_ kind: Kind, low: Double, high: Double) -> [(ColorRangeParam, Float)] {
        StepRangeKind.params(kind, low: low, high: high)
    }
}
