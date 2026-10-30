import Foundation

/// One section of a Library folder: "All" (every item, recursive) or one subfolder (its own items; nested subfolders
/// are further groups with a greater depth).
public struct LibraryGroup: Sendable, Equatable, Identifiable {
    public static let allID = "*"
    /// "*" for All, else the subfolder path relative to the library folder.
    public var id: String
    public var title: String
    public var depth: Int
    public var parentID: String?
    /// Items directly in this folder (All: every item). Empty while collapsed in `visible(_:collapsed:)`.
    public var entries: [LibraryEntry]
    /// Items in this folder and below (shown as the count in the header).
    public var totalCount: Int
    public var isCollapsed = false
    public var isAll: Bool { id == Self.allID }
}

public enum LibraryGrouping {
    /// Sections for one folder's entries (already filtered and sorted; order is kept). Empty when no entry sits in a
    /// subfolder: the panel then shows a plain flat list.
    public static func groups(_ entries: [LibraryEntry]) -> [LibraryGroup] {
        var direct: [String: [LibraryEntry]] = [:]
        var total: [String: Int] = [:]
        var anySub = false
        for entry in entries {
            let parts = entry.relativePath.split(separator: "/").dropLast()
            guard !parts.isEmpty else { continue }
            anySub = true
            var path = ""
            for (i, p) in parts.enumerated() {
                path = i == 0 ? String(p) : path + "/" + p
                total[path, default: 0] += 1
            }
            direct[path, default: []].append(entry)
        }
        guard anySub else { return [] }
        let paths = total.keys.sorted { a, b in
            let ca = a.split(separator: "/").map(String.init), cb = b.split(separator: "/").map(String.init)
            for (x, y) in zip(ca, cb) where x != y {
                let r = x.compare(y, options: [.caseInsensitive, .numeric])
                return r == .orderedSame ? x < y : r == .orderedAscending
            }
            return ca.count < cb.count
        }
        var out = [LibraryGroup(id: LibraryGroup.allID, title: "All", depth: 0, parentID: nil, entries: entries, totalCount: entries.count)]
        for p in paths {
            let comps = p.split(separator: "/")
            out.append(LibraryGroup(
                id: p, title: String(comps.last ?? ""), depth: comps.count - 1,
                parentID: comps.count > 1 ? comps.dropLast().joined(separator: "/") : nil,
                entries: direct[p] ?? [], totalCount: total[p] ?? 0))
        }
        return out
    }

    /// Applies collapsed state: a collapsed group keeps its header but shows no items; its descendants disappear.
    public static func visible(_ groups: [LibraryGroup], collapsed: Set<String>) -> [LibraryGroup] {
        var result: [LibraryGroup] = []
        for var g in groups {
            if let p = g.parentID, !isShown(parent: p, in: result) { continue }
            if collapsed.contains(g.id) { g.isCollapsed = true; g.entries = [] }
            result.append(g)
        }
        return result
    }

    /// A child is shown when every ancestor header is present and not collapsed.
    private static func isShown(parent: String, in result: [LibraryGroup]) -> Bool {
        guard let g = result.last(where: { $0.id == parent }) else { return false }
        return !g.isCollapsed
    }
}
