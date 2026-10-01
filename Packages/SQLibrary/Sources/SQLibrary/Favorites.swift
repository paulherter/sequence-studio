import Foundation

public enum LibraryStoreError: Error, Equatable, Sendable {
    case newerFormat(found: Int, supported: Int)
    case emptyName
    case notFound
    case duplicateID
}

/// Set of favorite entries keyed by stable entry id.
public struct Favorites: Sendable, Equatable {
    public private(set) var ids: Set<LibraryEntryID>
    public init(ids: Set<LibraryEntryID> = []) { self.ids = ids }

    public func contains(_ id: LibraryEntryID) -> Bool { ids.contains(id) }
    public mutating func add(_ id: LibraryEntryID) { ids.insert(id) }
    public mutating func remove(_ id: LibraryEntryID) { ids.remove(id) }
    /// Returns the new state (true = now favorite).
    @discardableResult
    public mutating func toggle(_ id: LibraryEntryID) -> Bool {
        if ids.remove(id) != nil { return false }
        ids.insert(id)
        return true
    }
}

/// Versioned JSON persistence for `Favorites`.
public enum FavoritesStore {
    public static let formatVersion = 1

    private struct File: Codable {
        var formatVersion: Int
        var items: [LibraryEntryID]
    }

    public static func load(from url: URL) throws -> Favorites {
        guard FileManager.default.fileExists(atPath: url.path) else { return Favorites() }
        let data = try Data(contentsOf: url)
        struct Header: Decodable { var formatVersion: Int }
        do {
            let header = try JSONDecoder().decode(Header.self, from: data)
            if header.formatVersion > formatVersion {
                throw LibraryStoreError.newerFormat(found: header.formatVersion, supported: formatVersion)
            }
            return Favorites(ids: Set(try JSONDecoder().decode(File.self, from: data).items))
        } catch let error as LibraryStoreError {
            throw error
        } catch {
            try JSONFileIO.backupCorrupt(url)
            return Favorites()
        }
    }

    public static func save(_ favorites: Favorites, to url: URL) throws {
        let items = favorites.ids.sorted { ($0.relativePath, $0.folderID.uuidString) < ($1.relativePath, $1.folderID.uuidString) }
        try JSONFileIO.writeAtomically(File(formatVersion: formatVersion, items: items), to: url)
    }
}

/// Shared helpers for versioned JSON files.
enum JSONFileIO {
    static func writeAtomically<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Number of `<name>.corrupt-*` backups kept per file name.
    static let corruptBackupsToKeep = 3

    static func backupCorrupt(_ url: URL) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        let prefix = "\(url.lastPathComponent).corrupt-"
        let stamp = Int(Date().timeIntervalSince1970)
        // Next free counter for this second: max existing + 1, so pruning never frees a lower name that would sort as oldest.
        let existing = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        let used = existing.compactMap { order(of: $0, prefix: prefix) }.filter { $0.stamp == stamp }
        var name = "\(prefix)\(stamp)"
        if !used.isEmpty { name += "-\((used.map(\.n).max() ?? 0) + 1)" }
        try fm.moveItem(at: url, to: dir.appendingPathComponent(name))
        pruneCorruptBackups(of: url)
    }

    private static func order(of fileName: String, prefix: String) -> (stamp: Int, n: Int)? {
        guard fileName.hasPrefix(prefix) else { return nil }
        let parts = fileName.dropFirst(prefix.count).split(separator: "-", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let stamp = Int(parts[0]) else { return nil }
        if parts.count == 1 { return (stamp, 0) }
        guard let n = Int(parts[1]) else { return nil }
        return (stamp, n)
    }

    /// Keeps the newest `corruptBackupsToKeep` backups of this file name (by name stamp, then counter); siblings of other names are untouched.
    static func pruneCorruptBackups(of url: URL) {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        let prefix = "\(url.lastPathComponent).corrupt-"
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        let backups = names.compactMap { name in order(of: name, prefix: prefix).map { (name, $0) } }
            .sorted { ($0.1.stamp, $0.1.n) > ($1.1.stamp, $1.1.n) }
        for (name, _) in backups.dropFirst(corruptBackupsToKeep) {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }
}
