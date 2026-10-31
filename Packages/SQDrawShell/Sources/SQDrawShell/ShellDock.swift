import Foundation
import SQCore
import SQUIKit
import SQDrawKit
import SQEditorSession

/// The dockable panel layout on the canvas: the Mac `WorkspaceHostView` (one card per tab group, 2 pt gaps),
/// `DividerSplitView` (drag a gap to resize, panels never squeezed under their minimum), `PanelContainerView` / `TabStrip`
/// (tab strip on top, the timeline-only group without one) and `DockDragSession` (drag a tab onto another group's edge or
/// strip, reorder inside its own strip) translated. The layouts are the shared `WorkspaceStore` (built-ins, the user's
/// workspaces, fractions, hidden panels), saved per workspace like the Mac `workspaces.json`.
/// Coordinates are points; events come in pixels with the scale.
@MainActor
public final class ShellDock {
    /// One tab group on screen.
    public struct Group: Equatable {
        public var panels: [PanelID]
        public var selected: PanelID
        /// The card.
        public var frame: CGRect
        /// The tab strip (zero height when the group shows none).
        public var strip: CGRect
        /// Where the selected panel draws.
        public var content: CGRect
        /// One frame per panel in `panels` (zero width when it does not fit the strip).
        public var tabs: [CGRect]
        /// A floating panel's rectangle on the shared canvas (`ShellFloating`): the strip is its title row.
        public var isFloating = false
    }

    /// One gap between two children of a split.
    public struct Divider: Equatable {
        /// The split's visible path (`Workspace.setFractions`).
        public var path: [Int]
        /// The gap lies after child `index`.
        public var index: Int
        public var axis: SplitAxis
        /// The drawn 2 pt gap.
        public var frame: CGRect
        /// Lengths of the split's children along the axis and their minimums, at layout time.
        public var lengths: [Double]
        public var mins: [Double]
        /// The drag target: 2 pt over each neighboring card (the Mac `effectiveRect`).
        public var hitFrame: CGRect {
            axis == .horizontal ? frame.insetBy(dx: -2, dy: 0) : frame.insetBy(dx: 0, dy: -2)
        }
    }

    /// What a tab drag would do on release (the Mac `DockOverlayView.State`).
    public struct DropTarget: Equatable {
        public enum Action: Equatable { case reorder(PanelID, Int), dock(PanelID, onto: PanelID, DropZone) }
        public var container: CGRect
        public var zone: DropZone?
        public var insertionX: CGFloat?
        public var stripHighlight = false
        public var action: Action?
    }

    /// The window's height below which a released tab is still a dock drop: the dock area plus the status bar under it.
    var windowHeight: CGFloat { frame.maxY + CGFloat(DrawTheme.Metrics.statusBar) }

    public static let gap = CGFloat(LayoutMetrics.dividerThickness)
    public static let stripHeight = CGFloat(DrawTheme.Metrics.panelHeader)
    public static let tabHeight: CGFloat = 22
    public static let tabPadding: CGFloat = 10
    static let tabFont: CGFloat = 11
    static let dragSlop: CGFloat = 4

    public private(set) var store: WorkspaceStore
    /// Transient, never saved (the Mac `maximizedPanel`).
    public private(set) var maximized: PanelID?
    /// The area between the top bar and the status bar.
    public var frame: CGRect = .zero
    public var measure = TextMeasure(atlas: nil, scale: 1)
    /// Panels that draw a header of their own (the monitors' Program | Source tabs): their group shows no strip.
    public var ownsHeader: (PanelID) -> Bool = { _ in false }
    /// Width (points) at the right end of a strip whose selected tab is `p` that the panel's host draws and clicks
    /// itself (header detail and buttons, the Mac `PanelHeaderItems`): no tab goes there, the dock ignores presses on it.
    public var stripTools: (PanelID) -> CGFloat = { _ in 0 }
    /// The panel with keyboard focus: its tab underline turns accent.
    public var focused: PanelID? { didSet { if let f = focused { onFocus?(f) } } }
    /// The host follows it: the key map's scope (`ShellHost.focus`) is the panel last clicked or focused.
    public var onFocus: ((PanelID) -> Void)?
    /// The last pointer position (points): Maximize Panel Under Pointer.
    public var pointer: CGPoint?
    /// Writes the store (the host debounces nothing: layouts are small). nil = not saved (tests).
    public var save: (@MainActor (WorkspaceStore) -> Void)?
    /// Right-click menu of a tab (shell menus, window points).
    public var presentMenu: (@MainActor ([SQMenuItem], CGPoint) -> Void)?
    /// The layout changed (the host relayouts its panels, the menus refresh).
    public var onChange: (@MainActor () -> Void)?

    public private(set) var groups: [Group] = []
    public private(set) var dividers: [Divider] = []
    public private(set) var dropTarget: DropTarget?
    /// The tab being dragged (its ghost follows the pointer).
    public private(set) var dragTab: (panel: PanelID, at: CGPoint)?

    private enum Press { case divider(Divider, start: CGPoint), tab(PanelID, start: CGPoint, moved: Bool) }
    private var press: Press?

    /// The panels popped out into windows of their own (`ShellFloating`).
    public let floating = ShellFloating()

    public init(store: WorkspaceStore = WorkspaceStore()) {
        self.store = store
        floating.dock = self
    }

    /// Takes the saved layouts (at launch: `WorkspaceStore.load()`).
    public func load(_ s: WorkspaceStore) {
        store = s
        maximized = nil
        layout()
        onChange?()
    }

    /// Panels left out of the layout without touching the stored workspace (shown, not stored: the Color page hides
    /// Steps while the grade is Simple, the Mac `applyWorkspace`). Their Window rows are unchecked and disabled, and
    /// `toggle` / `show` leave them hidden.
    public var transientlyHidden: Set<PanelID> = [] {
        didSet { if transientlyHidden != oldValue { maximized = maximized.flatMap { transientlyHidden.contains($0) ? nil : $0 }; layout() } }
    }

    /// The workspace on screen with the transient maximize and hides applied.
    public var workspace: Workspace {
        var w = store.current
        for p in transientlyHidden.union(floating.panels) { w.hide(p) }
        w.maximized = maximized.flatMap { w.isVisible($0) ? $0 : nil }
        return w
    }

    /// The visible panels (Window menu check marks).
    public var visiblePanels: Set<PanelID> {
        Set(store.current.allPanels.filter { store.current.isVisible($0) }).subtracting(transientlyHidden)
    }

    /// Where `p` draws, when it is the selected tab of a group on screen.
    public func contentFrame(_ p: PanelID) -> CGRect? { groups.first { $0.selected == p }?.content }
    /// The one monitor card (Program and Source share it and its picture): a floating monitor's window below its title row,
    /// else the docked card; a floating monitor wins over a docked one.
    public var monitorCard: CGRect? {
        let shown = groups.filter { $0.selected == .programMonitor || $0.selected == .sourceMonitor }
        guard let g = shown.first(where: \.isFloating) ?? shown.first(where: { $0.selected == .programMonitor }) ?? shown.first else { return nil }
        return g.isFloating ? g.content : g.frame
    }
    /// The group draws the monitor card (the other monitor group shows a placeholder).
    public func isMonitorCard(_ g: Group) -> Bool { g.isFloating ? g.content == monitorCard : g.frame == monitorCard }
    /// The card of the group showing `p` as its selected tab.
    public func cardFrame(_ p: PanelID) -> CGRect? { groups.first { $0.selected == p }?.frame }
    /// The selected panel of the group under `p` (points).
    public func panel(at p: CGPoint) -> PanelID? { groups.first { $0.frame.contains(p) }?.selected }
    /// The panel is the shown tab of its group.
    public func shows(_ p: PanelID) -> Bool { contentFrame(p) != nil }

    // MARK: Layout

    public func layout() {
        groups = []
        dividers = []
        floating.refresh(key: FloatingPanelState.key(page: store.page, editName: store.editName), mainWidth: frame.maxX)
        if frame.width > 2 * Self.gap, frame.height > 2 * Self.gap, let root = workspace.visibleRoot {
            place(root, in: frame.insetBy(dx: Self.gap, dy: Self.gap), path: [])
        }
        for w in floating.windows {
            let bar = ShellFloating.titleBar
            groups.append(Group(panels: [w.panel], selected: w.panel, frame: w.rect,
                                strip: CGRect(x: w.rect.minX, y: w.rect.minY, width: w.rect.width, height: bar),
                                content: CGRect(x: w.rect.minX, y: w.rect.minY + bar, width: w.rect.width, height: max(w.rect.height - bar, 0)),
                                tabs: [.zero], isFloating: true))
        }
    }

    private func place(_ node: LayoutNode, in r: CGRect, path: [Int]) {
        switch node {
        case .tabs(let panels, let selected):
            // A group holding only the Timeline shows no title row (its sequence tabs are the header); a panel with a
            // header of its own replaces the strip.
            let bare = panels == [.timeline] || ownsHeader(selected)
            let h = bare ? 0 : min(Self.stripHeight, r.height)
            let strip = CGRect(x: r.minX, y: r.minY, width: r.width, height: h)
            var tabs: [CGRect] = []
            var x = r.minX + CGFloat(DrawTheme.Spacing.sm) - 2
            let limit = r.maxX - CGFloat(DrawTheme.Spacing.sm) - (bare ? 0 : stripTools(selected))
            let y = (r.minY + (h - 1 - Self.tabHeight) / 2).rounded()
            for p in panels {
                let w = ceil(measure.width(EditorCommand.localizedPanelTitle(p), size: Self.tabFont, face: measure.medium)) + 2 * Self.tabPadding
                if bare || x + w > limit { tabs.append(CGRect(x: x, y: y, width: 0, height: 0)); continue }   // a narrow group shows the tabs that fit
                tabs.append(CGRect(x: x, y: y, width: w, height: Self.tabHeight))
                x += w + 2
            }
            groups.append(Group(panels: panels, selected: selected, frame: r, strip: strip,
                                content: CGRect(x: r.minX, y: r.minY + h, width: r.width, height: max(r.height - h, 0)), tabs: tabs))
        case .split(let axis, let children, let fractions):
            let total = axis == .horizontal ? r.width : r.height
            let length = max(Double(total - Self.gap * CGFloat(children.count - 1)), 0)
            let mins = LayoutMetrics.childMinimums(axis: axis, children: children)
            let f = LayoutMetrics.clampedFractions(fractions, length: length, mins: mins)
            var lengths: [Double] = []
            var used = 0.0
            for i in children.indices {
                let l = i == children.count - 1 ? length - used : (f[i] * length).rounded()
                lengths.append(max(l, 0)); used += lengths[i]
            }
            var pos = axis == .horizontal ? r.minX : r.minY
            for (i, c) in children.enumerated() {
                let l = CGFloat(lengths[i])
                let cr = axis == .horizontal ? CGRect(x: pos, y: r.minY, width: l, height: r.height)
                                             : CGRect(x: r.minX, y: pos, width: r.width, height: l)
                place(c, in: cr, path: path + [i])
                pos += l
                if i < children.count - 1 {
                    let g = axis == .horizontal ? CGRect(x: pos, y: r.minY, width: Self.gap, height: r.height)
                                                : CGRect(x: r.minX, y: pos, width: r.width, height: Self.gap)
                    dividers.append(Divider(path: path, index: i, axis: axis, frame: g, lengths: lengths, mins: mins))
                    pos += Self.gap
                }
            }
        }
    }

    // MARK: Workspace changes (the Mac `mutateWorkspace` and the Window menu actions)

    public func mutate(_ body: (inout Workspace) -> Void) {
        var w = store.current
        body(&w)
        store.updateCurrent(w)
        commit()
    }

    private func commit() {
        save?(store)
        layout()
        onChange?()
    }

    /// Window > panel row from a click: shows or hides it (`windowPanelItem`).
    public func toggle(_ p: PanelID) {
        guard !transientlyHidden.contains(p) else { return }
        if floating.isFloating(p) { floating.close(p); return }        // a floating panel's Window row closes it
        maximized = nil
        let was = store.current.isVisible(p)
        mutate { $0.toggle(p) }
        if !was { focused = p }
    }

    /// The panel's shortcut or a request from another panel: shown and selected in its group (`showPanel`).
    public func show(_ p: PanelID) {
        guard !transientlyHidden.contains(p) else { return }
        if floating.isFloating(p) { focused = p; floating.raise?(p); return }   // its window comes forward
        if maximized != nil && maximized != p { maximized = nil }
        mutate { $0.show(p) }
        focused = p
    }

    public func select(_ p: PanelID) { show(p) }

    public func close(_ p: PanelID) {
        maximized = nil
        mutate { $0.hide(p) }
        if focused == p { focused = store.current.isVisible(.timeline) ? .timeline : nil }
    }

    public func toggleMaximize(_ p: PanelID) {
        // A floating panel's window fills its display (the Mac `toggleFloatingZoom`).
        guard !floating.isFloating(p) else { floating.toggleZoom(p); return }
        maximized = maximized == p ? nil : p
        focused = p
        layout()
        onChange?()
    }

    /// The Edit | Color switch (the Mac `toolbarPage`): the Color page opens on its Color tab.
    public func setPage(_ p: WorkspaceStore.Page) {
        guard store.page != p else { return }
        store.setPage(p)
        if p == .color {
            var c = store.colorPage
            c.selectTab(.colorInspector)
            if c != store.colorPage { store.colorPage = c }      // no override stored for a page switch alone
        }
        maximized = nil
        commit()
    }

    public func chooseWorkspace(_ name: String) {
        guard store.selectEdit(name) else { return }
        maximized = nil
        commit()
    }

    /// Save as New Workspace: a numbered copy for a taken name. Returns the name used.
    @discardableResult
    public func saveAsNew(_ name: String) -> String? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return nil }
        let used = store.saveCurrentAsNew(base: n)
        commit()
        return used
    }

    public func renameCurrent(_ name: String) -> Bool {
        guard store.renameCurrent(to: name.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        commit()
        return true
    }

    public func deleteCurrent() -> Bool {
        guard store.deleteCurrent() else { return false }
        maximized = nil
        commit()
        return true
    }

    public func resetLayout() {
        guard store.page == .edit else { store.resetCurrentColor(); maximized = nil; commit(); return }
        guard store.library.resetBuiltIn(store.editName) else { return }
        maximized = nil
        commit()
    }

    public func resetAll() {
        store.library.resetAllBuiltIns()
        store.resetAllColor()
        maximized = nil
        commit()
    }

    /// The host moves a dockable panel into its own window (the Mac `floatPanel`: a borderless panel window; Windows: a second
    /// top-level window). nil = the host has no floating windows yet, the tab menu then leaves the row out.
    // Hosts that open a window per `floating.windows` entry set it to `floating.float`.
    public var floatPanel: (@MainActor (PanelID) -> Void)?

    /// Right-click menu of a tab (`tabContextItems`).
    public func tabMenu(_ p: PanelID) -> [SQMenuItem] {
        var items = [SQMenuItem(title: maximized == p || floating.isZoomed(p) ? "Restore Panel Size" : "Maximize Panel", shortcut: "`") { [weak self] in self?.toggleMaximize(p) }]
        if ShellFloating.canFloat(p), floatPanel != nil { items.append(SQMenuItem(title: "Move to Floating Window") { [weak self] in self?.floatPanel?(p) }) }
        items.append(SQMenuItem(title: "Close Panel") { [weak self] in self?.close(p) })
        return items
    }

    // MARK: Events

    /// True while a divider or tab press is being tracked (the host sends it the drags and the release first).
    public var isTracking: Bool { press != nil }

    /// One event in pixels; true when the dock took it (a divider, a tab, a strip).
    public func handle(_ e: InputEvent, scale: Float) -> Bool {
        let k = CGFloat(max(scale, 0.01))
        func pt(_ x: Float, _ y: Float) -> CGPoint { CGPoint(x: CGFloat(x) / k, y: CGFloat(y) / k) }
        switch e {
        case .mouseDown(let x, let y, let m): pointer = pt(x, y); return mouseDown(pt(x, y), modifiers: m)
        case .mouseDragged(let x, let y): return mouseDragged(pt(x, y))
        case .mouseUp(let x, let y): return mouseUp(pt(x, y))
        case .keyDown(let key, _):
            guard press != nil, key == .escape else { return false }
            press = nil; dropTarget = nil; dragTab = nil
            return true
        case .mouseMoved(let x, let y): pointer = pt(x, y); return false
        case .scroll: return false
        }
    }

    /// The pointer is over a divider: the host shows the resize cursor.
    public func divider(at p: CGPoint) -> Divider? { dividers.first { $0.hitFrame.contains(p) } }

    func mouseDown(_ p: CGPoint, modifiers m: InputModifiers) -> Bool {
        if !floating.windows.isEmpty, floating.hit(at: p) != nil {
            focused = floating.hit(at: p).flatMap { h -> PanelID? in
                switch h { case .title(let q), .dock(let q), .close(let q), .grip(let q), .content(let q): q }
            } ?? focused
            return floating.press(at: p) && !m.contains(.secondary)
        }
        if !m.contains(.secondary), let d = divider(at: p) { press = .divider(d, start: p); return true }
        guard let g = groups.first(where: { $0.strip.contains(p) }) else { return false }
        if p.x >= g.strip.maxX - stripTools(g.selected), !m.contains(.secondary) { return false }
        if let i = g.tabs.firstIndex(where: { $0.width > 0 && $0.contains(p) }) {
            let panel = g.panels[i]
            if m.contains(.secondary) { presentMenu?(tabMenu(panel), p); return true }
            press = .tab(panel, start: p, moved: false)
            focused = panel
            return true
        }
        if m.contains(.secondary) { presentMenu?(tabMenu(g.selected), p) }
        focused = g.selected
        return true
    }

    func mouseDragged(_ p: CGPoint) -> Bool {
        switch press {
        case .divider(let d, let start)?:
            let delta = Double(d.axis == .horizontal ? p.x - start.x : p.y - start.y)
            mutateFractions(d, delta: delta)
            return true
        case .tab(let panel, let start, let moved)?:
            guard moved || hypot(p.x - start.x, p.y - start.y) > Self.dragSlop else { return true }
            press = .tab(panel, start: start, moved: true)
            dragTab = (panel, p)
            dropTarget = target(at: p, panel: panel)
            return true
        case nil: return false
        }
    }

    func mouseUp(_ p: CGPoint) -> Bool {
        defer { press = nil; dropTarget = nil; dragTab = nil }
        switch press {
        case .divider?:
            save?(store)
            return true
        case .tab(let panel, _, let moved)?:
            if !moved { select(panel); return true }
            if floating.tearOff(panel, at: p, window: CGSize(width: frame.maxX, height: windowHeight)) { return true }
            switch target(at: p, panel: panel)?.action {
            case .reorder(let q, let i)?: mutate { $0.moveTab(q, toIndex: i) }
            case .dock(let q, let anchor, let zone)?: maximized = nil; mutate { $0.dock(q, onto: anchor, zone: zone) }
            case nil: break
            }
            return true
        case nil: return false
        }
    }

    /// The Mac `DividerSplitView` drag: the two neighbors trade length, each kept at its minimum.
    private func mutateFractions(_ d: Divider, delta: Double) {
        var l = d.lengths
        let i = d.index, j = d.index + 1
        let pair = l[i] + l[j]
        let a = min(max(l[i] + delta, d.mins[i]), max(pair - d.mins[j], d.mins[i]))
        l[i] = a; l[j] = pair - a
        let sum = l.reduce(0, +)
        guard sum > 0 else { return }
        var w = store.current
        guard w.setFractions(at: d.path, l.map { $0 / sum }) else { return }
        store.updateCurrent(w)
        layout()
    }

    /// `DockDragSession.hitTest`: the strip of the own group reorders, another strip joins as a tab, a card's edge
    /// bands split it, its center joins as a tab; a lone panel dropped back onto its own group does nothing.
    public func target(at p: CGPoint, panel: PanelID) -> DropTarget? {
        guard let g = groups.first(where: { $0.frame.contains(p) }) else { return nil }
        let own = g.panels.contains(panel)
        let rect = g.frame
        if p.y < rect.minY + Self.stripHeight {
            let frames = g.tabs.filter { $0.width > 0 }
            if own, let cur = g.panels.firstIndex(of: panel), frames.count == g.panels.count {
                let to = TabReorder.finalIndex(current: cur, x: Double(p.x), midXs: frames.map { Double($0.midX) })
                let slot = frames.filter { $0.midX < p.x }.count
                let lineX = slot < frames.count ? frames[slot].minX - 2 : (frames.last?.maxX ?? rect.minX) + 2
                return DropTarget(container: rect, zone: nil, insertionX: lineX, action: .reorder(panel, to))
            }
            if !own, let anchor = Workspace.dockAnchor(group: g.panels, selected: g.selected, dragging: panel) {
                return DropTarget(container: rect, zone: .center, stripHighlight: true, action: .dock(panel, onto: anchor, .center))
            }
        }
        guard let zone = DropZone.zone(for: (Double(p.x), Double(p.y)),
                                       in: (Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height))),
              let anchor = Workspace.dockAnchor(group: g.panels, selected: g.selected, dragging: panel) else {
            return DropTarget(container: rect, zone: nil, action: nil)
        }
        if own, zone == .center { return DropTarget(container: rect, zone: nil, action: nil) }
        return DropTarget(container: rect, zone: zone, action: .dock(panel, onto: anchor, zone))
    }
}
