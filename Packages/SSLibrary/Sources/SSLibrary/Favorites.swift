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

    static func backupCorrupt(_ url: URL) throws {
        let stamp = Int(Date().timeIntervalSince1970)
        var backup = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).corrupt-\(stamp)")
        var n = 1
        while FileManager.default.fileExists(atPath: backup.path) {
            backup = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).corrupt-\(stamp)-\(n)")
            n += 1
        }
        try FileManager.default.moveItem(at: url, to: backup)
    }
}
