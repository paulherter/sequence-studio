import AppKit
import SQCore

/// Controls > Graphic, the basics of the selected shape items (text concept B, step 4): Corners (rectangles), Fill
/// (color, opacity) and Outline (color, width) as rows on the Controls grid. They read and write the same Shape effect
/// values as the Graphics panel through the one `GraphicsEditor`, at the playhead, so keys are kept. Hidden while no
/// shape item of the shown clip is selected; a text item's look lives in its text block.
@MainActor
final class GraphicItemRows: NSStackView {
    weak var editor: GraphicsEditor? { didSet { refresh() } }
    var onHeightChange: (() -> Void)?

    let corners = ScrubField()
    private(set) lazy var cornersRow = TextBlockRow(label: "Corners", controls: [corners, ControlsRows.spacer()])
    let fill = AppearanceRow(key: "controls.graphic.fill", title: "Fill", hasCheck: true)
    let outline = AppearanceRow(key: "controls.graphic.outline", title: "Outline", hasCheck: true)
    let textBox = TextBoxView()
    private var loaders: [() -> Void] = []

    private static let cornersP = GraphicsEditor.Property.shape(ClipEffect.shapeCornerRadiusKey)

    init() {
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 0
        translatesAutoresizingMaskIntoConstraints = false
        for r in [textBox, cornersRow, fill, outline] as [NSView] { ControlsRows.add(r, to: self) }
        textBox.isHidden = true
        // The same text box as the Graphics panel's Text section: it edits the selected text layer's string in place.
        textBox.onBegin = { [weak self] in self?.editor?.beginGesture() }
        textBox.onChange = { [weak self] s in self?.editor?.updateText("Edit Text") { $0.text = s } }

        corners.unit = "px"
        corners.decimals = 0
        corners.isPlain = true
        corners.range = 0...Double.greatestFiniteMagnitude
        corners.defaultValue = EffectCatalog.param(ClipEffect.shapeEffectKind, ClipEffect.shapeCornerRadiusKey)?.defaultValue
        corners.setAccessibilityLabel("Corners")
        corners.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            corners.widthAnchor.constraint(equalToConstant: ControlsGrid.valueWidth),
            corners.heightAnchor.constraint(equalToConstant: ControlsGrid.controlHeight),
        ])
        corners.onBegin = { [weak self] in self?.editor?.beginGesture() }
        corners.onChange = { [weak self] v in self?.editor?.setValue(Self.cornersP, max(v, 0)) }

        // Nothing to open: color and the one value are on the row. The wiring is the Graphics panel's.
        for row in [fill, outline] { row.head.chevron.isHidden = true }
        loaders = [GraphicAppearanceBinding.bindFill(fill, editor: { [weak self] in self?.editor }),
                   GraphicAppearanceBinding.bindOutline(outline, editor: { [weak self] in self?.editor })]
        refresh()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// The selected items the rows edit: shape and path items of the shown clip (none while a text item is among them).
    /// One picked item shows as its own clip, so its Shape section carries these values: the rows are for several items.
    var shownLayers: [GraphicsLayer] {
        guard let e = editor else { return [] }
        return Self.rowLayers(e.targetLayers)
    }

    static func rowLayers(_ layers: [GraphicsLayer]) -> [GraphicsLayer] { GraphicsPanelLogic.itemRowLayers(layers) }

    /// Lines, arrows and open paths have no fill.
    static func isLineLike(_ l: GraphicsLayer) -> Bool { GraphicsPanelLogic.isLineLike(l) }

    /// Shows the rows the selection has and loads their values at the playhead.
    func refresh() {
        let layers = shownLayers
        let text = editor?.textTemplate
        let before = [isHidden, cornersRow.isHidden, fill.isHidden, textBox.isHidden]
        textBox.isHidden = text == nil
        if let text, textBox.string != text.text { textBox.setString(text.text) }      // ignored while the user types
        isHidden = layers.isEmpty && text == nil
        cornersRow.isHidden = !GraphicsPanelLogic.allRectangles(layers)
        fill.isHidden = layers.allSatisfy(Self.isLineLike)
        if before != [isHidden, cornersRow.isHidden, fill.isHidden, textBox.isHidden] { onHeightChange?() }
        guard let e = editor, !layers.isEmpty else { return }
        if !corners.isEditing && !corners.isDragging {
            let v = e.value(Self.cornersP)
            if let v { corners.value = v }
            corners.isMixed = v == nil
        }
        for load in loaders { load() }
    }
}
