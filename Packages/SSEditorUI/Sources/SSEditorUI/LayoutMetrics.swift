import Foundation

/// Pure sizing rules for the workspace layout: per-panel minimum sizes roll up the layout tree, and split fractions are
/// clamped so no pane ever gets less than its minimum (no overlapping or squeezed views when the window or a divider moves).
public enum LayoutMetrics {
    public static let dividerThickness = 1.0

    /// Smallest (width, height) of a node: tab groups need their largest panel plus the tab strip; horizontal splits add
    /// widths, vertical splits add heights; the other axis takes the maximum.
    public static func minSize(of node: LayoutNode) -> (width: Double, height: Double) {
        switch node {
        case .tabs(let panels, _):
            let w = panels.map { $0.minSize.width }.max() ?? 0
            let h = panels.map { $0.minSize.height }.max() ?? 0
            return (w, h + PanelID.headerHeight)
        case .split(let axis, let children, _):
            let sizes = children.map(minSize(of:))
            let gaps = dividerThickness * Double(max(children.count - 1, 0))
            switch axis {
            case .horizontal: return (sizes.reduce(0) { $0 + $1.width } + gaps, sizes.map(\.height).max() ?? 0)
            case .vertical: return (sizes.map(\.width).max() ?? 0, sizes.reduce(0) { $0 + $1.height } + gaps)
            }
        }
    }

    /// Minimum length of each child along the split axis.
    public static func childMinimums(axis: SplitAxis, children: [LayoutNode]) -> [Double] {
        children.map { c in
            let s = minSize(of: c)
            return axis == .horizontal ? s.width : s.height
        }
    }

    /// Fractions (summing to 1) for panes sharing `length` points (dividers already subtracted) so that every pane keeps
    /// at least its minimum. Panes below their minimum are raised; the excess is taken from the others in proportion.
    /// When the minimums do not fit, the panes share `length` in proportion to their minimums.
    public static func clampedFractions(_ fractions: [Double], length: Double, mins: [Double]) -> [Double] {
        let n = fractions.count
        guard n > 0, mins.count == n else { return fractions }
        let mins = mins.map { $0.isFinite ? max($0, 0) : 0 }
        let equal = Array(repeating: 1 / Double(n), count: n)
        guard length.isFinite, length > 0 else { return equal }
        let minSum = mins.reduce(0, +)
        if minSum >= length { return minSum > 0 ? mins.map { $0 / minSum } : equal }
        var base = fractions.map { $0.isFinite ? max($0, 0) : 0 }
        let sum = base.reduce(0, +)
        base = sum > 0 ? base.map { $0 / sum } : equal
        var lens = base.map { $0 * length }
        var pinned = Set<Int>()
        for _ in 0...n {
            let low = lens.indices.filter { !pinned.contains($0) && lens[$0] < mins[$0] - 1e-9 }
            if low.isEmpty { break }
            for i in low { lens[i] = mins[i]; pinned.insert(i) }
            let free = lens.indices.filter { !pinned.contains($0) }
            let target = length - pinned.reduce(0.0) { $0 + lens[$1] }
            let freeBase = free.reduce(0.0) { $0 + base[$1] }
            guard freeBase > 0 else { break }
            for i in free { lens[i] = base[i] / freeBase * target }
        }
        let total = lens.reduce(0, +)
        return total > 0 ? lens.map { $0 / total } : equal
    }

    /// Clamps one proposed divider position between its two panes, each keeping its minimum.
    public static func clampedDivider(_ proposed: Double, start: Double, end: Double, minBefore: Double, minAfter: Double) -> Double {
        let lo = start + minBefore, hi = end - minAfter
        return lo <= hi ? min(max(proposed, lo), hi) : (start + end) / 2
    }
}

public extension Workspace {
    /// Smallest content area the visible layout can be shown in.
    var minimumContentSize: (width: Double, height: Double) {
        visibleRoot.map(LayoutMetrics.minSize(of:)) ?? (0, 0)
    }
}

/// Saved layouts from before a panel was removed (Properties) name panels that no longer exist.
public enum WorkspaceMigration {
    /// Removes unknown panel names from `panels` arrays, `hidden` and `maximized`, and repairs `selected`,
    /// anywhere in the JSON. Returns the input unchanged when it is not JSON.
    public static func dropUnknownPanels(_ data: Data) -> Data {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return data }
        let fixed = walk(obj)
        return (try? JSONSerialization.data(withJSONObject: fixed, options: [.sortedKeys])) ?? data
    }

    private static func known(_ s: Any) -> Bool { (s as? String).flatMap(PanelID.init(rawValue:)) != nil }

    private static func walk(_ v: Any) -> Any {
        if let a = v as? [Any] { return a.map(walk) }
        guard var d = v as? [String: Any] else { return v }
        for (k, x) in d { d[k] = walk(x) }
        if let p = d["panels"] as? [Any] {
            let kept = p.filter(known)
            d["panels"] = kept
            if let sel = d["selected"], !kept.contains(where: { ($0 as? String) == (sel as? String) }), let first = kept.first {
                d["selected"] = first
            }
        }
        if let h = d["hidden"] as? [Any] { d["hidden"] = h.filter(known) }
        if let m = d["maximized"], !known(m) { d["maximized"] = nil }
        return d
    }
}
