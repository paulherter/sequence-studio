import Foundation

/// The start window's Recents list: newest first, one entry per file, capped. Pure value; the app persists it
/// (`UserDefaults`, key `sq.recentProjects`) and passes a file-exists check to `pruned`.
public struct RecentProjects: Sendable, Equatable, Codable {
    public struct Entry: Sendable, Equatable, Codable, Identifiable {
        public var path: String
        public var name: String
        public var opened: Date
        public var id: String { path }
        public init(path: String, name: String, opened: Date) { self.path = path; self.name = name; self.opened = opened }
        public var url: URL { URL(fileURLWithPath: path) }
    }

    public static let limit = 12
    public private(set) var entries: [Entry]

    public init(entries: [Entry] = []) { self.entries = Array(entries.prefix(Self.limit)) }

    /// A saved list is normalized on load (one entry per file, capped), so a hand-edited or older default cannot break the list.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.container(keyedBy: CodingKeys.self).decode([Entry].self, forKey: .entries)
        var seen = Set<String>()
        self.init(entries: raw.filter { seen.insert($0.path).inserted })
    }
    private enum CodingKeys: String, CodingKey { case entries }

    /// Remembers a project: moves it to the top (no duplicates), keeps `limit` entries.
    public mutating func note(_ url: URL, now: Date = Date()) {
        let path = url.standardizedFileURL.path
        entries.removeAll { $0.path == path }
        entries.insert(Entry(path: path, name: url.deletingPathExtension().lastPathComponent, opened: now), at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    public mutating func remove(path: String) { entries.removeAll { $0.path == path } }
    public mutating func clear() { entries = [] }

    /// Paths of entries whose file is gone (the start window shows them grayed with "Locate…").
    public func missing(exists: (String) -> Bool) -> [String] { entries.map(\.path).filter { !exists($0) } }

    /// The newest entry whose file is still there: the start window's "Continue" target.
    public func mostRecent(missing: Set<String>) -> Entry? { entries.first { !missing.contains($0.path) } }

    /// With "Reopen last project on launch" on: the newest recent whose file exists (opened instead of the start window).
    public func launchReopenTarget(enabled: Bool, exists: (String) -> Bool) -> Entry? {
        guard enabled else { return nil }
        return entries.first { exists($0.path) }
    }

    /// "Locate…": the entry at `path` now lives at `url`. It keeps its place in the list; another entry already at `url` is dropped.
    public mutating func relocate(path: String, to url: URL) {
        guard let i = entries.firstIndex(where: { $0.path == path }) else { return }
        var moved = entries.remove(at: i)
        moved.path = url.standardizedFileURL.path
        moved.name = url.deletingPathExtension().lastPathComponent
        entries.removeAll { $0.path == moved.path }
        entries.insert(moved, at: min(i, entries.count))
    }

    /// Entries whose file is still there.
    public func pruned(exists: (String) -> Bool) -> RecentProjects {
        RecentProjects(entries: entries.filter { exists($0.path) })
    }

    // MARK: Persistence

    public static func load(from defaults: UserDefaults = .standard, key: String = "sq.recentProjects") -> RecentProjects {
        guard let data = defaults.data(forKey: key), let r = try? JSONDecoder().decode(RecentProjects.self, from: data) else { return RecentProjects() }
        return r
    }

    public func save(to defaults: UserDefaults = .standard, key: String = "sq.recentProjects") {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: key) }
    }
}

extension RecentProjects {
    public enum Order: Sendable { case opened, name, size }

    /// The start window's Recent list: entries whose name contains the trimmed query (case-insensitive), in the chosen order.
    /// `.opened` keeps the stored order (newest first); `.name` is Finder-style numeric; `.size` is largest frame first,
    /// unknown sizes last, ties by most recently opened.
    public static func listing(_ entries: [Entry], query: String, order: Order, pixels: (String) -> Int?) -> [Entry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let hits = q.isEmpty ? entries : entries.filter { $0.name.localizedCaseInsensitiveContains(q) }
        switch order {
        case .opened: return hits
        case .name: return hits.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .size:
            return hits.sorted {
                let a = pixels($0.path) ?? 0, b = pixels($1.path) ?? 0
                return a != b ? a > b : $0.opened > $1.opened
            }
        }
    }
}
