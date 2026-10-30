import AppKit

/// The one list selection style (INTERACTION-AUDIT §4, DECISIONS "Interaction rules"): a flat, full-width neutral fill,
/// no rounded pill, no system highlight. `Theme.Selection.fill` normally, `fillFocused` while the table has keyboard
/// focus (AppKit's "emphasized"); optional hover with `Theme.Selection.hover`. Return it from every NSTableView /
/// NSOutlineView `rowViewForRow` / `rowViewForItem`.
public final class FlatSelectionRowView: NSTableRowView {
    /// Hover fill on unselected rows (off by default: lists that open on single click turn it on).
    public var showsHover = false { didSet { updateTrackingAreas(); needsDisplay = true } }
    private var hovering = false { didSet { if oldValue != hovering { needsDisplay = true } } }
    private var hoverArea: NSTrackingArea?
    private var focused = false

    // AppKit sets this when the table becomes / stops being first responder in the key window.
    public override var isEmphasized: Bool {
        get { focused }
        set { if focused != newValue { focused = newValue; needsDisplay = true } }
    }

    /// Selection color for the focus state.
    public func selectionFill(focused: Bool) -> NSColor { focused ? Theme.Selection.fillFocused : Theme.Selection.fill }

    public override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        selectionFill(focused: focused).setFill()
        bounds.fill()
    }

    public override func drawBackground(in dirtyRect: NSRect) {
        guard showsHover, hovering, !isSelected else { return }
        Theme.Selection.hover.setFill()
        bounds.fill()
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        hoverArea = nil
        guard showsHover else { return }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        hoverArea = a
    }
    public override func mouseEntered(with event: NSEvent) { hovering = true }
    public override func mouseExited(with event: NSEvent) { hovering = false }

    /// Scrolling under a resting pointer sends no mouseExited: the pointer is re-read on every scroll step and on reuse.
    private lazy var hoverSync = ScrollHoverSync(view: self) { [weak self] p in self?.hovering = p != nil }
    public override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); hoverSync.attach(); hoverSync.refresh() }
    public override func prepareForReuse() { super.prepareForReuse(); hovering = false; hoverSync.refresh() }
    /// Tests: apply a pointer position (window coordinates) as the scroll refresh would.
    public func syncHover(atWindowPoint p: NSPoint) { hovering = ScrollHoverSync.pointer(over: self, atWindowPoint: p) != nil }
    public var isHovered: Bool { hovering }
}
