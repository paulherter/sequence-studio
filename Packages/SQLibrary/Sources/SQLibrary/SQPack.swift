import Foundation
import SQCore

// `.sqpack`: one shareable bundle of presets (any kind) plus the LUTs and OFL fonts they use.
//
// Format: one UTF-8 JSON file, data only (nothing in it is ever executed; assets are checked by extension, header and
// SHA-256 and only ever written to the LUT or font folder). Layout:
//
//     { "format": "sequence-studio-pack", "formatVersion": 1,
//       "manifest": { "name", "author", "version", "createdAt", "kinds": ["effect", ...] },
//       "entries":  [ { "kind", "name", "payloadVersion", "payload": {...}, "assets": ["luts/x.cube"] } ],
//       "assets":   [ { "path": "luts/x.cube", "sha256", "data": <base64>, "license": { "id", "notice" } } ] }
//
// `kind` is a plain string, not an enum: a new preset kind (the multi-layer text templates, say) is added by registering
// it in `SQPackKindRegistry`, not by changing the format. A kind this app does not know is skipped on import (listed in
// `SQPackReadResult.skipped`), never fatal, so a pack from a newer build still opens with everything that can be read.

public struct SQPackManifest: Sendable, Equatable {
    public var name: String
    public var author: String
    public var version: String
    public var createdAt: Date
    /// Distinct entry kinds, sorted. Filled in by encode/decode from the entries; informational in the file.
    public var kinds: [String]

    public init(name: String, author: String = "", version: String = "1.0", createdAt: Date = Date(), kinds: [String] = []) {
        self.name = name; self.author = author; self.version = version; self.createdAt = createdAt; self.kinds = kinds
    }
}

public struct SQPackLicense: Sendable, Equatable {
    /// SPDX id. Only the SIL Open Font License is accepted for fonts ("OFL-1.1").
    public var id: String
    /// Copyright line and Reserved Font Name statement, as recorded by the font's authors.
    public var notice: String
    public init(id: String, notice: String) { self.id = id; self.notice = notice }
}

public struct SQPackAsset: Sendable, Equatable {
    public enum Kind: String, Sendable { case lut, font }
    /// `luts/<file>` or `fonts/<file>`: exactly two components.
    public var path: String
    public var data: Data
    public var license: SQPackLicense?

    public init(path: String, data: Data, license: SQPackLicense? = nil) { self.path = path; self.data = data; self.license = license }

    public var kind: Kind? {
        if path.hasPrefix("luts/") { return .lut }
        if path.hasPrefix("fonts/") { return .font }
        return nil
    }
}

public struct SQPackEntry: Sendable, Equatable {
    public var kind: String
    public var name: String
    public var payloadVersion: Int
    /// JSON bytes owned by the feature behind `kind`.
    public var payload: Data
    /// Paths of the pack assets this entry uses.
    public var assets: [String]

    public init(kind: String, name: String, payloadVersion: Int, payload: Data, assets: [String] = []) {
        self.kind = kind; self.name = name; self.payloadVersion = payloadVersion; self.payload = payload; self.assets = assets
    }

    public init(item: PresetItem, assets: [String] = []) {
        self.init(kind: item.kind.rawValue, name: item.name, payloadVersion: item.payloadVersion, payload: item.payload, assets: assets)
    }
}

public struct SQPack: Sendable, Equatable {
    public var manifest: SQPackManifest
    public var entries: [SQPackEntry]
    public var assets: [SQPackAsset]
    public init(manifest: SQPackManifest, entries: [SQPackEntry], assets: [SQPackAsset] = []) {
        self.manifest = manifest; self.entries = entries; self.assets = assets
    }
}

public struct SQPackSkipped: Sendable, Equatable {
    public var name: String
    public var kind: String
    public init(name: String, kind: String) { self.name = name; self.kind = kind }
}

public struct SQPackReadResult: Sendable, Equatable {
    public var pack: SQPack
    /// Entries of kinds this build does not know (made by a newer version).
    public var skipped: [SQPackSkipped]
}

public enum SQPackError: Error, Equatable, Sendable {
    case notAPack
    case newerFormat(found: Int, supported: Int)
    /// What exceeded its cap: "file", "entries", "payload", "asset", "assets".
    case tooLarge(String)
    case invalidManifest(String)
    case malformed(String)
    case invalidAsset(String)
    case checksumMismatch(String)
    case missingLicense(String)
    case damagedEntry(String)
    case emptyPack
}

/// Size limits, checked while reading (a hostile file cannot make the app allocate more than this).
public struct SQPackCaps: Sendable, Equatable {
    public var maxFileBytes = 96 * 1024 * 1024
    public var maxEntries = 2000
    public var maxPayloadBytes = 2 * 1024 * 1024
    public var maxAssets = 200
    public var maxAssetBytes = 16 * 1024 * 1024
    public var maxTotalAssetBytes = 64 * 1024 * 1024
    public static let standard = SQPackCaps()
}

/// Which entry kinds a build understands and how each payload is validated. `standard` knows every `PresetKind`;
/// other layers (workspaces, later the multi-layer text templates) register their kind and validator here.
public struct SQPackKindRegistry: Sendable {
    public typealias Validator = @Sendable (_ payload: Data, _ version: Int) throws -> Void
    private var validators: [String: Validator] = [:]

    public init() {}

    public static let standard: SQPackKindRegistry = {
        var r = SQPackKindRegistry()
        for kind in PresetKind.allCases {
            r.register(kind.rawValue) { payload, version in try PresetFile.validate(kind: kind, payload: payload, version: version) }
        }
        return r
    }()

    public mutating func register(_ kind: String, validate: @escaping Validator) { validators[kind] = validate }
    public func knows(_ kind: String) -> Bool { validators[kind] != nil }

    func validate(_ entry: SQPackEntry) throws {
        guard let v = validators[entry.kind] else { throw SQPackError.damagedEntry(entry.name) }
        do { try v(entry.payload, entry.payloadVersion) } catch LibraryStoreError.newerFormat(let found, let supported) {
            throw SQPackError.newerFormat(found: found, supported: supported)
        } catch let e as SQPackError {
            if case .newerFormat = e { throw e }
            throw SQPackError.damagedEntry(entry.name)
        } catch { throw SQPackError.damagedEntry(entry.name) }
    }
}

public enum SQPackFormat {
    public static let fileExtension = "sqpack"
    public static let formatName = "sequence-studio-pack"
    public static let formatVersion = 1

    // MARK: Encode

    /// Validates everything the importer would and returns the file bytes.
    public static func encode(_ pack: SQPack, caps: SQPackCaps = .standard, registry: SQPackKindRegistry = .standard) throws -> Data {
        var pack = pack
        try validateName(pack.manifest.name)
        guard !pack.entries.isEmpty else { throw SQPackError.emptyPack }
        guard pack.entries.count <= caps.maxEntries else { throw SQPackError.tooLarge("entries") }
        try validateAssets(pack.assets, caps: caps)
        let paths = Set(pack.assets.map(\.path))
        var entryJSON: [[String: Any]] = []
        for e in pack.entries {
            try validateEntryName(e.name)
            guard e.payload.count <= caps.maxPayloadBytes else { throw SQPackError.tooLarge("payload") }
            try registry.validate(e)
            if let missing = e.assets.first(where: { !paths.contains($0) }) { throw SQPackError.invalidAsset(missing) }
            guard let payload = try? JSONSerialization.jsonObject(with: e.payload, options: [.fragmentsAllowed]) else {
                throw SQPackError.damagedEntry(e.name)
            }
            entryJSON.append(["kind": e.kind, "name": e.name, "payloadVersion": e.payloadVersion, "payload": payload, "assets": e.assets])
        }
        pack.manifest.kinds = Array(Set(pack.entries.map(\.kind))).sorted()
        var assetJSON: [[String: Any]] = []
        for a in pack.assets {
            var o: [String: Any] = ["path": a.path, "sha256": sha256Hex(a.data), "data": a.data.base64EncodedString()]
            if let l = a.license { o["license"] = ["id": l.id, "notice": l.notice] }
            assetJSON.append(o)
        }
        let m = pack.manifest
        let root: [String: Any] = [
            "format": formatName, "formatVersion": formatVersion,
            "manifest": ["name": m.name, "author": m.author, "version": m.version,
                         "createdAt": ISO8601DateFormatter().string(from: m.createdAt), "kinds": m.kinds] as [String: Any],
            "entries": entryJSON, "assets": assetJSON,
        ]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .fragmentsAllowed])
        guard data.count <= caps.maxFileBytes else { throw SQPackError.tooLarge("file") }
        return data
    }

    // MARK: Decode

    public static func decode(_ data: Data, caps: SQPackCaps = .standard,
                              registry: SQPackKindRegistry = .standard) throws -> SQPackReadResult {
        guard data.count <= caps.maxFileBytes else { throw SQPackError.tooLarge("file") }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              root["format"] as? String == formatName, let version = root["formatVersion"] as? Int, version >= 1
        else { throw SQPackError.notAPack }
        guard version <= formatVersion else { throw SQPackError.newerFormat(found: version, supported: formatVersion) }

        guard let m = root["manifest"] as? [String: Any], let name = m["name"] as? String else {
            throw SQPackError.invalidManifest("manifest")
        }
        try validateName(name)
        var manifest = SQPackManifest(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        manifest.author = String((m["author"] as? String ?? "").prefix(200))
        manifest.version = String((m["version"] as? String ?? "").prefix(40))
        if let s = m["createdAt"] as? String, let d = ISO8601DateFormatter().date(from: s) { manifest.createdAt = d }

        let assets = try decodeAssets(root["assets"], caps: caps)
        let paths = Set(assets.map(\.path))

        guard let rawEntries = root["entries"] as? [Any] else { throw SQPackError.malformed("entries") }
        guard rawEntries.count <= caps.maxEntries else { throw SQPackError.tooLarge("entries") }
        var entries: [SQPackEntry] = [], skipped: [SQPackSkipped] = []
        for raw in rawEntries {
            guard let o = raw as? [String: Any], let kind = o["kind"] as? String, let ename = o["name"] as? String,
                  let pv = o["payloadVersion"] as? Int, let payload = o["payload"] else { throw SQPackError.malformed("entry") }
            try validateEntryName(ename)
            guard registry.knows(kind) else { skipped.append(SQPackSkipped(name: ename, kind: kind)); continue }
            guard let payloadData = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .fragmentsAllowed]) else {
                throw SQPackError.damagedEntry(ename)
            }
            guard payloadData.count <= caps.maxPayloadBytes else { throw SQPackError.tooLarge("payload") }
            var refs: [String] = []
            if let list = o["assets"] {
                guard let strings = list as? [String] else { throw SQPackError.malformed("assets") }
                refs = strings
            }
            let entry = SQPackEntry(kind: kind, name: ename.trimmingCharacters(in: .whitespacesAndNewlines),
                                    payloadVersion: pv, payload: payloadData, assets: refs)
            try registry.validate(entry)
            if let missing = refs.first(where: { !paths.contains($0) }) { throw SQPackError.invalidAsset(missing) }
            entries.append(entry)
        }
        guard !entries.isEmpty else { throw SQPackError.emptyPack }
        manifest.kinds = Array(Set(entries.map(\.kind))).sorted()
        return SQPackReadResult(pack: SQPack(manifest: manifest, entries: entries, assets: assets), skipped: skipped)
    }

    private static func decodeAssets(_ value: Any?, caps: SQPackCaps) throws -> [SQPackAsset] {
        guard let value else { return [] }
        guard let list = value as? [Any] else { throw SQPackError.malformed("assets") }
        guard list.count <= caps.maxAssets else { throw SQPackError.tooLarge("assets") }
        var out: [SQPackAsset] = [], total = 0
        for raw in list {
            guard let o = raw as? [String: Any], let path = o["path"] as? String, let b64 = o["data"] as? String,
                  let sum = o["sha256"] as? String else { throw SQPackError.malformed("asset") }
            try validatePath(path)
            guard b64.utf8.count <= caps.maxAssetBytes / 3 * 4 + 8 else { throw SQPackError.tooLarge("asset") }
            guard let data = Data(base64Encoded: b64) else { throw SQPackError.invalidAsset(path) }
            guard data.count <= caps.maxAssetBytes else { throw SQPackError.tooLarge("asset") }
            total += data.count
            guard total <= caps.maxTotalAssetBytes else { throw SQPackError.tooLarge("assets") }
            guard sha256Hex(data) == sum.lowercased() else { throw SQPackError.checksumMismatch(path) }
            var license: SQPackLicense?
            if let l = o["license"] as? [String: Any], let id = l["id"] as? String, let notice = l["notice"] as? String {
                license = SQPackLicense(id: id, notice: notice)
            }
            out.append(SQPackAsset(path: path, data: data, license: license))
        }
        try validateAssets(out, caps: caps)
        return out
    }

    // MARK: Validation (shared by encode, decode and the installer)

    static func validateAssets(_ assets: [SQPackAsset], caps: SQPackCaps) throws {
        guard assets.count <= caps.maxAssets else { throw SQPackError.tooLarge("assets") }
        var seen = Set<String>(), total = 0
        for a in assets {
            guard a.data.count <= caps.maxAssetBytes else { throw SQPackError.tooLarge("asset") }
            total += a.data.count
            guard total <= caps.maxTotalAssetBytes else { throw SQPackError.tooLarge("assets") }
            guard seen.insert(a.path.lowercased()).inserted else { throw SQPackError.invalidAsset(a.path) }
            try validateAsset(a)
        }
    }

    /// Path, extension, content header and (fonts) license of one asset.
    static func validateAsset(_ a: SQPackAsset) throws {
        try validatePath(a.path)
        let ext = (a.path as NSString).pathExtension.lowercased()
        switch a.kind {
        case .lut:
            guard ["cube", "3dl"].contains(ext), !a.data.isEmpty, !a.data.contains(0),
                  String(data: a.data, encoding: .utf8) != nil else { throw SQPackError.invalidAsset(a.path) }
        case .font:
            guard ["ttf", "otf"].contains(ext), a.data.count >= 4 else { throw SQPackError.invalidAsset(a.path) }
            let head = Array(a.data.prefix(4))
            let ok = head == [0, 1, 0, 0] || head == Array("OTTO".utf8) || head == Array("true".utf8)
            guard ok else { throw SQPackError.invalidAsset(a.path) }
            guard let l = a.license, ["OFL-1.1", "OFL"].contains(l.id.trimmingCharacters(in: .whitespaces).uppercased()),
                  !l.notice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SQPackError.missingLicense(a.path) }
        case nil: throw SQPackError.invalidAsset(a.path)
        }
    }

    /// `luts/<file>` or `fonts/<file>`: two components, a plain file name (letters, digits, space . _ - ( )), no dot-files, no `..`.
    static func validatePath(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, ["luts", "fonts"].contains(parts[0]) else { throw SQPackError.invalidAsset(path) }
        let file = parts[1]
        let allowed = { (c: Character) in c.isLetter || c.isNumber || " ._-()".contains(c) }
        guard !file.isEmpty, file.count <= 100, file.allSatisfy(allowed), let first = file.first, first != ".", first != " ",
              !file.contains("..") else { throw SQPackError.invalidAsset(path) }
    }

    public static func validateName(_ name: String) throws {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let bad = t.contains { $0 == "/" || $0 == "\\" || $0 == ":" || $0.unicodeScalars.contains { $0.value < 32 } }
        guard !t.isEmpty, t.count <= 120, !bad, !t.hasPrefix(".") else { throw SQPackError.invalidManifest("name") }
    }

    static func validateEntryName(_ name: String) throws {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 200, !t.unicodeScalars.contains(where: { $0.value < 32 }) else { throw SQPackError.malformed("name") }
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256Digest.hex(data)
    }

    // MARK: Files

    public static func write(_ pack: SQPack, to url: URL, registry: SQPackKindRegistry = .standard) throws {
        try encode(pack, registry: registry).write(to: url, options: .atomic)
    }

    public static func read(from url: URL, caps: SQPackCaps = .standard, registry: SQPackKindRegistry = .standard) throws -> SQPackReadResult {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= caps.maxFileBytes else { throw SQPackError.tooLarge("file") }
        return try decode(try Data(contentsOf: url), caps: caps, registry: registry)
    }

    /// `<name>.sqpack` with path separators and colons replaced; "Pack" for a blank name.
    public static func suggestedFileName(for name: String) -> String {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = t.isEmpty ? "Pack" : t.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return "\(safe).\(fileExtension)"
    }
}
