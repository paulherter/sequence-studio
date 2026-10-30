import Foundation

/// What to do with an imported preset whose name already exists in the pack's folder.
public enum SQPackConflict: Sendable, Equatable {
    /// Keep both: the new one gets " 2", " 3" ... after its name.
    case rename
    /// Overwrite the existing preset with the pack's version.
    case replace
    /// Leave the existing preset, drop the pack's.
    case skip
}

public struct SQPackImportResult: Sendable {
    public var added: [PresetItem] = []
    public var replaced = 0
    public var skipped = 0
    /// Entries of kinds that do not live in the preset store (workspaces, ...): the caller installs them.
    public var deferred: [SQPackEntry] = []
}

extension PresetStore {
    /// Bundles the presets `ids` (in that order; unknown ids are ignored). `assets` are the files they use, `assetRefs`
    /// maps a preset id to the asset paths it references.
    public func makePack(ids: [UUID], manifest: SQPackManifest, assets: [SQPackAsset] = [],
                         assetRefs: [UUID: [String]] = [:]) throws -> SQPack {
        let items = ids.compactMap { preset($0) }
        guard !items.isEmpty else { throw SQPackError.emptyPack }
        var m = manifest
        m.kinds = Array(Set(items.map(\.kind.rawValue))).sorted()
        return SQPack(manifest: m, entries: items.map { SQPackEntry(item: $0, assets: assetRefs[$0.id] ?? []) }, assets: assets)
    }

    /// Names of pack entries that already exist in the pack's folder (same kind and name).
    public func conflicts(in pack: SQPack) -> [String] {
        pack.entries.filter { e in
            guard let kind = PresetKind(rawValue: e.kind) else { return false }
            return existing(kind: kind, name: e.name, pack: pack.manifest.name) != nil
        }.map(\.name)
    }

    /// Adds the pack's presets to the store in a folder named after the pack, in one write.
    public func importPack(_ pack: SQPack, conflict: SQPackConflict, registry: SQPackKindRegistry = .standard) throws -> SQPackImportResult {
        let folder = pack.manifest.name.trimmingCharacters(in: .whitespacesAndNewlines)
        try SQPackFormat.validateName(folder)
        var result = SQPackImportResult()
        var replacing: [UUID: PresetItem] = [:]
        var taken = Set<String>()          // "kind|folded name" claimed by this batch
        for e in pack.entries {
            try registry.validate(e)
            guard let kind = PresetKind(rawValue: e.kind) else { result.deferred.append(e); continue }
            func key(_ n: String) -> String { "\(kind.rawValue)|\(LibrarySearch.fold(n))" }
            var name = e.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let old = existing(kind: kind, name: name, pack: folder)
            if let old, !taken.contains(key(name)) {
                switch conflict {
                case .skip: result.skipped += 1; continue
                case .replace:
                    replacing[old.id] = PresetItem(id: old.id, kind: kind, name: name, payload: e.payload,
                                                   payloadVersion: e.payloadVersion, pack: folder)
                    taken.insert(key(name)); result.replaced += 1; continue
                case .rename: break
                }
            }
            if old != nil || taken.contains(key(name)) {
                var n = 2
                while existing(kind: kind, name: "\(name) \(n)", pack: folder) != nil || taken.contains(key("\(name) \(n)")) { n += 1 }
                name = "\(name) \(n)"
            }
            taken.insert(key(name))
            result.added.append(PresetItem(kind: kind, name: name, payload: e.payload, payloadVersion: e.payloadVersion, pack: folder))
        }
        if !result.added.isEmpty || !replacing.isEmpty { try commitBatch(adding: result.added, replacing: replacing) }
        return result
    }

    private func existing(kind: PresetKind, name: String, pack: String) -> PresetItem? {
        let n = LibrarySearch.fold(name.trimmingCharacters(in: .whitespacesAndNewlines))
        return all().first { $0.kind == kind && $0.pack == pack && LibrarySearch.fold($0.name) == n }
    }
}

/// Writes pack assets into the LUT folder and a font folder. Re-validates every asset first: the paths are never trusted.
public enum SQPackInstaller {
    public struct Installed: Sendable, Equatable {
        public var luts: [URL] = []
        /// Font files to register with the system for this session (CTFontManager, in the host).
        public var fonts: [URL] = []
    }

    public static func install(_ assets: [SQPackAsset], lutDirectory: URL, fontDirectory: URL) throws -> Installed {
        for a in assets { try SQPackFormat.validateAsset(a) }
        let fm = FileManager.default
        var out = Installed()
        for a in assets {
            guard let kind = a.kind else { continue }
            let dir = kind == .lut ? lutDirectory : fontDirectory
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = (a.path as NSString).lastPathComponent
            let stem = (file as NSString).deletingPathExtension, ext = (file as NSString).pathExtension
            var name = file, n = 2
            var dest = dir.appendingPathComponent(name)
            while fm.fileExists(atPath: dest.path) {
                if let have = try? Data(contentsOf: dest), have == a.data { break }       // already installed: reuse
                name = "\(stem) \(n).\(ext)"; n += 1
                dest = dir.appendingPathComponent(name)
            }
            if !fm.fileExists(atPath: dest.path) { try a.data.write(to: dest, options: .atomic) }
            if kind == .lut { out.luts.append(dest) } else { out.fonts.append(dest) }
        }
        return out
    }
}

/// Finds the LUT files a preset payload refers to, so "Export as Pack" can bundle them.
public enum SQPackAssetScanner {
    /// File names (last path component) of every JSON string in `payload` that ends in `.cube` or `.3dl` and is a valid pack asset name.
    public static func lutFileNames(in payload: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: payload, options: [.fragmentsAllowed]) else { return [] }
        var found: [String] = []
        func walk(_ v: Any) {
            if let s = v as? String {
                let ext = (s as NSString).pathExtension.lowercased()
                guard ext == "cube" || ext == "3dl" else { return }
                let name = (s as NSString).lastPathComponent
                if (try? SQPackFormat.validatePath("luts/" + name)) != nil, !found.contains(name) { found.append(name) }
            } else if let a = v as? [Any] { a.forEach(walk) } else if let d = v as? [String: Any] { d.values.forEach(walk) }
        }
        walk(root)
        return found.sorted()
    }
}
