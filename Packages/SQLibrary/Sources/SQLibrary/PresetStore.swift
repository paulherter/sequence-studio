import Foundation
import SQCore

public enum PresetKind: String, Codable, Sendable, CaseIterable {
    case textTemplate, animatedTextTemplate, easing, caption, effect, transition
    /// G1: a keyframe building block (`Keystone` payload); a saved built-in keeps the built-in's id and overrides it.
    case keystone
    /// A saved title: generator clips with their element transitions (`TitleBlock` payload). Listed under Text Templates.
    case titleBlock
    /// A saved multi-layer title (`TitleTemplatePreset` payload: layers, slots, animation zones). Listed under Titles.
    case titleTemplate
}

/// A user preset. `payload` is opaque versioned JSON owned by the feature that created it.
public struct PresetItem: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var kind: PresetKind
    public var name: String
    public var createdAt: Date
    public var payload: Data
    public var payloadVersion: Int
    /// Name of the `.sqpack` this preset was imported from (shown as a Library folder); nil for presets the user made.
    public var pack: String?

    public init(id: UUID = UUID(), kind: PresetKind, name: String, createdAt: Date = Date(), payload: Data, payloadVersion: Int,
                pack: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.createdAt = createdAt
        self.payload = payload
        self.payloadVersion = payloadVersion
        self.pack = pack
    }
}

/// User preset store: `<Application Support>/Sequence Studio/Library/presets.json`.
public actor PresetStore {
    public static let formatVersion = 1

    private struct File: Codable {
        var formatVersion: Int
        var presets: [PresetItem]
    }

    /// Where the presets of this store come from. Only `.file` says what the user's presets are: a preset missing from
    /// a `.recovered` or `.standIn` store was not deleted by the user.
    public enum Origin: Sendable, Equatable {
        /// `presets.json` as it was read (or no file yet).
        case file
        /// `presets.json` was damaged: it was moved aside and the store started empty.
        case recovered
        /// An empty store used in place of a `presets.json` that could not be opened (written by a newer build).
        case standIn
    }

    public nonisolated let fileURL: URL
    public nonisolated let origin: Origin
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
    /// `standIn`: this store replaces one that could not be opened (`Origin.standIn`).
    public init(applicationSupport: URL, standIn: Bool = false) throws {
        let url = Self.fileURL(applicationSupport: applicationSupport)
        fileURL = url
        let loaded = try Self.load(url)
        items = loaded.items
        origin = standIn ? .standIn : loaded.recovered ? .recovered : .file
    }

    private static func load(_ url: URL) throws -> (items: [PresetItem], recovered: Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else { return ([], false) }
        let data = try Data(contentsOf: url)
        struct Header: Decodable { var formatVersion: Int }
        do {
            let header = try JSONDecoder().decode(Header.self, from: data)
            if header.formatVersion > formatVersion {
                throw LibraryStoreError.newerFormat(found: header.formatVersion, supported: formatVersion)
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return (try decoder.decode(File.self, from: data).presets, false)
        } catch let error as LibraryStoreError {
            throw error
        } catch {
            try JSONFileIO.backupCorrupt(url)
            return ([], true)
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

    /// Adds `new` and replaces the payload and name of the presets in `replacing` (id -> new item) in one write.
    func commitBatch(adding new: [PresetItem], replacing: [UUID: PresetItem]) throws {
        var copy = items.map { old -> PresetItem in
            guard let r = replacing[old.id] else { return old }
            var u = old
            u.payload = r.payload; u.payloadVersion = r.payloadVersion; u.name = r.name
            return u
        }
        copy.append(contentsOf: new)
        try commit(copy)
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

// MARK: - .sqpreset files

public enum PresetFileError: Error, Equatable, Sendable {
    /// Not JSON, or not a Sequence Studio preset.
    case notAPreset
    case unknownKind(String)
    /// The embedded preset cannot be read (it could never be applied).
    case damagedPayload
}

/// One shareable preset as a `.sqpreset` file: versioned JSON with the payload embedded as a JSON object.
public enum PresetFile {
    public static let fileExtension = "sqpreset"
    public static let formatName = "sequence-studio-preset"
    public static let formatVersion = 1

    public static func encode(_ item: PresetItem) throws -> Data {
        let payload = try JSONSerialization.jsonObject(with: item.payload, options: [.fragmentsAllowed])
        let file: [String: Any] = [
            "format": formatName, "formatVersion": formatVersion,
            "kind": item.kind.rawValue, "name": item.name,
            "payloadVersion": item.payloadVersion, "payload": payload,
        ]
        return try JSONSerialization.data(withJSONObject: file, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
    }

    /// The preset in `data` as a new item (new id, created now). A newer format throws `LibraryStoreError.newerFormat`;
    /// a newer payload version is left to the feature that reads the payload.
    public static func decode(_ data: Data) throws -> PresetItem {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              obj["format"] as? String == formatName,
              let version = obj["formatVersion"] as? Int else { throw PresetFileError.notAPreset }
        guard version <= formatVersion else { throw LibraryStoreError.newerFormat(found: version, supported: formatVersion) }
        guard let kindName = obj["kind"] as? String, let name = obj["name"] as? String,
              let payloadVersion = obj["payloadVersion"] as? Int, let payload = obj["payload"] else { throw PresetFileError.notAPreset }
        guard let kind = PresetKind(rawValue: kindName) else { throw PresetFileError.unknownKind(kindName) }
        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .fragmentsAllowed])
        try validate(kind: kind, payload: payloadData, version: payloadVersion)
        return PresetItem(kind: kind, name: name, payload: payloadData, payloadVersion: payloadVersion)
    }

    /// Kinds this layer knows how to read are checked on import; others stay opaque.
    /// Newer payload → `LibraryStoreError.newerFormat`, unreadable → `PresetFileError.damagedPayload`.
    static func validate(kind: PresetKind, payload: Data, version: Int) throws {
        do {
            switch kind {
            case .effect: _ = try EffectPreset(payload: payload, version: version)
            case .transition: _ = try TransitionPreset(payload: payload, version: version)
            case .keystone: _ = try Keystone(payload: payload, version: version)
            case .titleBlock: _ = try TitleBlock(payload: payload, version: version)
            case .titleTemplate: _ = try TitleTemplatePreset(payload: payload, version: version)
            default: return
            }
        } catch EffectPreset.PayloadError.newerVersion(let found, let supported) {
            throw LibraryStoreError.newerFormat(found: found, supported: supported)
        } catch TransitionPreset.PayloadError.newerVersion(let found, let supported) {
            throw LibraryStoreError.newerFormat(found: found, supported: supported)
        } catch Keystone.PayloadError.newerVersion(let found, let supported) {
            throw LibraryStoreError.newerFormat(found: found, supported: supported)
        } catch TitleBlock.PayloadError.newerVersion(let found, let supported) {
            throw LibraryStoreError.newerFormat(found: found, supported: supported)
        } catch TitleTemplatePreset.PayloadError.newerVersion(let found, let supported) {
            throw LibraryStoreError.newerFormat(found: found, supported: supported)
        } catch {
            throw PresetFileError.damagedPayload
        }
    }

    /// `<name>.sqpreset` with path separators and colons replaced; "Preset" for a blank name.
    public static func suggestedFileName(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = trimmed.isEmpty ? "Preset"
            : trimmed.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return "\(safe).\(fileExtension)"
    }
}

extension PresetStore {
    /// Writes one preset as a `.sqpreset` file. Throws `.notFound` for an unknown id.
    public func exportPreset(_ id: UUID, to url: URL) throws {
        guard let item = preset(id) else { throw LibraryStoreError.notFound }
        try PresetFile.encode(item).write(to: url, options: .atomic)
    }

    /// Reads a `.sqpreset` file and adds it as a new preset.
    @discardableResult
    public func importPreset(from url: URL) throws -> PresetItem {
        let item = try PresetFile.decode(try Data(contentsOf: url))
        try add(item)
        return item
    }
}
