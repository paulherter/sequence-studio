import Foundation

public enum PanelID: String, Sendable, Codable, Hashable, CaseIterable {
    case effectControls, text, properties
    case programMonitor, sourceMonitor
    case library, effects, project
    case timeline
}

public enum SplitAxis: String, Sendable, Codable, Hashable {
    /// Children sit side by side.
    case horizontal
    /// Children are stacked.
    case vertical
}

/// Layout tree: splits -> tab groups -> panels. `fractions` of a split sum to 1.
public indirect enum LayoutNode: Sendable, Codable, Hashable {
    case split(axis: SplitAxis, children: [LayoutNode], fractions: [Double])
    case tabs(panels: [PanelID], selected: PanelID)

    /// Every panel in this subtree, in layout order.
    public var panels: [PanelID] {
        switch self {
        case .split(_, let c, _): c.flatMap(\.panels)
        case .tabs(let p, _): p
        }
    }
}

/// A named layout plus view state (hidden panels, maximized panel). Value type.
/// Hidden panels stay in `root` and are only pruned from `visibleRoot`, so show restores the exact previous position and sizes.
public struct Workspace: Sendable, Codable, Hashable {
    public var name: String
    public var root: LayoutNode
    public var hidden: Set<PanelID>
    public var maximized: PanelID?

    public static let minFraction = 0.05

    public init(name: String, root: LayoutNode, hidden: Set<PanelID> = [], maximized: PanelID? = nil) {
        self.name = name; self.root = root; self.hidden = hidden; self.maximized = maximized
    }

    // MARK: Built-ins (docs/UX.md section 1)

    /// Effect Controls | Text | Properties and Program | Source on top, timeline below; Library and Effects | Project on the right, full height.
    public static let editingPC = Workspace(name: "Editing – PC", root: .split(axis: .horizontal, children: [
        .split(axis: .vertical, children: [
            .split(axis: .horizontal, children: [
                .tabs(panels: [.effectControls, .text, .properties], selected: .effectControls),
                .tabs(panels: [.programMonitor, .sourceMonitor], selected: .programMonitor),
            ], fractions: [0.6, 0.4]),
            .tabs(panels: [.timeline], selected: .timeline),
        ], fractions: [0.55, 0.45]),
        .split(axis: .vertical, children: [
            .tabs(panels: [.library], selected: .library),
            .tabs(panels: [.effects, .project], selected: .effects),
        ], fractions: [0.55, 0.45]),
    ], fractions: [0.75, 0.25]))

    /// Program monitor full height on the right; Library | Effects and Effect Controls group in the middle; Project and timeline bottom left.
    public static let editingMacBook = Workspace(name: "Editing – MacBook", root: .split(axis: .horizontal, children: [
        .split(axis: .vertical, children: [
            .split(axis: .horizontal, children: [
                .tabs(panels: [.library, .effects], selected: .library),
                .tabs(panels: [.effectControls, .text, .properties], selected: .effectControls),
            ], fractions: [0.4, 0.6]),
            .split(axis: .horizontal, children: [
                .tabs(panels: [.project], selected: .project),
                .tabs(panels: [.timeline], selected: .timeline),
            ], fractions: [0.25, 0.75]),
        ], fractions: [0.5, 0.5]),
        .tabs(panels: [.programMonitor, .sourceMonitor], selected: .programMonitor),
    ], fractions: [0.68, 0.32]))

    public static let builtIns: [Workspace] = [editingPC, editingMacBook]

    // MARK: Queries

    public var allPanels: [PanelID] { root.panels }
    public func isVisible(_ p: PanelID) -> Bool { allPanels.contains(p) && !hidden.contains(p) }

    /// Tree to render: hidden panels pruned, single-child splits collapsed, fractions renormalised.
    /// A maximized panel fills everything. Nil when nothing is visible.
    public var visibleRoot: LayoutNode? {
        if let m = maximized, isVisible(m) { return .tabs(panels: [m], selected: m) }
        return prune(root)
    }

    private func prune(_ node: LayoutNode) -> LayoutNode? {
        switch node {
        case .tabs(let panels, let selected):
            let vis = panels.filter { !hidden.contains($0) }
            guard let first = vis.first else { return nil }
            return .tabs(panels: vis, selected: vis.contains(selected) ? selected : first)
        case .split(let axis, let children, let fractions):
            var kept: [LayoutNode] = [], fr: [Double] = []
            for (i, c) in children.enumerated() {
                if let p = prune(c) { kept.append(p); fr.append(fractions[i]) }
            }
            if kept.count <= 1 { return kept.first }
            return .split(axis: axis, children: kept, fractions: Self.normalized(fr))
        }
    }

    // MARK: Operations

    public mutating func hide(_ p: PanelID) {
        guard allPanels.contains(p) else { return }
        hidden.insert(p)
        if maximized == p { maximized = nil }
    }

    /// Restores the panel at its previous position and selects it in its tab group.
    public mutating func show(_ p: PanelID) {
        guard allPanels.contains(p) else { return }
        hidden.remove(p)
        root = Self.selecting(p, in: root)
    }

    public mutating func toggle(_ p: PanelID) { isVisible(p) ? hide(p) : show(p) }

    /// Selects a tab (and shows the panel if it was hidden).
    public mutating func selectTab(_ p: PanelID) { show(p) }

    /// Sets fractions of the split at `visiblePath` (child indices in `visibleRoot`). `fractions` has one entry per
    /// visible child; it is clamped to `minFraction` and normalised. Hidden children keep their stored fractions.
    /// Returns false when the path is not a split or the count is wrong.
    @discardableResult
    public mutating func setFractions(at visiblePath: [Int], _ fractions: [Double]) -> Bool {
        guard maximized == nil, let new = applying(root, visiblePath[...], fractions) else { return false }
        root = new
        return true
    }

    /// Maximizes a visible panel; calling again with the same panel restores the layout.
    public mutating func toggleMaximize(_ p: PanelID) {
        if maximized == p { maximized = nil } else if isVisible(p) { maximized = p }
    }
    public mutating func restore() { maximized = nil }

    // MARK: Helpers

    private func hasVisible(_ n: LayoutNode) -> Bool { n.panels.contains { !hidden.contains($0) } }

    private func applying(_ node: LayoutNode, _ path: ArraySlice<Int>, _ new: [Double]) -> LayoutNode? {
        guard case .split(let axis, let children, let old) = node else { return nil }
        let vis = children.indices.filter { hasVisible(children[$0]) }
        if vis.count == 1 {   // collapsed in visibleRoot: path passes through
            guard let inner = applying(children[vis[0]], path, new) else { return nil }
            var c = children; c[vis[0]] = inner
            return .split(axis: axis, children: c, fractions: old)
        }
        guard vis.count >= 2 else { return nil }
        if let i = path.first {
            guard vis.indices.contains(i), let inner = applying(children[vis[i]], path.dropFirst(), new) else { return nil }
            var c = children; c[vis[i]] = inner
            return .split(axis: axis, children: c, fractions: old)
        }
        guard new.count == vis.count else { return nil }
        let share = Self.normalized(new)
        let hiddenSum = children.indices.filter { !vis.contains($0) }.reduce(0.0) { $0 + old[$1] }
        let visibleSum = 1 - hiddenSum
        var f = old
        for (k, idx) in vis.enumerated() { f[idx] = share[k] * visibleSum }
        return .split(axis: axis, children: children, fractions: f)
    }

    private static func selecting(_ p: PanelID, in node: LayoutNode) -> LayoutNode {
        switch node {
        case .tabs(let panels, let sel): .tabs(panels: panels, selected: panels.contains(p) ? p : sel)
        case .split(let a, let c, let f): .split(axis: a, children: c.map { selecting(p, in: $0) }, fractions: f)
        }
    }

    /// Non-finite or negative values count as 0; result sums to 1 with every entry >= `minFraction`
    /// (equal split when that is impossible or the input is all zero).
    public static func normalized(_ values: [Double]) -> [Double] {
        let n = values.count
        guard n > 0 else { return [] }
        let equal = Array(repeating: 1 / Double(n), count: n)
        var v = values.map { $0.isFinite ? max($0, 0) : 0 }
        let sum = v.reduce(0, +)
        guard sum > 0, Double(n) * minFraction < 1 else { return equal }
        v = v.map { $0 / sum }
        // Raise entries below the minimum, take the excess from the free entries proportionally.
        var pinned = Set<Int>()
        for _ in 0..<n {
            let low = v.indices.filter { !pinned.contains($0) && v[$0] < minFraction }
            if low.isEmpty { break }
            for i in low { v[i] = minFraction; pinned.insert(i) }
            let free = v.indices.filter { !pinned.contains($0) }
            let target = 1 - Double(pinned.count) * minFraction
            let freeSum = free.reduce(0.0) { $0 + v[$1] }
            guard freeSum > 0 else { return equal }
            for i in free { v[i] *= target / freeSum }
        }
        return v
    }
}
