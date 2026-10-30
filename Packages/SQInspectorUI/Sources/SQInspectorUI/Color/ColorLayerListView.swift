import AppKit
import SQCore

/// The layer list at the top of the Pro page: the Steps as rows, topmost layer first. Each row has the eye (Step on / off),
/// the name, a blend popup (Series, Parallel or a Layer mix; the bottom row is the base) and the opacity (the Step's Mix).
/// A drag on the name reorders; the footer holds the In / Out LUT chips and "+", which adds a Layer Step on top.
/// The node graph stays in the Steps panel. No file change: it reads and writes `kind`, `layerMix` and `mix`.
@MainActor
final class ColorLayerListView: NSView {
    struct Item: Equatable {
        var id: UUID
        var label: String
        var enabled: Bool
        var hasLUT: Bool
        var blend: StepBlend
        var mix: Float
        var isBase: Bool
    }

    /// Topmost layer first.
    var items: [Item] = [] { didSet { if oldValue != items { rebuild() } } }
    var selected: UUID? { didSet { if oldValue != selected { needsDisplay = true } } }
    /// Custom wiring: the rows can be read but not re-joined or moved (the Steps graph owns the wires).
    var isEditable = true { didSet { if oldValue != isEditable { rebuild() } } }
    var inLUT: String? { didSet { if oldValue != inLUT { updateChips() } } }
    var outLUT: String? { didSet { if oldValue != outLUT { updateChips() } } }

    var onSelect: ((UUID) -> Void)?
    var onStepMenu: ((UUID, NSPoint) -> Void)?
    var onChip: ((GraphLUTSlot, NSPoint) -> Void)?
    var onAdd: (() -> Void)?
    var onToggle: ((UUID) -> Void)?
    var onBlend: ((UUID, StepBlend) -> Void)?
    var onMix: ((UUID, Float) -> Void)?
    var onMixBegin: (() -> Void)?
    var onMixEnd: (() -> Void)?
    /// Drop of a dragged row: the Step and its new list row (0 = top).
    var onMove: ((UUID, Int) -> Void)?

    static let rowHeight: CGFloat = 28
    static let footerHeight: CGFloat = 36
    private static let popupWidth: CGFloat = 96
    private static let mixWidth: CGFloat = 60
    private static let dragThreshold: CGFloat = 4

    @MainActor private final class RowControls {
        let eye: SQButton
        let blend = SQMenuPopup()
        let mix = ScrubField()
        init(eye: SQButton) { self.eye = eye }
    }
    private var controls: [UUID: RowControls] = [:]
    private lazy var inChip = SQButton(title: "In", target: self, action: #selector(chipPressed(_:)), style: .standard)
    private lazy var outChip = SQButton(title: "Out", target: self, action: #selector(chipPressed(_:)), style: .standard)
    private lazy var addButton = SQButton(symbol: .plus, label: "Add layer", target: self, action: #selector(addPressed), size: 12)

    private var pressed: (id: UUID, y: CGFloat)?
    private var dragRow: (id: UUID, target: Int)?

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: CGFloat(items.count) * Self.rowHeight + Self.footerHeight)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel("Color layers")
        inChip.tag = 0; outChip.tag = 1
        addButton.sqToolTip = "Add a layer on top"
        for v in [inChip, outChip, addButton] as [NSView] { addSubview(v) }
        updateChips()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: Rows

    static func title(_ b: StepBlend) -> String {
        switch b {
        case .series: "Series"
        case .parallel: "Parallel"
        case .layer(.normal): "Layer"
        case .layer(let m): m.rawValue.prefix(1).uppercased() + m.rawValue.dropFirst()
        }
    }

    /// The popup entries of one row.
    func blendItems(for item: Item) -> [SQMenuItem] {
        StepBlend.all.map { b in
            SQMenuItem(title: Self.title(b), isChecked: b == item.blend) { [weak self] in self?.onBlend?(item.id, b) }
        }
    }

    /// The popup of a row (nil for an unknown Step).
    func blendPopup(_ id: UUID) -> SQMenuPopup? { controls[id]?.blend }
    func mixField(_ id: UUID) -> ScrubField? { controls[id]?.mix }

    private func rebuild() {
        let ids = Set(items.map(\.id))
        for (id, c) in controls where !ids.contains(id) {
            c.eye.removeFromSuperview(); c.blend.removeFromSuperview(); c.mix.removeFromSuperview()
            controls[id] = nil
        }
        for item in items {
            let c = controls[item.id] ?? makeControls(item.id)
            c.eye.image = Theme.symbol(item.enabled ? .eye : .eyeOff, size: 12, label: item.enabled ? "Layer on" : "Layer off")
            c.blend.title = Self.title(item.blend)
            c.blend.isEnabled = isEditable && !item.isBase
            c.blend.isHidden = item.isBase
            if !c.mix.isDragging && !c.mix.isEditing { c.mix.value = Double(item.mix) }
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
        needsDisplay = true
    }

    private func makeControls(_ id: UUID) -> RowControls {
        let eye = SQButton(symbol: .eye, label: "Layer on", target: self, action: #selector(eyePressed(_:)), size: 12)
        eye.contentTintColor = Theme.Colors.label2
        let c = RowControls(eye: eye)
        c.blend.itemsProvider = { [weak self] in
            guard let self, let item = self.items.first(where: { $0.id == id }) else { return [] }
            return self.blendItems(for: item)
        }
        c.blend.setAccessibilityLabel("Blend")
        c.mix.range = 0...100
        c.mix.unit = "%"
        c.mix.defaultValue = 100
        c.mix.setAccessibilityLabel("Opacity")
        c.mix.onBegin = { [weak self] in self?.onMixBegin?() }
        c.mix.onChange = { [weak self] v in self?.onMix?(id, Float(v)) }
        c.mix.onEnd = { [weak self] _ in self?.onMixEnd?() }
        for v in [eye, c.blend, c.mix] as [NSView] { addSubview(v) }
        controls[id] = c
        return c
    }

    private func updateChips() {
        inChip.sqToolTip = SQL10n.format("In LUT: %@", SQL10n.string(inLUT ?? "None (built-in conversion)"))
        outChip.sqToolTip = SQL10n.format("Out LUT: %@", SQL10n.string(outLUT ?? "None"))
        inChip.contentTintColor = inLUT != nil ? Theme.Colors.accent : nil
        outChip.contentTintColor = outLUT != nil ? Theme.Colors.accent : nil
    }

    func rowRect(_ i: Int) -> NSRect { NSRect(x: 0, y: CGFloat(i) * Self.rowHeight, width: bounds.width, height: Self.rowHeight) }

    /// Where the name is drawn and dragged: between the eye and the blend popup.
    private func labelRect(_ i: Int) -> NSRect {
        let r = rowRect(i), inset = ColorGrid.inset, q = Theme.Metrics.capsule
        let x = inset + q + Theme.Spacing.sm
        let right = r.maxX - inset - Self.mixWidth - Theme.Spacing.sm - Self.popupWidth - Theme.Spacing.sm
        return NSRect(x: x, y: r.minY, width: max(0, right - x), height: r.height)
    }

    override func layout() {
        super.layout()
        let inset = ColorGrid.inset, q = Theme.Metrics.capsule
        for (i, item) in items.enumerated() {
            guard let c = controls[item.id] else { continue }
            let r = rowRect(i)
            let y = r.minY + ((r.height - q) / 2).rounded()
            c.eye.frame = NSRect(x: inset, y: y, width: q, height: q)
            c.mix.frame = NSRect(x: r.maxX - inset - Self.mixWidth, y: y, width: Self.mixWidth, height: q)
            c.blend.frame = NSRect(x: c.mix.frame.minX - Theme.Spacing.sm - Self.popupWidth, y: y, width: Self.popupWidth, height: q)
        }
        let fy = CGFloat(items.count) * Self.rowHeight + ((Self.footerHeight - q) / 2).rounded()
        let inW = max(inChip.intrinsicContentSize.width, q), outW = max(outChip.intrinsicContentSize.width, q)
        inChip.frame = NSRect(x: inset, y: fy, width: inW, height: q)
        outChip.frame = NSRect(x: bounds.width - inset - outW, y: fy, width: outW, height: q)
        addButton.frame = NSRect(x: (bounds.midX - q / 2).rounded(), y: fy, width: q, height: q)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        for (i, item) in items.enumerated() {
            let r = rowRect(i)
            if item.id == selected {
                Theme.Colors.selection.setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: Theme.Spacing.xs, dy: 1), xRadius: Theme.Radius.control, yRadius: Theme.Radius.control).fill()
            }
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            let a = NSAttributedString(string: item.label, attributes: [
                .font: Theme.Typography.body,
                .foregroundColor: item.enabled ? Theme.Colors.label : Theme.Colors.label3,
                .paragraphStyle: style,
            ])
            let l = labelRect(i), h = ceil(a.size().height)
            a.draw(with: NSRect(x: l.minX, y: (l.midY - h / 2).rounded(), width: l.width, height: h), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            if item.hasLUT {
                Theme.Colors.accent.setFill()
                let d = Theme.Spacing.xs
                NSBezierPath(ovalIn: NSRect(x: min(l.maxX - d, l.minX + a.size().width + d), y: l.midY - d / 2, width: d, height: d)).fill()
            }
        }
        if let d = dragRow {
            Theme.Colors.accent.setFill()
            let from = items.firstIndex { $0.id == d.id } ?? 0
            let y = CGFloat(d.target) * Self.rowHeight + (d.target > from ? Self.rowHeight : 0)
            NSRect(x: ColorGrid.inset, y: y - 1, width: bounds.width - 2 * ColorGrid.inset, height: 2).fill()
        }
        Theme.Colors.separator.setFill()
        NSRect(x: 0, y: CGFloat(items.count) * Self.rowHeight, width: bounds.width, height: Theme.Separator.width).fill()
    }

    // MARK: Actions

    private func id(of sender: NSView) -> UUID? { controls.first { $0.value.eye === sender }?.key }
    @objc private func eyePressed(_ b: SQButton) { if let id = id(of: b) { onToggle?(id) } }
    @objc private func addPressed() { onAdd?() }
    @objc private func chipPressed(_ b: SQButton) {
        guard let w = b.window else { return }
        onChip?(b.tag == 0 ? .input : .output, w.convertPoint(toScreen: b.convert(NSPoint(x: 0, y: b.bounds.maxY), to: nil)))
    }

    // MARK: Mouse (the name area: select, drag to reorder, secondary click for the Step menu)

    func row(at p: NSPoint) -> Int? {
        let i = Int(floor(p.y / Self.rowHeight))
        return items.indices.contains(i) ? i : nil
    }

    private func screenPoint(_ e: NSEvent) -> NSPoint { window?.convertPoint(toScreen: e.locationInWindow) ?? e.locationInWindow }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if e.modifierFlags.contains(.control) { rightMouseDown(with: e); return }
        guard let i = row(at: p) else { return }
        onSelect?(items[i].id)
        pressed = (items[i].id, p.y)
    }

    override func mouseDragged(with e: NSEvent) {
        guard isEditable, let pressed else { return }
        let p = convert(e.locationInWindow, from: nil)
        guard dragRow != nil || abs(p.y - pressed.y) > Self.dragThreshold else { return }
        let target = min(max(Int(floor(p.y / Self.rowHeight)), 0), items.count - 1)
        dragRow = (pressed.id, target)
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        defer { pressed = nil; dragRow = nil; needsDisplay = true }
        guard let d = dragRow, items.firstIndex(where: { $0.id == d.id }) != d.target else { return }
        onMove?(d.id, d.target)
    }

    override func rightMouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        guard let i = row(at: p) else { return }
        onSelect?(items[i].id)
        onStepMenu?(items[i].id, screenPoint(e))
    }
}
