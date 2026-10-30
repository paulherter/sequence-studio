import AppKit
import SQEditorUI

/// Panel header (design v9 `.ph`, `.tab`): 30 pt, tabs are plain text (selected = `label` with a 2 pt underline at the
/// header's bottom edge, the others `label3`, no pill), a trailing "..." button, 1 pt separator below.
@MainActor
final class TabStrip: NSView {
    private var buttons: [(PanelID, TabButton)] = []
    private let more = MoreButton()
    private let selectedPanel: PanelID
    var onSelect: ((PanelID) -> Void)?
    /// Context menu of a tab (Close Panel, Maximize Panel); the trailing "..." button opens it for the selected tab.
    var tabMenu: ((PanelID) -> [SQMenuItem])?
    /// A tab was pressed: the owner runs the click-or-drag session (`DockDragSession`).
    var onPress: ((PanelID, NSView, NSEvent) -> Void)?
    /// Header icon buttons of the selected panel (Project: list, icons, new folder; Library: add folder), left of "...".
    var accessories: [NSView] = [] {
        didSet {
            oldValue.forEach { if $0.superview === self { $0.removeFromSuperview() } }
            accessories.forEach(addSubview)
            needsLayout = true
        }
    }
    /// A control after the tabs (the monitors' format / clip popup); keeps its own width, shrinks when the strip is narrow.
    var leading: NSView? {
        didSet {
            if oldValue !== leading, oldValue?.superview === self { oldValue?.removeFromSuperview() }
            if let leading { leading.translatesAutoresizingMaskIntoConstraints = true; addSubview(leading) }
            needsLayout = true
        }
    }
    /// A control at its intrinsic width right before the accessories / "..." (the monitors' zoom badge).
    var trailing: NSView? {
        didSet {
            if oldValue !== trailing, oldValue?.superview === self { oldValue?.removeFromSuperview() }
            if let trailing { trailing.translatesAutoresizingMaskIntoConstraints = true; addSubview(trailing) }
            needsLayout = true
        }
    }
    /// Quiet text after the tabs ("2 uses" in the Color panel header).
    var detail: String? {
        didSet {
            guard detail != oldValue else { return }
            detailLabel.stringValue = detail ?? ""
            needsLayout = true
        }
    }
    /// The selected panel's own options for "..." (view options); nil = the tab menu (Close Panel, Maximize Panel).
    var onMore: ((NSView) -> Void)?
    var hidesMore = false { didSet { needsLayout = true } }
    private let detailLabel = NSTextField(labelWithString: "")

    static let accessoryWidth: CGFloat = 28

    /// Tab frames in strip order, in strip coordinates.
    var tabFrames: [CGRect] { buttons.map { $0.1.frame } }

    static let height = CGFloat(ShellMetrics.panelHeader)

    nonisolated override var isFlipped: Bool { true }

    init(panels: [PanelID], selected: PanelID) {
        selectedPanel = selected
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.panel.cgColor
        for p in panels {
            let b = TabButton(title: EditorCommand.localizedPanelTitle(p))
            b.isSelectedTab = p == selected
            b.target = self
            b.action = #selector(tapped(_:))
            b.identifier = NSUserInterfaceItemIdentifier(p.rawValue)
            b.setAccessibilityLabel(EditorCommand.localizedPanelTitle(p))
            addSubview(b)
            buttons.append((p, b))
        }
        detailLabel.font = Theme.Typography.body
        detailLabel.textColor = Theme.Colors.label3
        detailLabel.lineBreakMode = .byTruncatingTail
        addSubview(detailLabel)
        more.target = self
        more.action = #selector(moreTapped(_:))
        more.setAccessibilityLabel("Panel options")
        addSubview(more)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Starts the click-or-drag session of the first tab from another view (the sequence tab row of a timeline-only group).
    func pressFirstTab(_ event: NSEvent) {
        guard let (p, b) = buttons.first else { return }
        if let onPress { onPress(p, b, event) } else { onSelect?(p) }
    }

    @objc private func tapped(_ sender: TabButton) {
        guard let p = PanelID(rawValue: sender.identifier?.rawValue ?? "") else { return }
        onSelect?(p)
    }

    @objc private func moreTapped(_ sender: NSView) {
        if let onMore { onMore(sender); return }
        guard let items = tabMenu?(selectedPanel), !items.isEmpty else { return }
        SQContextMenu.popUp(items: items, at: NSPoint(x: sender.frame.minX, y: sender.frame.maxY + 2), in: self)
    }

    fileprivate func pressed(_ button: TabButton, _ event: NSEvent) {
        guard let p = PanelID(rawValue: button.identifier?.rawValue ?? "") else { return }
        if let onPress { onPress(p, button, event) } else { onSelect?(p) }
    }

    override func layout() {
        super.layout()
        let h = CGFloat(ShellMetrics.tabHeight)
        let y = ((bounds.height - 1 - h) / 2).rounded()          // centered above the 1 pt separator
        let moreW = more.intrinsicContentSize.width
        more.frame = CGRect(x: bounds.width - Theme.Spacing.sm - moreW, y: y, width: moreW, height: h)
        more.isHidden = hidesMore || (tabMenu == nil && onMore == nil)
        var x = Theme.Spacing.sm - 2
        var limit = more.isHidden ? bounds.width - Theme.Spacing.sm : more.frame.minX
        for a in accessories.reversed() {       // right to left, 2 pt apart, next to "..."
            limit -= Self.accessoryWidth + 2
            a.frame = CGRect(x: limit, y: y, width: Self.accessoryWidth, height: h)
            a.isHidden = limit < Theme.Spacing.sm
        }
        if let trailing {
            var size = trailing.sqLayoutSize        // a stack view (the monitors' Fit / Full pair) has no intrinsic size
            if trailing is NSTextField { size.width = ceil(size.width) + 6 }    // a text meta ("8 items") clipped its last glyph at the exact width
            limit -= size.width + 2
            trailing.frame = CGRect(x: limit, y: ((bounds.height - 1 - size.height) / 2).rounded(), width: size.width, height: size.height)
        }
        for (_, b) in buttons {
            let w = b.intrinsicContentSize.width
            b.isHidden = x + w > limit          // a narrow group shows the tabs that fit
            b.frame = CGRect(x: x, y: y, width: w, height: h)
            if !b.isHidden { x += w + 2 }
        }
        if let leading {
            let lx = x + Theme.Spacing.xs
            let w = min(leading.sqLayoutSize.width, limit - lx - Theme.Spacing.xs)
            leading.isHidden = w < 56
            leading.frame = CGRect(x: lx, y: y, width: max(w, 0), height: h)
            if !leading.isHidden { x = lx + w }
        }
        let dw = ceil(((detail ?? "") as NSString).size(withAttributes: [.font: Theme.Typography.body]).width) + 6   // + the cell's insets
        let dh = ceil(detailLabel.intrinsicContentSize.height)
        // One meta rule for every panel ("8 items", "Color Graph"): quiet text right-aligned next to the header icons, never
        // directly after the tabs, where it read like one more tab.
        let minX = x + Theme.Spacing.md
        let w = min(dw, max(limit - minX - Theme.Spacing.xs, 0))
        detailLabel.isHidden = (detail ?? "").isEmpty || w < 24
        detailLabel.frame = CGRect(x: limit - Theme.Spacing.xs - w, y: ((bounds.height - 1 - dh) / 2).rounded(), width: w, height: dh)
    }

    /// The selected tab's underline (v9 `.tab[aria-selected]::after`): 2 pt, inset by the tab's text padding.
    var underlineFrame: CGRect? {
        guard let b = buttons.first(where: { $0.0 == selectedPanel })?.1, !b.isHidden else { return nil }
        let inset = TabButton.padding
        return CGRect(x: b.frame.minX + inset, y: bounds.height - 2, width: max(b.frame.width - 2 * inset, 0), height: 2)
    }

    /// The panel group has keyboard focus: the selected tab's underline turns accent (v9 `.panel.focus`).
    var isActive = false { didSet { if isActive != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        Theme.Colors.separator.setFill()
        CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        guard let u = underlineFrame else { return }
        PanelActiveMarker.lineColor(active: isActive).setFill()
        let cap = u.height / 2
        NSBezierPath(roundedRect: u, xRadius: cap, yRadius: cap).fill()
    }
}

/// Trailing "..." of a panel header: a 22 pt capsule that fills on hover. A plain view, not a system button.
@MainActor
private final class MoreButton: NSView {
    weak var target: AnyObject?
    var action: Selector?
    private let icon = NSImageView()
    private var hovering = false { didSet { if hovering != oldValue { layer?.backgroundColor = (hovering ? Theme.Colors.fill : NSColor.clear).cgColor } } }
    nonisolated override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        icon.image = Theme.symbol(.ellipsis, size: 12, label: "Panel options")
        icon.contentTintColor = Theme.Colors.label3
        addSubview(icon)
        setAccessibilityRole(.button)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 28, height: CGFloat(ShellMetrics.tabHeight)) }
    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        icon.frame = bounds
    }
    override func accessibilityPerformPress() -> Bool { fire(); return true }
    private func fire() { if let action { NSApp.sendAction(action, to: target, from: self) } }
    override func mouseDown(with event: NSEvent) { fire() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        removeOwnTrackingAreas()
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
}

@MainActor
private final class TabButton: NSButton {
    /// Text padding at each side (v9 `--pad-x-sm`).
    static let padding: CGFloat = 10
    private static var font: NSFont { Theme.Typography.bodyStrong }
    var isSelectedTab = false { didSet { refresh() } }
    private var hovering = false { didSet { if hovering != oldValue { refresh() } } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        removeOwnTrackingAreas()
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        setButtonType(.momentaryChange)
        wantsLayer = true
        focusRingType = .none
        refresh()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        (superview as? TabStrip)?.pressed(self, event)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let strip = superview as? TabStrip, let p = PanelID(rawValue: identifier?.rawValue ?? ""),
              let items = strip.tabMenu?(p), !items.isEmpty else { return super.rightMouseDown(with: event) }
        SQContextMenu.show(items: items, for: event, in: self)
    }

    override var intrinsicContentSize: NSSize {
        let w = (title as NSString).size(withAttributes: [.font: Self.font]).width
        return NSSize(width: ceil(w) + 2 * Self.padding, height: CGFloat(ShellMetrics.tabHeight))
    }

    /// Drawn here, not by the button cell: the cell re-tints an attributed title (every tab came out near white), but the
    /// board has the selected tab at `label` and the others at `label3` (v9 `.tab`). The underline is the strip's.
    override func draw(_ dirtyRect: NSRect) {
        let ts = attributedTitle.size()
        attributedTitle.draw(at: NSPoint(x: ((bounds.width - ts.width) / 2).rounded(), y: ((bounds.height - ts.height) / 2).rounded()))
    }

    private func refresh() {
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: Self.font,
            .foregroundColor: isSelectedTab || hovering ? Theme.Colors.label : Theme.Colors.label3,
        ])
        setAccessibilityValue(isSelectedTab ? "selected" : "")
        needsDisplay = true
    }
}

/// One tab group: strip on top, the selected panel's view below. The panel views are owned by `EditorPanels` and
/// re-parented here on every layout rebuild.
@MainActor
final class PanelContainerView: NSView {
    let panels: [PanelID]
    let selected: PanelID
    let strip: TabStrip
    private let content: NSView
    /// A header of the panel's own instead of the tab strip (the Color page's viewer header above the Program monitor).
    private let header: NSView?
    var collapsesStrip: Bool { panels == [.timeline] }
    private let outline = FocusOutlineView()

    nonisolated override var isFlipped: Bool { true }

    /// The panel that has keyboard focus (kept for key routing; no outline is drawn, see `showsFocusOutline`).
    var isFocused = false {
        didSet {
            guard isFocused != oldValue else { return }
            outline.isHidden = !(isFocused && Self.showsFocusOutline); outline.needsDisplay = true
            strip.isActive = isFocused
            syncSequenceTabsFocus()
            updateActiveLine()
        }
    }
    /// The active mark for a group with no tab strip of its own (Timeline, a panel's own header).
    private let activeLine = ActiveLineView()
    private var headerHeight: CGFloat = 0
    /// The boards show no outline around the focused panel (Main, Color, Panels).
    static let showsFocusOutline = false

    init(panels: [PanelID], selected: PanelID, content: NSView, header: NSView? = nil, onSelect: @escaping (PanelID) -> Void) {
        self.panels = panels; self.selected = selected; self.content = content; self.header = header
        strip = TabStrip(panels: panels, selected: selected)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.panel.cgColor
        layer?.masksToBounds = true          // a panel can never draw over its neighbors
        layer?.cornerRadius = Theme.Radius.panel      // design B: panels are 3 pt cards on the `divider` surface
        strip.onSelect = onSelect
        addSubview(strip)
        content.removeFromSuperview()
        content.autoresizingMask = []
        addSubview(content)
        if let header {
            header.removeFromSuperview()
            header.autoresizingMask = []
            addSubview(header)
        }
        activeLine.isHidden = true
        addSubview(activeLine)
        outline.isHidden = true
        addSubview(outline)              // last: above the panel content, never takes clicks
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// One rule (`PanelFocusRule`): accent only while this group is focused, quiet gray otherwise, none under a strip.
    private func updateActiveLine() {
        // The Timeline's sequence tabs draw their own underline: no full-width line above the panel.
        let line = PanelFocusRule.line(isFocused: isFocused, stripShown: !strip.isHidden || collapsesStrip)
        activeLine.isHidden = line == .none
        activeLine.isActive = line == .accent
    }

    private func syncSequenceTabsFocus() {
        (content as? TimelineHostView)?.tabs.isPanelFocused = isFocused
    }

    override func layout() {
        super.layout()
        syncSequenceTabsFocus()
        // A group holding only the Timeline shows no "Timeline" title row: the sequence tabs are its header.
        var h = collapsesStrip ? 0 : TabStrip.height
        if let header {
            let hh = header.intrinsicContentSize.height
            h = hh > 0 ? hh : TabStrip.height
            header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: h)
        }
        strip.isHidden = collapsesStrip || header != nil
        headerHeight = header != nil ? h : 0
        activeLine.frame = PanelActiveMarker.lineFrame(in: bounds, headerHeight: headerHeight)
        updateActiveLine()
        strip.frame = CGRect(x: 0, y: 0, width: bounds.width, height: h)
        content.frame = CGRect(x: 0, y: h, width: bounds.width, height: max(bounds.height - h, 0))
        outline.frame = bounds
    }
}

/// The 2 pt accent line that marks the active panel where no tab strip shows.
@MainActor
private final class ActiveLineView: NSView {
    nonisolated override var isFlipped: Bool { true }
    var isActive = false { didSet { if isActive != oldValue { needsDisplay = true } } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        PanelActiveMarker.lineColor(active: isActive).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
}

/// V1 Quiet focus outline: 1 pt accent at 55 % just inside a panel group.
@MainActor
private final class FocusOutlineView: NSView {
    nonisolated override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        Theme.Colors.focusRing.setStroke()
        let w = Theme.Metrics.focusRingWidth
        let path = NSBezierPath(rect: bounds.insetBy(dx: w / 2, dy: w / 2))
        path.lineWidth = w
        path.stroke()
    }
}
