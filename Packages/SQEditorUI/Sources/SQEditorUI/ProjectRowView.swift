import AppKit
import SQCore

/// Row of the Project list: plain row background (every second row striped), selected = the shared selection fill,
/// hover = faint lift. The item's label color lives only in the small box behind the type icon (`ProjectIconBox`).
@MainActor
final class ProjectRowView: NSTableRowView {
    var isStripe = false { didSet { needsDisplay = true } }
    private var hovered = false { didSet { if oldValue != hovered { needsDisplay = true } } }
    private var focused = false

    override var isEmphasized: Bool {
        get { focused }
        set { if focused != newValue { focused = newValue; needsDisplay = true } }
    }

    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(a); tracking = a
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    /// Scrolling under a resting pointer sends no mouseExited: the pointer is re-read on every scroll step and on reuse.
    private lazy var hoverSync = ScrollHoverSync(view: self) { [weak self] p in self?.hovered = p != nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); hoverSync.attach(); hoverSync.refresh() }
    override func prepareForReuse() { super.prepareForReuse(); hovered = false; hoverSync.refresh() }
    /// Tests: apply a pointer position (window coordinates) as the scroll refresh would.
    func syncHover(atWindowPoint p: NSPoint) { hovered = ScrollHoverSync.pointer(over: self, atWindowPoint: p) != nil }
    var isHovered: Bool { hovered }

    override func drawBackground(in dirtyRect: NSRect) {
        if isStripe { Theme.Colors.rowAlt.setFill(); bounds.fill() }
        if hovered && !isSelected { Theme.Selection.hover.setFill(); bounds.fill() }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        (focused ? Theme.Selection.fillFocused : Theme.Selection.fill).setFill(); bounds.fill()
    }
}

/// The type icon of a list row in a small rounded box of the item's label color (the timeline clip fill); the glyph takes
/// `LabelColor.onFill` (white or black by contrast). Without a label it draws the plain tinted icon.
@MainActor
final class ProjectIconBox: NSImageView {
    static let size = NSSize(width: 20, height: 16)
    var label: LabelColor? { didSet { if oldValue != label { needsDisplay = true } } }
    /// Kind chip (decision 2026-10-11): a 16 pt rounded chip in the item's color (two halves for video with audio) with the
    /// kind's `SQIcon` inside in the contrasting `onFill`, so the kind reads without the color.
    static let chipSize: CGFloat = 16
    static let glyphSize: CGFloat = 11
    struct Chip: Equatable {
        var fills: [NSColor]
        var glyph: SQIcon
        var glyphColor: NSColor
    }
    var chip: Chip? { didSet { if oldValue != chip { needsDisplay = true } } }
    override var intrinsicContentSize: NSSize { Self.size }
    override func draw(_ dirtyRect: NSRect) {
        if let chip, !chip.fills.isEmpty {
            let r = NSRect(x: bounds.minX, y: (bounds.midY - Self.chipSize / 2).rounded(), width: Self.chipSize, height: Self.chipSize)
            let path = NSBezierPath(roundedRect: r, xRadius: Theme.Radius.small, yRadius: Theme.Radius.small)
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            let w = r.width / CGFloat(chip.fills.count)
            for (i, c) in chip.fills.enumerated() {
                c.setFill()
                NSRect(x: r.minX + CGFloat(i) * w, y: r.minY, width: w, height: r.height).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            let g = chip.glyph.image(size: Self.glyphSize, color: chip.glyphColor, stroke: 1.6)
            g.draw(in: NSRect(x: r.midX - Self.glyphSize / 2, y: r.midY - Self.glyphSize / 2, width: Self.glyphSize, height: Self.glyphSize))
            return
        }
        if let label {
            label.fill.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: Theme.Radius.small, yRadius: Theme.Radius.small).fill()
        }
        super.draw(dirtyRect)
    }
}
