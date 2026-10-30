import AppKit
import SQCore
import SQEditorUI

/// Timeline panel content: the header bar (sequence tabs, Snap/Link, zoom) above the timeline, with the tool strip docked
/// beside it (left by default, any edge or floating, Window > Tools).
@MainActor
final class TimelineHostView: NSView {
    let tabs = SequenceTabsView()
    let header = TimelineHeaderBar()
    let timeline: TimelineView
    let dock: ToolStripDockView
    /// False on the Color page: its lower panel has a header of its own (Timeline | Clips), no sequence tabs.
    var showsHeader = true { didSet { if showsHeader != oldValue { header.isHidden = !showsHeader; needsLayout = true } } }

    /// Fast Cut verbs under the header; hidden in Normal sequences and on the Color page.
    let fastCutStrip = FastCutStrip(frame: .zero)
    var showsFastCutStrip = false { didSet { if showsFastCutStrip != oldValue { fastCutStrip.isHidden = !showsFastCutStrip; needsLayout = true } } }

    nonisolated override var isFlipped: Bool { true }

    init(timeline: TimelineView) {
        self.timeline = timeline
        self.dock = ToolStripDockView(content: timeline)
        super.init(frame: .zero)
        addSubview(dock)
        addSubview(header)
        fastCutStrip.isHidden = true
        addSubview(fastCutStrip)
        header.setTabs(tabs)
        header.bind(to: timeline)
        dock.bind(to: timeline)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = showsHeader ? TimelineHeaderBar.height : 0
        let stripShown = showsHeader && showsFastCutStrip
        let stripH = stripShown ? FastCutStrip.height : 0
        dock.topInset = h + stripH
        fastCutStrip.frame = CGRect(x: 0, y: h, width: bounds.width, height: stripH)
        let inset = showsHeader ? dock.headerInsets : (leading: 0, trailing: 0)
        header.frame = CGRect(x: inset.leading, y: 0, width: max(bounds.width - inset.leading - inset.trailing, 0), height: TimelineHeaderBar.height)
        dock.frame = bounds
    }
}

/// Sequence tabs (design v9 `.ptab`): 12 pt medium, 10 pt padding, quiet text; the open one is bright with a 2 pt accent underline.
/// The close mark shows on hover. Drag to reorder. Logic lives in `SequenceTabs` (SQEditorUI); this only draws and reports clicks.
@MainActor
final class SequenceTabsView: NSView {
    static let height = TimelineHeaderBar.height
    static let pillHeight: CGFloat = 24
    static let pillGap: CGFloat = 0
    static let tabFont = Theme.Typography.ns(12, .medium)

    struct Item: Equatable {
        var root: Timeline.ID
        var title: String       // "Main" or "Main > Inner"
        var active: Bool
    }

    /// The Timeline panel has keyboard focus: the active tab's underline is accent, otherwise the quiet `label3`.
    var isPanelFocused = false { didSet { if isPanelFocused != oldValue { needsDisplay = true } } }
    var onSelect: ((Timeline.ID) -> Void)?
    var onClose: ((Timeline.ID) -> Void)?
    var onMove: ((Timeline.ID, Int) -> Void)?
    /// Press on the empty part of the row: the panel's dock drag (move the Timeline panel elsewhere).
    var onBackgroundPress: ((NSEvent) -> Void)?
    private(set) var items: [Item] = []
    private var frames: [(item: Item, tab: CGRect, close: CGRect)] = []

    nonisolated override var isFlipped: Bool { true }

    private var hoverTab: Timeline.ID? { didSet { if hoverTab != oldValue { needsDisplay = true } } }
    private var hoverClose = false { didSet { if hoverClose != oldValue { needsDisplay = true } } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        removeOwnTrackingAreas()
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        layoutTabs()
        let f = frames.first { $0.tab.contains(p) }
        hoverTab = f?.item.root
        hoverClose = items.count > 1 && (f?.close.insetBy(dx: -3, dy: -3).contains(p) ?? false)
        if hoverClose { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
    }
    override func mouseExited(with event: NSEvent) { hoverTab = nil; hoverClose = false }

    func setItems(_ new: [Item]) {
        guard new != items else { return }
        items = new
        needsDisplay = true
    }

    private func layoutTabs() {
        frames = []
        var x: CGFloat = 0
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.tabFont]
        let closeW: CGFloat = 12
        let y = ((bounds.height - Self.pillHeight) / 2).rounded()
        for it in items {
            // The pill always reserves room for the close mark when there is more than one tab, so hover never reflows.
            let extra = items.count > 1 ? closeW + Theme.Spacing.xs : 0
            let w = min(ceil((it.title as NSString).size(withAttributes: attrs).width) + 20 + extra, 240)
            let r = CGRect(x: x, y: y, width: w, height: Self.pillHeight)
            frames.append((it, r, CGRect(x: r.maxX - 8 - closeW, y: r.minY + (r.height - closeW) / 2, width: closeW, height: closeW)))
            x = r.maxX + Self.pillGap
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        layoutTabs()
        for f in frames {
            if f.item.active {
                // v9 `.ptab.on::after`: 2 pt line, 10 pt in from both sides, at the bottom of the bar.
                PanelActiveMarker.lineColor(active: isPanelFocused).setFill()
                NSBezierPath(roundedRect: CGRect(x: f.tab.minX + 10, y: bounds.height - 3, width: max(f.tab.width - 20, 0), height: 2),
                             xRadius: Theme.Radius.small / 4, yRadius: Theme.Radius.small / 4).fill()
            }
            let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingHead
            let attrs: [NSAttributedString.Key: Any] = [
                .font: Self.tabFont,
                .foregroundColor: f.item.active ? Theme.Colors.label : (f.item.root == hoverTab ? Theme.Colors.label2 : Theme.Colors.label3),
                .paragraphStyle: para]
            let reserve: CGFloat = items.count > 1 ? 12 + Theme.Spacing.xs : 0
            let text = CGRect(x: f.tab.minX + 10, y: f.tab.minY + ((f.tab.height - 15) / 2).rounded(),
                              width: f.tab.width - 20 - reserve, height: 15)
            (f.item.title as NSString).draw(in: text, withAttributes: attrs)
            if items.count > 1, f.item.root == hoverTab {
                let c = f.close.insetBy(dx: 3.5, dy: 3.5)
                (hoverClose ? Theme.Colors.label : Theme.Colors.label3).setStroke()
                let x = NSBezierPath()
                x.move(to: c.origin); x.line(to: CGPoint(x: c.maxX, y: c.maxY))
                x.move(to: CGPoint(x: c.maxX, y: c.minY)); x.line(to: CGPoint(x: c.minX, y: c.maxY))
                x.lineWidth = 1
                x.stroke()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        layoutTabs()
        guard let f = frames.first(where: { $0.tab.contains(p) }) else { onBackgroundPress?(event); return }
        if items.count > 1, f.item.root == hoverTab, f.close.insetBy(dx: -3, dy: -3).contains(p) { onClose?(f.item.root); return }
        onSelect?(f.item.root)
        // Drag to reorder: the tab follows the pointer over its neighbors' centers.
        var index = items.firstIndex { $0.root == f.item.root } ?? 0
        while let e = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), e.type == .leftMouseDragged {
            let x = convert(e.locationInWindow, from: nil).x
            layoutTabs()
            let target = frames.firstIndex { x < $0.tab.midX } ?? frames.count - 1
            if target != index { onMove?(f.item.root, target); index = target }
        }
    }
}
