import Foundation

/// Shelf a preset or template is listed under. Display names are our own words.
public enum PresetCategory: String, Codable, Sendable, CaseIterable {
    case titles, lowerThirds, captions, social, effects, transitions, motion, other

    public var title: String {
        switch self {
        case .titles: "Titles"
        case .lowerThirds: "Lower Thirds"
        case .captions: "Captions"
        case .social: "Social"
        case .effects: "Effects"
        case .transitions: "Transitions"
        case .motion: "Motion"
        case .other: "Other"
        }
    }

    /// Category a preset of this kind starts in until the user moves it.
    public static func defaultCategory(for kind: PresetKind) -> PresetCategory {
        switch kind {
        case .textTemplate, .animatedTextTemplate, .titleBlock, .titleTemplate: .titles
        case .caption: .captions
        case .effect: .effects
        case .transition: .transitions
        case .easing, .keystone: .motion
        }
    }

    /// Category of a built-in text template, guessed from its name.
    public static func inferred(fromName name: String) -> PresetCategory {
        let n = LibrarySearch.fold(name)
        if n.contains("lower third") || n.contains("lower-third") { return .lowerThirds }
        if n.contains("cta") || n.contains("end card") || n.contains("subscribe") || n.contains("follow") { return .social }
        if n.contains("caption") || n.contains("subtitle") { return .captions }
        return .titles
    }
}

/// What the user attached to a preset or built-in template. Stored beside the presets, never inside a project.
public struct PresetMeta: Codable, Sendable, Equatable {
    public var category: PresetCategory?
    public var tags: [String] = []
    public var isFavorite = false
    public var lastUsed: Date?
    public var useCount = 0

    public init(category: PresetCategory? = nil, tags: [String] = [], isFavorite: Bool = false, lastUsed: Date? = nil, useCount: Int = 0) {
        self.category = category; self.tags = tags; self.isFavorite = isFavorite; self.lastUsed = lastUsed; self.useCount = useCount
    }

    /// Nothing worth saving.
    var isDefault: Bool { self == PresetMeta() }
}

/// Stable key of one list entry: `user:<uuid>` for a saved preset, `builtin:<id>` for a shipped template.
public enum PresetKey {
    public static func user(_ id: UUID) -> String { "user:\(id.uuidString)" }
    public static func builtIn(_ id: String) -> String { "builtin:\(id)" }
}

/// Metadata of all presets, by `PresetKey`. Value type; the owner persists it with `PresetMetaStore`.
public struct PresetMetaTable: Sendable, Equatable {
    public static let maxTags = 8
    public static let maxTagLength = 24
    /// Tags offered in menus (other tags from files are kept and shown).
    public static let suggestedTags = ["bold", "clean", "minimal", "retro", "glow", "outline", "box", "news", "gaming", "cinematic"]

    public private(set) var entries: [String: PresetMeta] = [:]
    public init() {}

    public subscript(key: String) -> PresetMeta { entries[key] ?? PresetMeta() }

    private mutating func edit(_ key: String, _ change: (inout PresetMeta) -> Void) {
        var m = self[key]
        change(&m)
        if m.isDefault { entries[key] = nil } else { entries[key] = m }
    }

    /// Returns the new state (true = now a favorite).
    @discardableResult
    public mutating func toggleFavorite(_ key: String) -> Bool {
        var now = false
        edit(key) { $0.isFavorite.toggle(); now = $0.isFavorite }
        return now
    }

    public mutating func setCategory(_ key: String, _ category: PresetCategory?) { edit(key) { $0.category = category } }

    /// Lower-cased, trimmed, at most 24 characters; nil when empty.
    public static func normalizedTag(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return nil }
        return String(t.prefix(maxTagLength))
    }

    /// Ignored when empty, a duplicate, or the preset already has 8 tags.
    public mutating func addTag(_ key: String, _ raw: String) {
        guard let tag = Self.normalizedTag(raw) else { return }
        edit(key) { if !$0.tags.contains(tag), $0.tags.count < Self.maxTags { $0.tags.append(tag) } }
    }

    public mutating func removeTag(_ key: String, _ raw: String) {
        guard let tag = Self.normalizedTag(raw) else { return }
        edit(key) { $0.tags.removeAll { $0 == tag } }
    }

    public mutating func toggleTag(_ key: String, _ raw: String) {
        guard let tag = Self.normalizedTag(raw) else { return }
        if self[key].tags.contains(tag) { removeTag(key, tag) } else { addTag(key, tag) }
    }

    public mutating func recordUse(_ key: String, at date: Date = Date()) {
        edit(key) { $0.lastUsed = date; $0.useCount += 1 }
    }

    /// Drops metadata of user presets that no longer exist. Built-in keys always stay.
    public mutating func prune(keepingUserKeys live: Set<String>) {
        entries = entries.filter { $0.key.hasPrefix("builtin:") || live.contains($0.key) }
    }

    fileprivate mutating func restore(_ key: String, _ meta: PresetMeta) { if !meta.isDefault { entries[key] = meta } }
}

/// Versioned JSON persistence for `PresetMetaTable` (`<Application Support>/Sequence Studio/Library/preset-meta.json`).
public enum PresetMetaStore {
    public static let formatVersion = 1

    private struct File: Codable {
        var formatVersion: Int
        var entries: [String: PresetMeta]
    }

    public static func fileURL(applicationSupport: URL) -> URL {
        PresetStore.fileURL(applicationSupport: applicationSupport).deletingLastPathComponent().appendingPathComponent("preset-meta.json")
    }

    /// Newer file version throws (file untouched); a corrupt file is moved aside and the table starts empty.
    public static func load(from url: URL) throws -> PresetMetaTable {
        guard FileManager.default.fileExists(atPath: url.path) else { return PresetMetaTable() }
        let data = try Data(contentsOf: url)
        struct Header: Decodable { var formatVersion: Int }
        do {
            let header = try JSONDecoder().decode(Header.self, from: data)
            if header.formatVersion > formatVersion {
                throw LibraryStoreError.newerFormat(found: header.formatVersion, supported: formatVersion)
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var table = PresetMetaTable()
            for (k, v) in try decoder.decode(File.self, from: data).entries { table.restore(k, v) }
            return table
        } catch let error as LibraryStoreError {
            throw error
        } catch {
            try JSONFileIO.backupCorrupt(url)
            return PresetMetaTable()
        }
    }

    public static func save(_ table: PresetMetaTable, to url: URL) throws {
        try JSONFileIO.writeAtomically(File(formatVersion: formatVersion, entries: table.entries), to: url)
    }
}

// MARK: - Listing

/// One row of the preset list, built-in or user.
public struct PresetListEntry: Identifiable, Sendable, Equatable {
    public var key: String
    public var name: String
    public var isBuiltIn: Bool
    public var createdAt: Date
    public var category: PresetCategory
    public var meta: PresetMeta
    public var id: String { key }
    public var tags: [String] { meta.tags }

    public init(key: String, name: String, isBuiltIn: Bool, createdAt: Date = .distantPast, defaultCategory: PresetCategory, meta: PresetMeta) {
        self.key = key; self.name = name; self.isBuiltIn = isBuiltIn; self.createdAt = createdAt
        self.category = meta.category ?? defaultCategory; self.meta = meta
    }
}

public enum PresetSortKey: String, Sendable, CaseIterable {
    case name, newest, mostUsed, recentlyUsed

    public var title: String {
        switch self {
        case .name: "Name"
        case .newest: "Newest"
        case .mostUsed: "Most Used"
        case .recentlyUsed: "Recently Used"
        }
    }
}

/// Which part of the list is shown.
public enum PresetScope: String, Sendable, CaseIterable {
    case all, favorites, recent, builtIn, yours

    public var title: String {
        switch self {
        case .all: "All"
        case .favorites: "Favorites"
        case .recent: "Recent"
        case .builtIn: "Built-in"
        case .yours: "Yours"
        }
    }
}

public struct PresetFilter: Sendable, Equatable {
    public var query = ""
    public var category: PresetCategory?
    public var scope: PresetScope = .all
    public var tag: String?
    public init(query: String = "", category: PresetCategory? = nil, scope: PresetScope = .all, tag: String? = nil) {
        self.query = query; self.category = category; self.scope = scope; self.tag = tag
    }
    public var isActive: Bool { self != PresetFilter(query: query) }
}

public enum PresetOrganizer {
    /// Entries shown in the Recent scope.
    public static let recentLimit = 12

    /// Filter, then sort. Search matches name, tags and category title (all words must match).
    /// Natural order: name A-Z, newest first, most used first, last used first; `ascending: false` reverses it.
    /// Ties fall back to name.
    public static func visible(_ entries: [PresetListEntry], filter: PresetFilter, sort: PresetSortKey, ascending: Bool = true) -> [PresetListEntry] {
        let tokens = LibrarySearch.fold(filter.query).split(whereSeparator: \.isWhitespace).map(String.init)
        let tag = filter.tag.flatMap(PresetMetaTable.normalizedTag)
        var list = entries.filter { e in
            if let c = filter.category, e.category != c { return false }
            if let tag, !e.tags.contains(tag) { return false }
            switch filter.scope {
            case .all: break
            case .favorites: if !e.meta.isFavorite { return false }
            case .recent: if e.meta.lastUsed == nil { return false }
            case .builtIn: if !e.isBuiltIn { return false }
            case .yours: if e.isBuiltIn { return false }
            }
            if tokens.isEmpty { return true }
            let hay = LibrarySearch.fold(([e.name, e.category.title] + e.tags).joined(separator: " "))
            return tokens.allSatisfy { hay.contains($0) }
        }
        func byName(_ a: PresetListEntry, _ b: PresetListEntry) -> Bool {
            let c = LibrarySearch.fold(a.name).compare(LibrarySearch.fold(b.name), options: .numeric)
            return c == .orderedSame ? a.key < b.key : c == .orderedAscending
        }
        list.sort { a, b in
            switch sort {
            case .name: return byName(a, b)
            case .newest: return a.createdAt == b.createdAt ? byName(a, b) : a.createdAt > b.createdAt
            case .mostUsed: return a.meta.useCount == b.meta.useCount ? byName(a, b) : a.meta.useCount > b.meta.useCount
            case .recentlyUsed:
                let (x, y) = (a.meta.lastUsed ?? .distantPast, b.meta.lastUsed ?? .distantPast)
                return x == y ? byName(a, b) : x > y
            }
        }
        if filter.scope == .recent { list = Array(list.sorted { ($0.meta.lastUsed ?? .distantPast) > ($1.meta.lastUsed ?? .distantPast) }.prefix(recentLimit)) }
        if !ascending { list.reverse() }
        return list
    }

    /// Tags in use with their counts, most used first.
    public static func tagCounts(_ entries: [PresetListEntry]) -> [(tag: String, count: Int)] {
        var counts: [String: Int] = [:]
        for e in entries { for t in e.tags { counts[t, default: 0] += 1 } }
        return counts.map { (tag: $0.key, count: $0.value) }.sorted { $0.count == $1.count ? $0.tag < $1.tag : $0.count > $1.count }
    }

    public static func categoryCounts(_ entries: [PresetListEntry]) -> [PresetCategory: Int] {
        Dictionary(grouping: entries, by: \.category).mapValues(\.count)
    }
}

// MARK: - Hover card text

/// Text lines of the hover card of a preset or template. Pure so it can be tested.
public enum PresetHoverInfo {
    public static func lines(for e: PresetListEntry) -> [String] {
        var out = ["\(e.isBuiltIn ? "Built-in" : "Yours") · \(e.category.title)"]
        if !e.tags.isEmpty { out.append(e.tags.map { "#\($0)" }.joined(separator: " ")) }
        if e.meta.useCount > 0 { out.append("Used \(e.meta.useCount) \(e.meta.useCount == 1 ? "time" : "times")") }
        if e.meta.isFavorite { out.append("Favorite") }
        return out
    }
}
