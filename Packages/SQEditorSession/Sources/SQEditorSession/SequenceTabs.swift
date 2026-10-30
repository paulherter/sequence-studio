import Foundation
import SQCore

/// Open sequences as tabs over the timeline. Each tab starts at a root sequence and can drill into nested sequences:
/// its `path` (root first) is the breadcrumb, the last entry is what the timeline shows. Pure value type.
public struct SequenceTabs: Equatable, Sendable {
    public struct Tab: Equatable, Sendable {
        public var path: [Timeline.ID]
        public var root: Timeline.ID { path[0] }
        public var shown: Timeline.ID { path[path.count - 1] }
    }

    public private(set) var tabs: [Tab] = []
    public private(set) var activeIndex: Int?

    public init() {}

    /// The sequence the timeline shows.
    public var current: Timeline.ID? { activeIndex.map { tabs[$0].shown } }
    /// Root-first path of the active tab.
    public var breadcrumb: [Timeline.ID] { activeIndex.map { tabs[$0].path } ?? [] }

    /// Opens `id` as a tab (or activates the tab that shows it / has it in its path).
    public mutating func open(_ id: Timeline.ID) {
        if let i = tabs.firstIndex(where: { $0.root == id }) {
            tabs[i].path.removeSubrange(1...)
            activeIndex = i; return
        }
        if let i = tabs.firstIndex(where: { $0.path.contains(id) }) {
            if let k = tabs[i].path.firstIndex(of: id) { tabs[i].path.removeSubrange((k + 1)...) }
            activeIndex = i; return
        }
        tabs.append(Tab(path: [id]))
        activeIndex = tabs.count - 1
    }

    public mutating func select(_ root: Timeline.ID) {
        if let i = tabs.firstIndex(where: { $0.root == root }) { activeIndex = i }
    }

    /// Closes the tab with this root. Returns the sequence to show afterwards (nil = no tabs left).
    @discardableResult
    public mutating func close(_ root: Timeline.ID) -> Timeline.ID? {
        guard let i = tabs.firstIndex(where: { $0.root == root }) else { return current }
        let wasActive = activeIndex == i
        tabs.remove(at: i)
        if tabs.isEmpty { activeIndex = nil }
        else if wasActive { activeIndex = min(i, tabs.count - 1) }
        else if let a = activeIndex, a > i { activeIndex = a - 1 }
        return current
    }

    /// Drills into a nested sequence inside the active tab. A sequence already in the path cuts the path back to it.
    public mutating func enter(_ id: Timeline.ID) {
        guard let i = activeIndex else { open(id); return }
        if let k = tabs[i].path.firstIndex(of: id) { tabs[i].path.removeSubrange((k + 1)...) }
        else { tabs[i].path.append(id) }
    }

    /// Breadcrumb click: back out to `id` in the active tab's path.
    public mutating func popTo(_ id: Timeline.ID) {
        guard let i = activeIndex, let k = tabs[i].path.firstIndex(of: id) else { return }
        tabs[i].path.removeSubrange((k + 1)...)
    }

    /// Moves the tab with this root to `index` (clamped); the active tab stays the same tab.
    public mutating func move(_ root: Timeline.ID, to index: Int) {
        guard let from = tabs.firstIndex(where: { $0.root == root }) else { return }
        let activeRoot = activeIndex.map { tabs[$0].root }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: min(max(index, 0), tabs.count))
        if let r = activeRoot { activeIndex = tabs.firstIndex(where: { $0.root == r }) }
    }

    /// Drops sequences that no longer exist: paths are cut at the first missing one, tabs with a missing root close.
    /// `rootable` (default: `existing`) are the sequences that may be a tab's root: Groups exist but are never tabs.
    public mutating func prune(existing: Set<Timeline.ID>, rootable: Set<Timeline.ID>? = nil) {
        let activeRoot = activeIndex.map { tabs[$0].root }
        let roots = rootable ?? existing
        tabs = tabs.compactMap { tab in
            guard existing.contains(tab.root), roots.contains(tab.root) else { return nil }
            var t = tab
            if let k = t.path.firstIndex(where: { !existing.contains($0) }) { t.path.removeSubrange(k...) }
            return t
        }
        if tabs.isEmpty { activeIndex = nil }
        else if let r = activeRoot, let i = tabs.firstIndex(where: { $0.root == r }) { activeIndex = i }
        else { activeIndex = min(activeIndex ?? 0, tabs.count - 1) }
    }
}
