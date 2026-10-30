import Foundation

/// Where a dragged panel lands relative to a target tab group.
public enum DropZone: String, Sendable, Codable, Hashable, CaseIterable {
    case center, left, right, top, bottom

    public var axis: SplitAxis? {
        switch self {
        case .center: nil
        case .left, .right: .horizontal
        case .top, .bottom: .vertical
        }
    }
    /// True when the new group goes before the target.
    var insertsBefore: Bool { self == .left || self == .top }

    /// Share of each side (normalized) that counts as an edge band; the inner rect is the center zone.
    public static let edgeBand = 0.25

    /// Pure geometry for the drag overlay (Premiere-like). In the corners the edge with the smaller normalized
    /// distance wins (ties prefer left/right). Returns nil outside `rect` or for empty rects.
    /// Coordinates are plain (y grows downward; `top` = smaller y).
    public static func zone(for point: (x: Double, y: Double), in rect: (x: Double, y: Double, width: Double, height: Double)) -> DropZone? {
        guard rect.width > 0, rect.height > 0, point.x.isFinite, point.y.isFinite else { return nil }
        let u = (point.x - rect.x) / rect.width, v = (point.y - rect.y) / rect.height
        guard u >= 0, u <= 1, v >= 0, v <= 1 else { return nil }
        let dl = u, dr = 1 - u, dt = v, db = 1 - v
        let m = min(dl, dr, dt, db)
        if m >= edgeBand { return .center }
        if m == dl { return .left }
        if m == dr { return .right }
        if m == dt { return .top }
        return .bottom
    }
}

public extension Workspace {
    static func dropZone(for point: (x: Double, y: Double), in rect: (x: Double, y: Double, width: Double, height: Double)) -> DropZone? {
        DropZone.zone(for: point, in: rect)
    }

    // MARK: Docking

    /// Drops `panel` onto the tab group that contains `target`. `center` appends a tab and selects it; edges split the
    /// target group (new group gets 50 % of the target's share). The panel is first removed from its source group
    /// (empty groups and singleton splits collapse, fractions renormalise) and is shown if it was hidden.
    /// Returns false (workspace unchanged) for unknown panels or `panel == target`.
    @discardableResult
    mutating func dock(_ panel: PanelID, onto target: PanelID, zone: DropZone) -> Bool {
        guard panel != target, allPanels.contains(panel), allPanels.contains(target) else { return false }
        guard let stripped = Self.removing(panel, from: root), stripped.panels.contains(target) else { return false }
        let placed: LayoutNode
        switch zone {
        case .center:
            placed = Self.mapGroup(containing: target, in: stripped) { panels, _ in
                .tabs(panels: panels + [panel], selected: panel)
            }
        case .left, .right, .top, .bottom:
            placed = Self.splitting(target, in: stripped, with: panel, zone: zone)
        }
        root = Self.flattened(placed)
        hidden.remove(panel)
        maximized = nil
        return true
    }

    /// Reorders a tab inside its group. `index` is the final position and is clamped; the selection is kept.
    @discardableResult
    mutating func moveTab(_ panel: PanelID, toIndex index: Int) -> Bool {
        guard allPanels.contains(panel) else { return false }
        root = Self.mapGroup(containing: panel, in: root) { panels, selected in
            var p = panels
            p.removeAll { $0 == panel }
            p.insert(panel, at: min(max(index, 0), p.count))
            return .tabs(panels: p, selected: selected)
        }
        return true
    }

    /// Everything that violates the layout invariants; empty for a valid workspace.
    public var validationProblems: [String] {
        var problems: [String] = []
        let all = allPanels
        if Set(all).count != all.count { problems.append("duplicate panel") }
        Self.validate(root, &problems)
        return problems
    }

    // MARK: Tree surgery

    /// Tree without `panel`; nil when nothing is left. Removes empty groups, collapses singleton splits.
    private static func removing(_ panel: PanelID, from node: LayoutNode) -> LayoutNode? {
        switch node {
        case .tabs(let panels, let selected):
            guard panels.contains(panel) else { return node }
            let rest = panels.filter { $0 != panel }
            guard !rest.isEmpty else { return nil }
            if selected != panel { return .tabs(panels: rest, selected: selected) }
            let i = panels.firstIndex(of: panel) ?? 0
            return .tabs(panels: rest, selected: rest[min(i, rest.count - 1)])
        case .split(let axis, let children, let fractions):
            var kept: [LayoutNode] = [], fr: [Double] = []
            for (i, c) in children.enumerated() {
                if let n = removing(panel, from: c) { kept.append(n); fr.append(fractions[i]) }
            }
            if kept.count <= 1 { return kept.first }
            return .split(axis: axis, children: kept, fractions: kept.count == children.count ? fractions : Workspace.normalized(fr))
        }
    }

    private static func mapGroup(containing p: PanelID, in node: LayoutNode, _ f: ([PanelID], PanelID) -> LayoutNode) -> LayoutNode {
        switch node {
        case .tabs(let panels, let sel): panels.contains(p) ? f(panels, sel) : node
        case .split(let a, let c, let fr): .split(axis: a, children: c.map { mapGroup(containing: p, in: $0, f) }, fractions: fr)
        }
    }

    private static func splitting(_ target: PanelID, in node: LayoutNode, with panel: PanelID, zone: DropZone) -> LayoutNode {
        guard let axis = zone.axis else { return node }
        let new = LayoutNode.tabs(panels: [panel], selected: panel)
        switch node {
        case .tabs(let panels, _):
            guard panels.contains(target) else { return node }
            return .split(axis: axis, children: zone.insertsBefore ? [new, node] : [node, new], fractions: [0.5, 0.5])
        case .split(let a, let children, let fractions):
            let direct = children.firstIndex { if case .tabs(let p, _) = $0 { p.contains(target) } else { false } }
            if let i = direct, a == axis {
                // Same axis as the parent: insert as a sibling, halving the target's share.
                var c = children, f = fractions
                let half = f[i] / 2
                f[i] = half
                let at = zone.insertsBefore ? i : i + 1
                c.insert(new, at: at)
                f.insert(half, at: at)
                return .split(axis: a, children: c, fractions: f)
            }
            return .split(axis: a, children: children.map { splitting(target, in: $0, with: panel, zone: zone) }, fractions: fractions)
        }
    }

    /// Merges nested splits of the same axis into their parent and collapses singleton splits.
    private static func flattened(_ node: LayoutNode) -> LayoutNode {
        guard case .split(let axis, let children, let fractions) = node else { return node }
        var c: [LayoutNode] = [], f: [Double] = []
        for (i, child) in children.enumerated() {
            let n = flattened(child)
            if case .split(let a2, let c2, let f2) = n, a2 == axis {
                c += c2; f += f2.map { $0 * fractions[i] }
            } else { c.append(n); f.append(fractions[i]) }
        }
        if c.count == 1 { return c[0] }
        let sum = f.reduce(0, +)
        return .split(axis: axis, children: c, fractions: abs(sum - 1) < 1e-12 ? f : Workspace.normalized(f))
    }

    private static func validate(_ node: LayoutNode, _ out: inout [String]) {
        switch node {
        case .tabs(let panels, let selected):
            if panels.isEmpty { out.append("empty group") } else if !panels.contains(selected) { out.append("selected not in group") }
        case .split(_, let children, let fractions):
            if children.count < 2 { out.append("split with fewer than 2 children") }
            if children.count != fractions.count { out.append("fraction count mismatch") }
            if abs(fractions.reduce(0, +) - 1) > 1e-9 { out.append("fractions do not sum to 1") }
            for c in children { validate(c, &out) }
        }
    }

    /// This layout without the Color page's clip list (unchanged when it does not hold it or holds nothing else).
    var withoutColorClips: Workspace {
        guard allPanels.contains(.colorClips), let rest = Self.removing(.colorClips, from: root) else { return self }
        var w = self
        w.root = rest
        w.hidden.remove(.colorClips)
        if w.maximized == .colorClips { w.maximized = nil }
        return w
    }
}

// MARK: - Library

/// The user's workspaces plus edits to built-ins, persisted as versioned JSON. Built-ins cannot be deleted or renamed;
/// an edited built-in is stored as an override and can be reset to its default. Names compare case-insensitively.
public struct WorkspaceLibrary: Sendable, Codable, Hashable {
    public static let currentVersion = 1

    public enum LoadError: Error, Equatable { case unsupportedVersion(Int) }

    public private(set) var version: Int
    public private(set) var userWorkspaces: [Workspace]
    /// Edited built-ins, keyed by built-in name.
    public private(set) var builtInOverrides: [String: Workspace]

    public init(userWorkspaces: [Workspace] = [], builtInOverrides: [String: Workspace] = [:]) {
        self.version = Self.currentVersion
        self.userWorkspaces = userWorkspaces
        self.builtInOverrides = builtInOverrides
    }

    // MARK: Queries

    /// Built-ins (with overrides applied) followed by user workspaces.
    public var all: [Workspace] { Workspace.builtIns.map { builtInOverrides[$0.name] ?? $0 } + userWorkspaces }
    public var names: [String] { all.map(\.name) }
    public func workspace(named name: String) -> Workspace? { all.first { Self.same($0.name, name) } }
    public func isBuiltIn(_ name: String) -> Bool { Workspace.builtIns.contains { Self.same($0.name, name) } }
    public func isModifiedBuiltIn(_ name: String) -> Bool { builtInOverrides.keys.contains { Self.same($0, name) } }

    // MARK: Operations (false = rejected, library unchanged)

    /// Stores a copy of `workspace` under `name` (trimmed). Overwrites a user workspace of that name;
    /// rejects empty names and built-in names.
    @discardableResult
    public mutating func saveAs(_ name: String, from workspace: Workspace) -> Bool {
        let n = Self.clean(name)
        guard !n.isEmpty, !isBuiltIn(n) else { return false }
        var copy = workspace
        copy.name = n; copy.maximized = nil
        if let i = userWorkspaces.firstIndex(where: { Self.same($0.name, n) }) { userWorkspaces[i] = copy } else { userWorkspaces.append(copy) }
        return true
    }

    /// `base` if free, else `base 2`, `base 3`, ... (case-insensitive, also avoiding built-in names).
    public func suggestedNewName(base: String) -> String {
        let b = Self.clean(base).isEmpty ? "Workspace" : Self.clean(base)
        if workspace(named: b) == nil { return b }
        var n = 2
        while workspace(named: "\(b) \(n)") != nil { n += 1 }
        return "\(b) \(n)"
    }

    /// Saves edits in place: user workspaces are replaced, built-ins stored as override. False for unknown names.
    @discardableResult
    public mutating func update(_ workspace: Workspace) -> Bool {
        var w = workspace; w.maximized = nil
        if let b = Workspace.builtIns.first(where: { Self.same($0.name, workspace.name) }) {
            w.name = b.name
            builtInOverrides[b.name] = w
            return true
        }
        guard let i = userWorkspaces.firstIndex(where: { Self.same($0.name, workspace.name) }) else { return false }
        w.name = userWorkspaces[i].name
        userWorkspaces[i] = w
        return true
    }

    /// Renames a user workspace; rejects built-ins, empty names and collisions (a case-only change is fine).
    @discardableResult
    public mutating func rename(_ old: String, to new: String) -> Bool {
        let n = Self.clean(new)
        guard !n.isEmpty, !isBuiltIn(old), !isBuiltIn(n),
              let i = userWorkspaces.firstIndex(where: { Self.same($0.name, old) }) else { return false }
        if userWorkspaces.indices.contains(where: { $0 != i && Self.same(userWorkspaces[$0].name, n) }) { return false }
        userWorkspaces[i].name = n
        return true
    }

    /// Deletes a user workspace. Built-ins cannot be deleted.
    @discardableResult
    public mutating func delete(_ name: String) -> Bool {
        guard !isBuiltIn(name), let i = userWorkspaces.firstIndex(where: { Self.same($0.name, name) }) else { return false }
        userWorkspaces.remove(at: i)
        return true
    }

    /// Drops the override of a built-in. False when it was not modified.
    @discardableResult
    public mutating func resetBuiltIn(_ name: String) -> Bool {
        guard let key = builtInOverrides.keys.first(where: { Self.same($0, name) }) else { return false }
        builtInOverrides[key] = nil
        return true
    }

    /// Self-healing for persisted state: a user workspace whose name collides with a built-in (it would be shadowed and
    /// vanish from the list) or with an earlier user workspace is kept under a new name; overrides of unknown
    /// built-ins are dropped. Built-ins themselves are always listed (`all`), whatever the file held.
    public func healed() -> WorkspaceLibrary {
        var out = self
        var seen = Set(Workspace.builtIns.map { Self.clean($0.name).lowercased() })
        var users: [Workspace] = []
        for var w in userWorkspaces {
            var name = Self.clean(w.name)
            if name.isEmpty { name = "Workspace" }
            if seen.contains(name.lowercased()) {
                let base = name
                var n = 2
                name = "\(base) (saved)"
                while seen.contains(name.lowercased()) { name = "\(base) (saved \(n))"; n += 1 }
            }
            seen.insert(name.lowercased())
            w.name = name
            users.append(w)
        }
        out.userWorkspaces = users
        out.builtInOverrides = builtInOverrides.filter { k, _ in Workspace.builtIns.contains { $0.name == k } }
        return out
    }

    /// Drops every override: all built-ins are back at their shipped layout (user workspaces stay).
    public mutating func resetAllBuiltIns() { builtInOverrides = [:] }

    // MARK: Persistence

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }

    /// Rejects files written by a newer version.
    public static func decoded(from data: Data) throws -> WorkspaceLibrary {
        let lib = try JSONDecoder().decode(WorkspaceLibrary.self, from: data)
        guard lib.version <= currentVersion else { throw LoadError.unsupportedVersion(lib.version) }
        return lib
    }

    private static func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func same(_ a: String, _ b: String) -> Bool { clean(a).caseInsensitiveCompare(clean(b)) == .orderedSame }

    /// Edit layouts never dock the Color page's clip list: a stored layout that holds it loses it.
    func droppingColorClips() -> WorkspaceLibrary {
        var out = self
        out.userWorkspaces = userWorkspaces.map(\.withoutColorClips)
        out.builtInOverrides = builtInOverrides.mapValues(\.withoutColorClips)
        return out
    }
}
