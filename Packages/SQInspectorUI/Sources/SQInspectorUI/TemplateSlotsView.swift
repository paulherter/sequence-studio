import AppKit
import SQCore

/// The Template section of Effect Controls (TEMPLATE-ECOSYSTEM T3): the editable slots of an applied title template
/// (text, color, font, number) and its animation zones. A slot edit goes to the host as `(slot, value, continuesGesture)`
/// so a drag or typing is one undo step. Built from SQ components only.
@MainActor
public final class TemplateSlotsView: NSView, NSTextFieldDelegate {
    /// A slot value changed. `continuesGesture`: false on the first change of a drag or typing run.
    public var onSlotChange: ((TemplateSlot.ID, SlotValue, Bool) -> Void)?
    /// The zones checkbox was clicked.
    public var onZonesToggle: ((Bool) -> Void)?
    public var onMiddleChange: ((AnimationZones.Middle) -> Void)?
    /// The height changed (another template clip, zones on or off).
    public var onHeightChange: (() -> Void)?

    private let stack = NSStackView()
    private var shownSlots: [TemplateSlot.ID] = []
    private var controls: [TemplateSlot.ID: NSView] = [:]
    private var gestureOpen: Set<TemplateSlot.ID> = []
    private let zonesBox = SQCheckbox(title: "Keep intro and outro", target: nil, action: nil)
    private let middleLabel = NSTextField(labelWithString: "Middle")
    private let middleControl = SQSegmented(labels: ["Hold", "Stretch"], segmentWidth: 64)
    private var middleRow: NSView?

    public override var isFlipped: Bool { true }

    public init() {
        super.init(frame: .zero)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        zonesBox.target = self; zonesBox.action = #selector(zonesClicked)
        zonesBox.sqToolTip = "The first and last moments of the title keep their length when you trim or stretch the clip."
        zonesBox.setAccessibilityLabel("Keep intro and outro when trimmed")
        middleLabel.font = Theme.Typography.body
        middleLabel.textColor = Theme.Colors.label2
        middleControl.setContentHuggingPriority(.required, for: .horizontal)
        middleControl.target = self; middleControl.action = #selector(middleClicked)
        middleControl.setAccessibilityLabel("Middle of the title when the clip length changes")
        setAccessibilityRole(.group)
        setAccessibilityLabel("Template slots")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Shows `slots` and the zones state of the selected template clip. Values update in place without reporting a
    /// change; the rows are rebuilt only when the slot list differs.
    public func show(slots: [TemplateSlot], zones: AnimationZones?) {
        let ids = slots.map(\.id)
        let rebuilt = ids != shownSlots
        if rebuilt { rebuild(slots) }
        for s in slots { update(s) }
        zonesBox.state = zones == nil ? .off : .on
        middleControl.selectedSegment = zones?.middle == .stretch ? 1 : 0
        let showMiddle = zones != nil
        if middleRow?.isHidden == showMiddle { middleRow?.isHidden = !showMiddle; needsLayout = true; onHeightChange?() }
        if rebuilt { needsLayout = true; onHeightChange?() }
    }

    // MARK: Rows

    private func rebuild(_ slots: [TemplateSlot]) {
        for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() }
        controls = [:]; gestureOpen = []
        shownSlots = slots.map(\.id)
        for s in slots {
            let control = makeControl(s)
            controls[s.id] = control
            ControlsRows.add(row(label: s.name, control: control), to: stack)
        }
        zonesBox.removeFromSuperview()
        ControlsRows.add(TextBlockRow(label: nil, controls: [zonesBox, ControlsRows.spacer()]), to: stack)
        middleControl.removeFromSuperview()
        let m = row(label: "Middle", control: middleControl)
        middleRow = m
        ControlsRows.add(m, to: stack)
    }

    /// One row on the Controls grid: text and font slots fill the row, a swatch or a number keeps the grid's value width.
    private func row(label: String, control: NSView) -> NSView {
        if control is SQColorWell || control is ScrubField {
            control.widthAnchor.constraint(equalToConstant: ControlsGrid.valueWidth).isActive = true
            if control is SQColorWell { control.heightAnchor.constraint(equalToConstant: Theme.Row.swatch.height).isActive = true }
        } else if !(control is SQSegmented) {
            ControlsRows.fill(control)
            return TextBlockRow(label: label, controls: [control])
        }
        return TextBlockRow(label: label, controls: [control, ControlsRows.spacer()])
    }

    private func makeControl(_ s: TemplateSlot) -> NSView {
        let id = s.id
        switch s.kind {
        case .text:
            let f = SQTextField(string: "")
            f.delegate = self
            f.identifier = NSUserInterfaceItemIdentifier(id.uuidString)
            f.setAccessibilityLabel(s.name)
            return f
        case .color:
            let w = SQColorWell()
            w.showsAlpha = true
            w.target = self; w.action = #selector(colorChanged(_:))
            w.identifier = NSUserInterfaceItemIdentifier(id.uuidString)
            w.setAccessibilityLabel(s.name)
            w.onClose = { [weak self] in self?.gestureOpen.remove(id) }
            return w
        case .font:
            let f = SQFontField(fontName: "")
            f.setAccessibilityLabel(s.name)
            f.onPreview = { [weak self] name in self?.send(id, .font(name)) }
            f.onCommit = { [weak self] name in self?.send(id, .font(name)); self?.gestureOpen.remove(id) }
            f.onEnd = { [weak self] in self?.gestureOpen.remove(id) }
            return f
        case .number:
            let f = ScrubField()
            f.range = 1...1000
            f.setAccessibilityLabel(s.name)
            f.onBegin = { [weak self] in self?.gestureOpen.remove(id) }
            f.onChange = { [weak self] v in self?.send(id, .number(v)) }
            f.onEnd = { [weak self] v in self?.send(id, .number(v)); self?.gestureOpen.remove(id) }
            return f
        }
    }

    private func update(_ s: TemplateSlot) {
        guard let c = controls[s.id] else { return }
        switch (s.value, c) {
        case let (.text(t), f as SQTextField): if f.stringValue != t, f.currentEditor() == nil { f.stringValue = t }
        case let (.color(r, g, b, a), w as SQColorWell): if !w.isActive { w.color = Self.nsColor(r, g, b, a) }
        case let (.font(n), f as SQFontField): if !f.isEditing, f.fontName != n { f.fontName = n }
        case let (.number(n), f as ScrubField): if !f.isDragging, !f.isEditing, f.value != n { f.value = n }
        default: break
        }
    }

    private static func nsColor(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> NSColor {
        NSColor(colorSpace: .sRGB, components: [CGFloat(r), CGFloat(g), CGFloat(b), CGFloat(a)], count: 4)
    }

    private func send(_ id: TemplateSlot.ID, _ value: SlotValue) {
        let continues = gestureOpen.contains(id)
        gestureOpen.insert(id)
        onSlotChange?(id, value, continues)
    }

    // MARK: Actions

    public func controlTextDidChange(_ obj: Notification) {
        guard let f = obj.object as? SQTextField, let id = f.identifier.flatMap({ UUID(uuidString: $0.rawValue) }) else { return }
        send(id, .text(f.stringValue))
    }

    public func controlTextDidEndEditing(_ obj: Notification) {
        guard let f = obj.object as? SQTextField, let id = f.identifier.flatMap({ UUID(uuidString: $0.rawValue) }) else { return }
        gestureOpen.remove(id)
    }

    @objc private func colorChanged(_ w: SQColorWell) {
        guard let id = w.identifier.flatMap({ UUID(uuidString: $0.rawValue) }),
              let c = w.color.usingColorSpace(.sRGB) else { return }
        send(id, .color(red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent), alpha: Double(c.alphaComponent)))
    }

    @objc private func zonesClicked() { onZonesToggle?(zonesBox.state == .on) }
    @objc private func middleClicked() { onMiddleChange?(middleControl.selectedSegment == 1 ? .stretch : .hold) }
}
