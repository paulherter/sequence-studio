import Foundation

public enum PresetKind: String, Codable, Sendable, CaseIterable {
    case textTemplate, animatedTextTemplate, easing, caption, effect
}

/// A user preset. `payload` is opaque versioned JSON owned by the feature that created it.
public struct PresetItem: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var kind: PresetKind
    public var name: String
    public var createdAt: Date
    public var payload: Data
    public var payloadVersion: Int

    public init(id: UUID = UUID(), kind: PresetKind, name: String, createdAt: Date = Date(), payload: Data, payloadVersion: Int) {
        self.id = id
        self.kind = kind
        self.name = name
        self.createdAt = createdAt
        self.payload = payload
        self.payloadVersion = payloadVersion
    }
}

/// User preset store: `<Application Support>/Sequence Studio/Library/presets.json`.
public actor PresetStore {
    public static let formatVersion = 1

    private struct File: Codable {
        var formatVersion: Int
        var presets: [PresetItem]
    }

    public nonisolated let fileURL: URL
    private var items: [PresetItem]

    public static func fileURL(applicationSupport: URL) -> URL {
        applicationSupport
            .appendingPathComponent("Sequence Studio", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("presets.json")
    }

    public static func defaultApplicationSupport() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// Loads the store. Newer file version throws (file untouched); a corrupt file is moved aside and the store starts empty.
    public init(applicationSupport: URL) throws {
        let url = Self.fileURL(applicationSupport: applicationSupport)
        fileURL = url
        items = try Self.load(url)
    }

    private static func load(_ url: URL) throws -> [PresetItem] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        struct Header: Decodable { var formatVersion: Int }
        do {
            let header = try JSONDecoder().decode(Header.self, from: data)
            if header.formatVersion > formatVersion {
                throw LibraryStoreError.newerFormat(found: header.formatVersion, supported: formatVersion)
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(File.self, from: data).presets
        } catch let error as LibraryStoreError {
            throw error
        } catch {
            try JSONFileIO.backupCorrupt(url)
            return []
        }
    }

    public func all() -> [PresetItem] { items }

    public func preset(_ id: UUID) -> PresetItem? { items.first { $0.id == id } }

    /// Presets of one kind (nil = all), optionally filtered by name tokens, sorted by name.
    public func presets(kind: PresetKind?, query: String = "") -> [PresetItem] {
        let tokens = LibrarySearch.fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        return items
            .filter { kind == nil || $0.kind == kind }
            .filter { item in
                let name = LibrarySearch.fold(item.name)
                return tokens.allSatisfy { name.contains($0) }
            }
            .sorted {
                let c = LibrarySearch.fold($0.name).compare(LibrarySearch.fold($1.name), options: .numeric)
                return c == .orderedSame ? $0.createdAt < $1.createdAt : c == .orderedAscending
            }
    }

    public func add(_ item: PresetItem) throws {
        var item = item
        item.name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !item.name.isEmpty else { throw LibraryStoreError.emptyName }
        guard !items.contains(where: { $0.id == item.id }) else { throw LibraryStoreError.duplicateID }
        try commit(items + [item])
    }

    public func rename(_ id: UUID, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LibraryStoreError.emptyName }
        try mutate(id) { $0.name = trimmed }
    }

    public func updatePayload(_ id: UUID, payload: Data, version: Int) throws {
        try mutate(id) { $0.payload = payload; $0.payloadVersion = version }
    }

    public func delete(_ id: UUID) throws {
        guard items.contains(where: { $0.id == id }) else { throw LibraryStoreError.notFound }
        try commit(items.filter { $0.id != id })
    }

    private func mutate(_ id: UUID, _ change: (inout PresetItem) -> Void) throws {
        guard let i = items.firstIndex(where: { $0.id == id }) else { throw LibraryStoreError.notFound }
        var copy = items
        change(&copy[i])
        try commit(copy)
    }

    /// Writes first, then swaps the in-memory state, so a failed write leaves both unchanged.
    private func commit(_ new: [PresetItem]) throws {
        try JSONFileIO.writeAtomically(File(formatVersion: Self.formatVersion, presets: new), to: fileURL)
        items = new
    }
}
