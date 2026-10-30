import Foundation
import SQCore
import SQText
import SQUIKit
import SQEditorSession

/// A folder the user made in the Effects panel. Items are effect / transition / preset row ids (`EffectsEntry.id`).
public struct UserEffectFolder: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var items: [String]
}

/// The user's own Effects panel folders. Lives in UserDefaults (not in the project file): it is a personal library layout.
public struct EffectFolderStore: Codable, Sendable, Hashable {
    public static let key = "sq.effects.userFolders"
    public private(set) var folders: [UserEffectFolder] = []
    public init() {}

    public func folder(_ id: UUID) -> UserEffectFolder? { folders.first { $0.id == id } }

    /// Empty names become "New Folder"; taken names get " 2", " 3", ...
    private func uniqueName(_ raw: String, excluding: UUID? = nil) -> String {
        let base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = base.isEmpty ? "New Folder" : base
        let taken = Set(folders.filter { $0.id != excluding }.map { $0.name.lowercased() })
        guard taken.contains(name.lowercased()) else { return name }
        var n = 2
        while taken.contains("\(name) \(n)".lowercased()) { n += 1 }
        return "\(name) \(n)"
    }

    @discardableResult
    public mutating func createFolder(named name: String) -> UUID {
        let f = UserEffectFolder(id: UUID(), name: uniqueName(name), items: [])
        folders.append(f)
        return f.id
    }

    public mutating func rename(_ id: UUID, to name: String) {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        folders[i].name = uniqueName(trimmed, excluding: id)
    }

    public mutating func delete(_ id: UUID) { folders.removeAll { $0.id == id } }

    public mutating func add(_ item: String, to id: UUID) {
        guard let i = folders.firstIndex(where: { $0.id == id }), !folders[i].items.contains(item) else { return }
        folders[i].items.append(item)
    }

    public mutating func remove(_ item: String, from id: UUID) {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[i].items.removeAll { $0 == item }
    }

    /// Drag-reorder of user folders: `id` goes in front of `target` (nil = last).
    public mutating func move(_ id: UUID, before target: UUID?) {
        guard id != target, let from = folders.firstIndex(where: { $0.id == id }) else { return }
        let f = folders.remove(at: from)
        let to = target.flatMap { t in folders.firstIndex { $0.id == t } } ?? folders.count
        folders.insert(f, at: to)
    }

    public static func load(from defaults: UserDefaults = .standard) -> EffectFolderStore {
        guard let data = defaults.data(forKey: key), let s = try? JSONDecoder().decode(EffectFolderStore.self, from: data) else { return EffectFolderStore() }
        return s
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}

/// Builds the Effects panel rows: folders (Presets, Video > category, Transitions / Crossfades) plus the
/// user's folders on top. Pure, so ordering, expansion and search are tested without a view.
public enum EffectFolderOutline {
    public static let expandedKey = "sq.effects.expandedFolders"
    public static let presetsFolder = "Presets", effectsFolder = "Video Effects"
    public static let videoTransitions = "Video Transitions", audioTransitions = "Audio Transitions"
    public static let audioEffectsFolder = "Audio Effects"
    public static let textFolder = "Text"
    public static let builtinOrder = [presetsFolder, textFolder, effectsFolder, videoTransitions, audioEffectsFolder, audioTransitions]

    /// Shown names of the top-level bins (docs/VOCABULARY.md). Folder ids, saved expansion state and entry categories keep
    /// the stored names; only the display changes.
    public static let displayNames: [String: String] = [
        effectsFolder: "Video", videoTransitions: "Transitions", audioEffectsFolder: "Audio", audioTransitions: "Crossfades",
    ]
    public static func displayName(_ name: String) -> String { displayNames[name] ?? name }

    public static func builtinID(_ folder: String, _ sub: String? = nil) -> String {
        "folder.builtin." + folder + (sub.map { "/" + $0 } ?? "")
    }
    public static func userID(_ id: UUID) -> String { "folder.user." + id.uuidString }

    public static func loadExpanded(from d: UserDefaults = .standard) -> Set<String> { Set(d.stringArray(forKey: expandedKey) ?? []) }
    public static func saveExpanded(_ ids: Set<String>, to d: UserDefaults = .standard) { d.set(ids.sorted(), forKey: expandedKey) }

    /// Where an entry sits: (top-level folder, sub-folder or nil).
    public static func location(of e: EffectsEntry) -> (String, String?) {
        if e.id.hasPrefix("preset.") { return (presetsFolder, nil) }
        if TextPresetCatalog.isTextPresetID(e.id) { return (textFolder, e.category) }
        if e.category == videoTransitions || e.category == audioTransitions { return (e.category, nil) }
        if ClipEffect.isAudioKind(e.id) { return (audioEffectsFolder, e.category) }
        return (effectsFolder, e.category)
    }

    /// The effects a folder row carries when it is dragged onto a clip or Effect Controls: every applicable effect inside
    /// it, in order. Transitions and presets are skipped (they apply elsewhere), so the Presets and transition folders
    /// carry nothing and cannot be dragged.
    public static func effectIDs(forFolder folderID: String, entries: [EffectsEntry], store: EffectFolderStore) -> [String] {
        func applicable(_ id: String) -> Bool { !id.hasPrefix("preset.") && !id.hasPrefix("transition.") && !TextPresetCatalog.isTextPresetID(id) }
        if folderID.hasPrefix("folder.user.") {
            guard let uuid = UUID(uuidString: String(folderID.dropFirst("folder.user.".count))), let f = store.folder(uuid) else { return [] }
            let known = Set(entries.map(\.id))
            return f.items.filter { known.contains($0) && applicable($0) }
        }
        let prefix = "folder.builtin."
        guard folderID.hasPrefix(prefix) else { return [] }
        let parts = folderID.dropFirst(prefix.count).split(separator: "/", maxSplits: 1).map(String.init)
        guard let top = parts.first else { return [] }
        return entries.filter { e in
            let loc = location(of: e)
            return loc.0 == top && (parts.count < 2 || loc.1 == parts[1]) && applicable(e.id)
        }.map(\.id)
    }

    /// Effect-id pasteboard string (`EffectDragPayload`).
    public static func encodeDrag(_ ids: [String]) -> String { EffectDragPayload.encodeDrag(ids) }
    public static func decodeDrag(_ s: String) -> [String] { EffectDragPayload.decodeDrag(s) }

    public enum Key: Sendable { case left, right }
    public enum Navigation: Sendable, Equatable { case none, toggle(String), select(Int) }

    /// Outline keys on the selected row: right opens a closed folder, then steps into it; left closes an open folder,
    /// then steps out to the parent folder (also from an item).
    public static func keyNavigation(rows: [EffectsRow], selected: Int, key: Key) -> Navigation {
        guard rows.indices.contains(selected) else { return .none }
        let r = rows[selected]
        switch key {
        case .right:
            guard r.isFolder else { return .none }
            if !r.isExpanded { return .toggle(r.id) }
            let next = selected + 1
            return rows.indices.contains(next) && rows[next].depth > r.depth ? .select(next) : .none
        case .left:
            if r.isFolder && r.isExpanded { return .toggle(r.id) }
            guard let parent = rows[..<selected].lastIndex(where: { $0.isFolder && $0.depth < r.depth }) else { return .none }
            return .select(parent)
        }
    }

    public static func rows(entries: [EffectsEntry], store: EffectFolderStore, expanded: Set<String>,
                            query: String, collapsedInSearch: Set<String> = []) -> [EffectsRow] {
        typealias Row = EffectsRow
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let searching = !q.isEmpty
        func matches(_ e: EffectsEntry) -> Bool { !searching || e.matches(query: q) }
        func item(_ e: EffectsEntry, depth: Int, id: String, folder: UUID? = nil) -> Row {
            var r = Row(id: id, title: e.title, symbol: e.symbol)
            r.depth = depth; r.payload = e.id; r.userFolder = folder
            return r
        }
        func folderRow(_ id: String, _ title: String, depth: Int, open: Bool, user: UUID? = nil, symbol: SQIcon = .folder) -> Row {
            var r = Row(id: id, title: title, symbol: symbol)
            r.isFolder = true; r.depth = depth; r.isExpanded = open; r.userFolder = user
            return r
        }
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [Row] = []

        for f in store.folders {
            let contents = f.items.compactMap { byID[$0] }.filter(matches)
            if searching && contents.isEmpty { continue }
            let fid = userID(f.id)
            let open = searching ? !collapsedInSearch.contains(fid) : expanded.contains(fid)
            var fr = folderRow(fid, f.name, depth: 0, open: open, user: f.id, symbol: .folderFilled)
            fr.count = contents.count
            out.append(fr)
            if open { out += contents.map { item($0, depth: 1, id: "\(fid)|\($0.id)", folder: f.id) } }
        }

        let hits = entries.filter(matches)
        for top in builtinOrder {
            let inTop = hits.filter { location(of: $0).0 == top }
            guard !inTop.isEmpty else { continue }
            let tid = builtinID(top)
            let topOpen = searching ? !collapsedInSearch.contains(tid) : expanded.contains(tid)
            var tr = folderRow(tid, displayName(top), depth: 0, open: topOpen)
            tr.count = inTop.count
            out.append(tr)
            guard topOpen else { continue }
            var subs: [String] = []
            for e in inTop { if let s = location(of: e).1, !subs.contains(s) { subs.append(s) } }
            for e in inTop where location(of: e).1 == nil { out.append(item(e, depth: 1, id: e.id)) }
            for s in subs {
                let sid = builtinID(top, s)
                let sOpen = searching ? !collapsedInSearch.contains(sid) : expanded.contains(sid)
                out.append(folderRow(sid, displayName(s), depth: 1, open: sOpen))
                if sOpen { out += inTop.filter { location(of: $0).1 == s }.map { item($0, depth: 2, id: $0.id) } }
            }
        }
        return out
    }
}
