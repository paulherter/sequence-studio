import AppKit
import SSEditorUI

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
            return c
        case .split(let axis, let children, let fractions):
            let split = DividerSplitView(path: path, fractions: fractions)
            split.isVertical = axis == .horizontal
            split.onUserResize = { [weak self] p, f in self?.onFractions?(p, f) }
            for (i, c) in children.enumerated() { split.addSubview(build(c, path: path + [i])) }
            return split
        }
    }
}

/// NSSplitView with a 1 pt black divider, no collapsing, a minimum pane size, and initial positions from fractions.
@MainActor
final class DividerSplitView: NSSplitView, NSSplitViewDelegate {
    static let minPane: CGFloat = 96

    let path: [Int]
    private let fractions: [Double]
    var onUserResize: (([Int], [Double]) -> Void)?
    private var appliedInitial = false
    private var applying = false

    override var dividerThickness: CGFloat { Theme.Spacing.paneDivider }
    override var dividerColor: NSColor { Theme.Colors.divider }
    override var isFlipped: Bool { true }

    init(path: [Int], fractions: [Double]) {
        self.path = path; self.fractions = fractions
        super.init(frame: .zero)
        dividerStyle = .thin
        delegate = self
        autoresizesSubviews = true
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private var length: CGFloat { isVertical ? bounds.width : bounds.height }

    override func layout() {
        super.layout()
        applyInitialFractions()
    }

    private func applyInitialFractions() {
        guard !appliedInitial, length > 1, subviews.count == fractions.count, subviews.count > 1 else { return }
        appliedInitial = true
        applying = true
        defer { applying = false }
        let available = length - dividerThickness * CGFloat(subviews.count - 1)
        var cumulative = 0.0
        for i in 0..<(subviews.count - 1) {
            cumulative += fractions[i]
            setPosition(CGFloat(cumulative) * available + CGFloat(i) * dividerThickness, ofDividerAt: i)
        }
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        let origin = isVertical ? subviews[i].frame.minX : subviews[i].frame.minY
        return max(proposed, origin + Self.minPane)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        let next = subviews[i + 1].frame
        let end = isVertical ? next.maxX : next.maxY
        return min(proposed, end - Self.minPane - dividerThickness)
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard appliedInitial, !applying, let e = NSApp.currentEvent,
              e.type == .leftMouseDragged || e.type == .leftMouseUp else { return }
        let lengths = subviews.map { isVertical ? $0.frame.width : $0.frame.height }
        let total = lengths.reduce(0, +)
        guard total > 0 else { return }
        onUserResize?(path, lengths.map { Double($0 / total) })
    }
}
