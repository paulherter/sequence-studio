import AppKit
import SQCore

/// Controls > Graphic (audit G7): one row for a graphics clip, its layer count and "Edit in Graphics", which brings the
/// Graphics panel to the front. Under it the basics of the selected shape items (`GraphicItemRows`: Corners, Fill,
/// Outline); everything else of an item is edited in the Graphics panel.
@MainActor
final class GraphicSectionView: NSView {
    var onEdit: (() -> Void)?
    /// The visible rows changed (the item picker row came or went): the section re-measures.
    var onHeightChange: (() -> Void)?
    let itemRows = GraphicItemRows()
    private let stack = NSStackView()
    private let button = SQButton(title: "Edit in Graphics", target: nil, action: nil)
    private lazy var row = InspectorRow(title: "", control: button, controlWidth: 120)
    /// Item picker: Controls shows the one item picked here (Motion, Opacity, effects, keyframes), or the whole graphic.
    let itemPopup = SQPopup(frame: .zero, pullsDown: false)
    private lazy var pickRow = InspectorRow(title: "Layer", control: itemPopup, controlWidth: 160)
    private var pickIDs: [UUID] = []
    private var shownClip: Clip?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        button.target = self
        button.action = #selector(edit)
        button.setAccessibilityLabel("Edit in Graphics")
        itemPopup.font = Theme.Typography.body
        itemPopup.target = self
        itemPopup.action = #selector(itemPicked)
        itemPopup.setAccessibilityLabel("Layer")
        itemPopup.sqToolTip = "Pick a layer of this graphic to edit its Motion, Opacity and effects with keyframes"
        stack.addArrangedSubview(pickRow)
        stack.addArrangedSubview(row)
        ControlsRows.add(itemRows, to: stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.widthAnchor.constraint(equalTo: stack.widthAnchor),
            pickRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            pickRow.heightAnchor.constraint(equalToConstant: Theme.Inspector.rowHeight),
            row.heightAnchor.constraint(equalToConstant: Theme.Inspector.rowHeight),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ clip: Clip) {
        shownClip = clip
        row.title = ClipSectionMode.layerSummary(clip)
        refreshPicker()
        itemRows.refresh()
    }

    /// The popup lists "Whole graphic" and the items front first; its selection follows the shared item selection.
    func refreshPicker() {
        let entries = shownClip?.graphics?.itemPickerEntries ?? []
        let wasHidden = pickRow.isHidden
        pickRow.isHidden = entries.isEmpty
        if wasHidden != pickRow.isHidden { onHeightChange?() }
        pickIDs = entries.map(\.id)
        let titles = ["Whole graphic"] + entries.map(\.name)
        if itemPopup.itemTitles != titles { itemPopup.removeAllItems(); itemPopup.addItems(withTitles: titles) }
        let shown = itemRows.editor.flatMap { e in shownClip?.graphics?.shownItem(selection: e.selectedLayers) }
        itemPopup.selectItem(at: shown.flatMap { pickIDs.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
    }

    @objc private func itemPicked() {
        let i = itemPopup.indexOfSelectedItem
        itemRows.editor?.select(i >= 1 && i <= pickIDs.count ? [pickIDs[i - 1]] : [])
    }

    var title: String { row.title }

    @objc private func edit() { onEdit?() }
}

/// Graphics panel header (audit G7): the clip's name, its layer count and "Save as Template…". 32 pt, `titlebar` fill,
/// hairline below; sits above the layer list while a graphics clip is selected.
@MainActor
final class GraphicsHeaderBar: NSView {
    static let height: CGFloat = 32
    var onSaveTemplate: (() -> Void)?
    private let name = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    let saveButton = SQButton(title: "Save as Template…", target: nil, action: nil)

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        name.font = Theme.Typography.bodyStrong
        name.textColor = Theme.Colors.label
        name.lineBreakMode = .byTruncatingTail
        count.font = Theme.Typography.body
        count.textColor = Theme.Colors.label3
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.setAccessibilityLabel("Save as Template")
        for v in [name, count, saveButton] { addSubview(v) }
        setAccessibilityRole(.group)
        setAccessibilityLabel("Graphic")
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ clip: Clip) {
        if name.stringValue != clip.name { name.stringValue = clip.name; needsLayout = true }
        let c = ClipSectionMode.layerSummary(clip)
        if count.stringValue != c { count.stringValue = c; needsLayout = true }
    }

    var summary: String { "\(name.stringValue) · \(count.stringValue)" }

    override func layout() {
        super.layout()
        let pad = Theme.Spacing.md
        let b = saveButton.fittingSize
        saveButton.frame = NSRect(x: bounds.width - pad - b.width, y: (bounds.height - b.height) / 2, width: b.width, height: b.height)
        let c = count.fittingSize
        let nameW = min(name.fittingSize.width, max(saveButton.frame.minX - pad - Theme.Spacing.sm - c.width - Theme.Spacing.sm, 0))
        name.frame = NSRect(x: pad, y: (bounds.height - c.height) / 2, width: nameW, height: c.height)
        count.frame = NSRect(x: name.frame.maxX + Theme.Spacing.sm, y: (bounds.height - c.height) / 2, width: c.width, height: c.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.Colors.titlebar.setFill(); bounds.fill()
        Theme.Colors.separator.setFill()
        NSRect(x: 0, y: bounds.height - Theme.Separator.width, width: bounds.width, height: Theme.Separator.width).fill()
    }

    @objc private func save() { onSaveTemplate?() }
}
