import AppKit
import SQEditorUI

/// Builds the on-screen layout from a `Workspace` tree: one `NSSplitView` per split (1 pt black dividers), one
/// `PanelContainerView` per tab group. The tree is rebuilt on every structural change (hide/show, tab select,
/// workspace switch); panel views are cached by `EditorPanels` and only re-parented. Divider drags report new
/// fractions through `onFractions` (visible path + fractions) and do not rebuild.
@MainActor
final class WorkspaceHostView: NSView {
    var panelView: ((PanelID) -> NSView)?
    var onSelectTab: ((PanelID) -> Void)?
    var onFractions: (([Int], [Double]) -> Void)?
    /// Tab drag outcomes; delivered asynchronously, after the drag session has ended.
    var onDock: ((PanelID, PanelID, DropZone) -> Void)?
    var onMoveTab: ((PanelID, Int) -> Void)?
    var tabMenu: ((PanelID) -> NSMenu?)?
    /// The panel with keyboard focus gets the focus outline.
    var focusedPanel: PanelID? { didSet { updateFocus() } }
    private var dragging = false

    override var isFlipped: Bool { true }

    func apply(_ w: Workspace) {
        subviews.forEach { $0.removeFromSuperview() }
        guard let root = w.visibleRoot else { return }
        let v = build(root, path: [])
        v.frame = bounds
        v.autoresizingMask = [.width, .height]
        addSubview(v)
        needsLayout = true
        updateFocus()
    }

    private func updateFocus() {
        for c in containers() { c.isFocused = c.selected == focusedPanel }
    }

    /// All tab groups currently on screen.
    func containers() -> [PanelContainerView] {
        var out: [PanelContainerView] = []
        func walk(_ v: NSView) {
            if let c = v as? PanelContainerView { out.append(c) } else { v.subviews.forEach(walk) }
        }
        walk(self)
        return out
    }

    private func tabPressed(_ panel: PanelID, _ button: NSView, _ event: NSEvent) {
        guard !dragging else { return }
        dragging = true
        let result = DockDragSession.run(panel: panel, button: button, event: event, host: self)
        dragging = false
        // Rebuild after the tab's own mouseDown has returned (the tab view is about to be replaced).
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                switch result {
                case .click: self?.onSelectTab?(panel)
                case .cancelled: break
                case .reorder(let p, let i): self?.onMoveTab?(p, i)
                case .dock(let p, let a, let z): self?.onDock?(p, a, z)
                }
            }
        }
    }

    private func build(_ node: LayoutNode, path: [Int]) -> NSView {
        switch node {
        case .tabs(let panels, let selected):
            let c = PanelContainerView(panels: panels, selected: selected,
                                       content: panelView?(selected) ?? NSView()) { [weak self] p in self?.onSelectTab?(p) }
            c.strip.onPress = { [weak self] p, button, event in self?.tabPressed(p, button, event) }
            c.strip.tabMenu = tabMenu
            return c
        case .split(let axis, let children, let fractions):
            let split = DividerSplitView(path: path, fractions: fractions,
                                         minLengths: LayoutMetrics.childMinimums(axis: axis, children: children).map { CGFloat($0) })
            split.isVertical = axis == .horizontal
            split.onUserResize = { [weak self] p, f in self?.onFractions?(p, f) }
            for (i, c) in children.enumerated() { split.addSubview(build(c, path: path + [i])) }
            return split
        }
    }
}

/// NSSplitView with a 1 pt black divider, no collapsing, and a minimum length per pane (from the panels' minimum sizes).
/// Panes are laid out from the user's desired fractions clamped to those minimums (`LayoutMetrics.clampedFractions`), both
/// initially and on every resize, so shrinking the window or dragging a divider can never squeeze or overlap a panel;
/// growing again restores the desired proportions.
@MainActor
final class DividerSplitView: NSSplitView, NSSplitViewDelegate {
    let path: [Int]
    private var desired: [Double]
    private let minLengths: [CGFloat]
    var onUserResize: (([Int], [Double]) -> Void)?
    private var appliedInitial = false
    private var applying = false

    override var dividerThickness: CGFloat { Theme.Spacing.paneDivider }
    override var dividerColor: NSColor { Theme.Colors.divider }
    override var isFlipped: Bool { true }

    init(path: [Int], fractions: [Double], minLengths: [CGFloat]) {
        self.path = path; self.desired = fractions; self.minLengths = minLengths
        super.init(frame: .zero)
        dividerStyle = .thin
        delegate = self
        autoresizesSubviews = true
        wantsLayer = true
        layer?.masksToBounds = true
        // The gaps between panes show this colour. NSSplitView's own divider drawing is stale after `arrange()`
        // moves the panes (it painted a 1 pt line at the default 50 % position, over the panes), so it is disabled.
        layer?.backgroundColor = Theme.Colors.divider.cgColor
    }

    override func drawDivider(in rect: NSRect) {}
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private var length: CGFloat { isVertical ? bounds.width : bounds.height }

    override func layout() {
        super.layout()
        if !appliedInitial { arrange() }
    }

    /// Frames for every pane from `desired` (clamped to the minimums); the last pane takes the rounding remainder.
    private func arrange() {
        let n = subviews.count
        guard n > 1, n == desired.count, length > 1 else { return }
        appliedInitial = true
        applying = true
        defer { applying = false }
        let gap = dividerThickness * CGFloat(n - 1)
        let available = max(length - gap, 0)
        let f = LayoutMetrics.clampedFractions(desired, length: Double(available), mins: minLengths.map(Double.init))
        var pos: CGFloat = 0
        for (i, v) in subviews.enumerated() {
            let len = i == n - 1 ? max(length - pos, 0) : (CGFloat(f[i]) * available).rounded()
            v.frame = isVertical ? CGRect(x: pos, y: 0, width: len, height: bounds.height)
                                 : CGRect(x: 0, y: pos, width: bounds.width, height: len)
            pos += len + dividerThickness
        }
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        if appliedInitial { arrange() } else { adjustSubviews() }
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        let origin = isVertical ? subviews[i].frame.minX : subviews[i].frame.minY
        return max(proposed, origin + minLengths[i])
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        let next = subviews[i + 1].frame
        let end = isVertical ? next.maxX : next.maxY
        return min(proposed, end - minLengths[i + 1] - dividerThickness)
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard appliedInitial, !applying, let e = NSApp.currentEvent,
              e.type == .leftMouseDragged || e.type == .leftMouseUp else { return }
        let lengths = subviews.map { isVertical ? $0.frame.width : $0.frame.height }
        let total = lengths.reduce(0, +)
        guard total > 0 else { return }
        desired = lengths.map { Double($0 / total) }
        onUserResize?(path, desired)
    }
}
