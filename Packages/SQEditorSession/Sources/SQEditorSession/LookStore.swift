import Foundation
import SQCore
import SQLibrary
import SQText
import SQTranscribe

/// The one store of the user's Looks (`<Application Support>/Sequence Studio/Library/looks.json`). The Text panel's
/// styles (`TextStyleLibrary`) and the caption looks (`CaptionLookLibrary`) are thin views of it; the Looks a project
/// carries live in its style kit (`StyleKit.projectLooks`).
///
/// The two older stores are taken in once and left on disk untouched: `text-styles.json` (the Text panel's styles) when
/// the store is opened, the preset store's `.caption` presets on the first `importCaptionPresets`. Looks with equal
/// values merge, a taken name gets a number (`LookLibrary.merge`). After that first import the `.caption` presets are
/// followed: one added, changed, renamed or deleted in the preset store (Library panel, pack import) changes its Look.
/// A Look is only deleted that way when its preset was removed from a preset store that was read as it is
/// (`PresetStore.Origin.file`) and the Look was not edited here since. Deleting such a Look here deletes its preset.
///
/// Every Look is registered in the caption look registry under its id (and under the ids merged into it), so captions
/// that carry `look-<id>` render.
///
/// A file this build cannot read is never written over: one from a newer build stays as it is (the store is then read
/// only), a damaged one is moved aside (`looks.json.corrupt-<time>`). A single Look that does not decode is kept in the
/// file as it is and not listed.
public final class LookStore: @unchecked Sendable {
    public static let shared = LookStore(url: defaultURL, legacyTextStyles: legacyTextStylesURL, registry: .shared,
                                         presets: LibraryStores.presetStore)

    public enum StoreError: Error, Equatable, Sendable {
        /// The Look file was written by a newer build (or is damaged and could not be moved aside): nothing is written,
        /// the change only lives until the app quits.
        case readOnly
    }

    /// Posted (object: the store) after the library changed, on the thread that changed it.
    public static let didChange = Notification.Name("sq.lookStore.didChange")

    /// Posted (object: the store) when a change could not be written because the Look file is read only. The change
    /// itself is kept in memory until the app quits; the UI shows `readOnlyMessage`.
    public static let writeFailed = Notification.Name("sq.lookStore.writeFailed")

    /// The Look file, nil for a store in memory.
    public var fileURL: URL? { url }

    /// What the user reads when `writeFailed` is posted.
    public var readOnlyMessage: String {
        let where_ = url.map { " (\($0.path))" } ?? ""
        return "Your Looks cannot be saved: the Look file\(where_) cannot be written. The change stays until you quit Sequence Studio."
    }

    public static var defaultURL: URL { libraryDirectory.appendingPathComponent("looks.json") }
    public static var legacyTextStylesURL: URL { libraryDirectory.appendingPathComponent("text-styles.json") }
    private static var libraryDirectory: URL {
        LibraryStores.supportDirectory.appendingPathComponent("Library", isDirectory: true)
    }

    private static let textStylesSource = "text-styles"
    private static let captionPresetsSource = "caption-presets"

    /// The library plus which old stores were already taken in (an imported Look the user deleted must not come back)
    /// and what the `.caption` presets looked like when they were last followed.
    private struct File: Encodable {
        var library: LookLibrary
        var imported: Set<String>
        var captionPresets: [String: String]?
        var captionPresetLooks: [String: String]

        private enum CodingKeys: String, CodingKey { case imported, captionPresets, captionPresetLooks }

        func encode(to encoder: Encoder) throws {
            try library.encode(to: encoder)
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(imported.sorted(), forKey: .imported)
            try c.encodeIfPresent(captionPresets, forKey: .captionPresets)
            if !captionPresetLooks.isEmpty { try c.encode(captionPresetLooks, forKey: .captionPresetLooks) }
        }
    }

    /// The Text panel's old file: `{formatVersion: 1, styles: [{id, name, style, isBuiltIn}]}`.
    private struct LegacyTextStyles: Codable {
        struct Entry: Codable { var id: String; var name: String; var style: TextStyle }
        var formatVersion: Int
        var styles: [Entry]
    }

    private let lock = NSLock()
    private let url: URL?
    private let registry: CaptionLookRegistry?
    private var lib = LookLibrary()
    private var imported: Set<String> = []
    /// Preset id -> digest of its name and payload at the last `importCaptionPresets`; nil = never recorded.
    private var presetsSeen: [String: String]?
    /// Preset id -> digest of its Look as the follow (or a save from the caption panels) left it. A Look that differs
    /// from it, or has none, was edited here since: the follow never deletes it.
    private var presetLooks: [String: String] = [:]
    /// Entries of `looks` this build could not decode (their place in the file and JSON): written back unchanged.
    private var unreadable: [(index: Int, json: Data)] = []
    /// Aliases that point at an unreadable entry: written back too.
    private var unreadableAliases: [String: String] = [:]
    /// Set under the lock by a change that touched only the bookkeeping: the file is written anyway.
    private var dirty = false
    /// The preset store whose `.caption` presets mirror the Looks: a Look deleted here takes its preset along.
    private let presets: PresetStore?
    private var mirroring: Task<Void, Never>?
    /// False for a file a newer build wrote, or a damaged one that could not be moved aside: never written over.
    private var writable = true
    /// A write failure was reported and no write has succeeded since: `writeFailed` is posted once per such run.
    private var failureReported = false
    /// False when the Look file could not be read as it is (newer build, or damaged and not movable): the library is
    /// then empty and says nothing about which Looks exist.
    public var isLoaded: Bool { lock.withLock { writable } }
    private var registered: [String: CaptionLook] = [:]

    /// `url` nil = memory only (tests). `legacyTextStyles`: the old Text panel file to take in once.
    /// `registry` nil = the Looks are not registered for caption rendering. `presets` nil = no preset is deleted with
    /// its Look.
    public init(url: URL?, legacyTextStyles: URL? = nil, registry: CaptionLookRegistry? = nil, presets: PresetStore? = nil) {
        self.url = url
        self.registry = registry
        self.presets = presets
        if let url, let data = try? Data(contentsOf: url), !read(data) {
            // Damaged: keep it under another name and start empty. Not movable: leave it alone and write nothing.
            if (try? Self.moveAside(url)) == nil { writable = false }
        }
        if let legacyTextStyles, writable, !imported.contains(Self.textStylesSource),
           let data = try? Data(contentsOf: legacyTextStyles), let old = Self.textStyles(in: data) {
            lib.merge(old)
            imported.insert(Self.textStylesSource)
            try? persist()
        }
        syncRegistry()
    }

    /// Reads a Look file (or one in the old Text panel format). False = the file is damaged.
    private func read(_ data: Data) -> Bool {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        if let old = Self.textStyles(in: data) {
            // The file itself is in the old Text panel format (it has `styles`, a Look file has `looks`).
            lib.merge(old)
            imported.insert(Self.textStylesSource)
            return true
        }
        if let v = obj["formatVersion"] as? Int, v > LookLibrary.formatVersion {
            writable = false
            return true
        }
        guard let raw = obj["looks"] as? [Any] else { return false }
        var looks: [Look] = []
        var lost: Set<String> = []
        for (i, item) in raw.enumerated() {
            guard let json = try? JSONSerialization.data(withJSONObject: item, options: [.fragmentsAllowed]) else { continue }
            if let look = try? JSONDecoder().decode(Look.self, from: json) {
                looks.append(look)
            } else {
                unreadable.append((i, json))
                if let id = (item as? [String: Any])?["id"] as? String { lost.insert(id) }
            }
        }
        let aliases = obj["aliases"] as? [String: String] ?? [:]
        lib = LookLibrary(user: looks, aliases: aliases)
        unreadableAliases = aliases.filter { lost.contains($0.value) }
        imported = Set(obj["imported"] as? [String] ?? [])
        presetsSeen = obj["captionPresets"] as? [String: String]
        presetLooks = obj["captionPresetLooks"] as? [String: String] ?? [:]
        return true
    }

    /// `looks.json` -> `looks.json.corrupt-<unix time>` (a counter is added when that name is taken).
    private static func moveAside(_ url: URL) throws {
        let dir = url.deletingLastPathComponent()
        let base = "\(url.lastPathComponent).corrupt-\(Int(Date().timeIntervalSince1970))"
        var target = dir.appendingPathComponent(base), n = 1
        while FileManager.default.fileExists(atPath: target.path) {
            n += 1
            target = dir.appendingPathComponent("\(base)-\(n)")
        }
        try FileManager.default.moveItem(at: url, to: target)
    }

    /// The old Text panel styles as Looks (style only). Each gets a UUID made from its old id: the same one on every
    /// read, so a copy loaded before the file was rewritten still names the same Looks.
    private static func textStyles(in data: Data) -> [Look]? {
        guard let file = try? JSONDecoder().decode(LegacyTextStyles.self, from: data), file.formatVersion == 1 else { return nil }
        return file.styles.map { Look(id: stableID(for: $0.id), name: $0.name, style: $0.style) }
    }

    static func stableID(for oldID: String) -> String {
        let h = SHA256Digest.hash(Data("sq.text-style:\(oldID)".utf8))
        return UUID(uuid: (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8], h[9], h[10], h[11], h[12], h[13], h[14], h[15])).uuidString
    }

    // MARK: Read

    public var library: LookLibrary { lock.lock(); defer { lock.unlock() }; return lib }

    // MARK: Write

    /// Changes the library, writes it and updates the caption registry. The change stays in memory when the write fails.
    @discardableResult
    public func edit<T>(_ body: (inout LookLibrary) -> T) throws -> T {
        try change { body(&$0) }
    }

    /// Takes back a copy a caller edited on its own. `base` is the library as that copy was read. Only what the copy
    /// changed against its base is applied: a Look saved, updated or deleted elsewhere in the meantime stays as it is,
    /// however old the copy is and however often it is handed back.
    public func replace(with edited: LookLibrary, base: LookLibrary) throws {
        try change { $0 = Self.threeWay(base: base, mine: edited, theirs: $0) }
    }

    static func threeWay(base: LookLibrary, mine: LookLibrary, theirs: LookLibrary) -> LookLibrary {
        let before = Dictionary(base.user.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let current = Dictionary(theirs.user.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [Look] = []
        var seen: Set<String> = []
        for l in mine.user {
            seen.insert(l.id)
            if let b = before[l.id], b == l {
                // Untouched in the copy: the store's Look wins (also when it was deleted there).
                if let now = current[l.id] { out.append(now) }
            } else {
                out.append(l)
            }
        }
        // Not in the copy: deleted by it when it had the Look, else new in the store.
        for l in theirs.user where !seen.contains(l.id) && before[l.id] == nil { out.append(l) }
        // Aliases the same way: what the copy added, changed or removed against its base is applied to the store's.
        var aliases = theirs.aliases
        for (old, kept) in mine.aliases where base.aliases[old] != kept { aliases[old] = kept }
        for old in base.aliases.keys where mine.aliases[old] == nil { aliases[old] = nil }
        return LookLibrary(user: out, aliases: aliases)
    }

    /// Takes the preset store's `.caption` presets in (first call), then follows them: a preset added or changed since
    /// the last call adds or changes the Look under its id, a preset that is gone deletes it. A Look changed here is not
    /// touched while its preset stays the same.
    ///
    /// A Look is deleted only for a preset that is gone from a store that was read as it is, and only when the Look is
    /// still as the preset left it. A stand-in store (the real `presets.json` is from a newer build) changes nothing; a
    /// store that started empty after a damaged file deletes nothing and its lost presets are followed no more. A
    /// preset this build cannot read keeps its Look.
    public func importCaptionPresets(from store: PresetStore?) async {
        guard let store, store.origin != .standIn else { return }
        await mirrored()
        let items = await store.presets(kind: .caption)
        var presets: [(look: Look, digest: String)] = []
        var undecodable: Set<String> = []
        for item in items {
            guard item.payloadVersion <= CaptionLookPayload.version,
                  let p = try? JSONDecoder().decode(CaptionLookPayload.self, from: item.payload) else {
                undecodable.insert(item.id.uuidString)
                continue
            }
            var look = Look(id: item.id.uuidString, name: item.name, style: p.look.style, animation: p.look.animation,
                            captionSegmentation: p.segmentation.flatMap(Self.encode))
            look.category = category(of: item.id.uuidString) ?? p.category
            presets.append((look, Self.digest(name: item.name, payload: item.payload)))
        }
        follow(presets, undecodable: undecodable, removalsAreReal: store.origin == .file)
    }

    /// The category a Look of this id has now (a rebuilt Look keeps it).
    private func category(of id: String) -> String? { lock.withLock { lib.user.first { $0.id == id }?.category } }

    private func follow(_ presets: [(look: Look, digest: String)], undecodable: Set<String>, removalsAreReal: Bool) {
        try? change(mirror: false) { lib in
            var now = Dictionary(presets.map { ($0.look.id, $0.digest) }, uniquingKeysWith: { a, _ in a })
            /// The Look under the preset's own id is now as the preset made it.
            func note(_ id: String) { presetLooks[id] = lib.user.first { $0.id == id }.map(Self.digest(of:)) }
            if !imported.contains(Self.captionPresetsSource) {
                lib.merge(presets.map(\.look))
                imported.insert(Self.captionPresetsSource)
                for p in presets { note(p.look.id) }
                dirty = true
            } else if let seen = presetsSeen {
                for p in presets where seen[p.look.id] != p.digest {
                    if let have = lib.look(p.look.id), !have.isBuiltIn {
                        let untouched = presetLooks[have.id] == Self.digest(of: have)
                        // The digest is "<name>.<payload>": only the part that changed is taken over. A preset that
                        // was merged into another Look (an alias) never renames that Look.
                        let was = seen[p.look.id]?.split(separator: ".").map(String.init) ?? []
                        let now = p.digest.split(separator: ".").map(String.init)
                        if was.count != 2 || was[1] != now[1] {
                            _ = lib.update(have.id) { l in
                                (l.style, l.animation) = (p.look.style, p.look.animation)
                                if let s = p.look.captionSegmentation { l.captionSegmentation = s }
                            }
                        }
                        if was.count == 2, was[0] != now[0], have.id == p.look.id { _ = lib.rename(have.id, to: p.look.name) }
                        // A Look edited here stays "edited" although part of it was just taken from the preset.
                        if untouched, have.id == p.look.id { note(have.id) }
                    } else if seen[p.look.id] == nil {
                        lib.merge([p.look])
                        note(p.look.id)
                    }
                    // Else the Look was deleted here: a later change of its preset does not bring it back.
                }
                for (id, digest) in seen where now[id] == nil {
                    if undecodable.contains(id) {
                        now[id] = digest
                    } else if removalsAreReal {
                        if let look = lib.user.first(where: { $0.id == id }) {
                            if presetLooks[id] == Self.digest(of: look) { _ = lib.delete(id) }
                        } else {
                            _ = lib.delete(id)   // Merged into another Look: only the old id stops resolving.
                        }
                    }
                }
            }
            if presetsSeen != now { (presetsSeen, dirty) = (now, true) }
            let followed = presetLooks.filter { now[$0.key] != nil }
            if followed != presetLooks { (presetLooks, dirty) = (followed, true) }
        }
    }

    /// A `.caption` preset that was just written from this store's Look (the caption panels save both): the follow
    /// must not take it for a new or changed preset and overwrite or bring back the Look.
    public func recordPreset(_ item: PresetItem) {
        try? change(mirror: false) { lib in
            guard presetsSeen != nil else { return }
            let id = item.id.uuidString
            presetsSeen?[id] = Self.digest(name: item.name, payload: item.payload)
            if let look = lib.user.first(where: { $0.id == id }) { presetLooks[id] = Self.digest(of: look) }
            dirty = true
        }
    }

    /// A `.caption` preset that was just deleted together with its Look.
    public func forgetPreset(_ id: UUID) {
        try? change(mirror: false) { _ in
            guard presetsSeen?[id.uuidString] != nil || presetLooks[id.uuidString] != nil else { return }
            presetsSeen?[id.uuidString] = nil
            presetLooks[id.uuidString] = nil
            dirty = true
        }
    }

    /// Returns when the presets of the Looks deleted so far are deleted too.
    public func mirrored() async {
        let task = lock.withLock { mirroring }
        await task?.value
    }

    private static func hex(_ data: Data) -> String {
        SHA256Digest.hash(data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func digest(name: String, payload: Data) -> String { hex(Data(name.utf8)) + "." + hex(payload) }

    private static func digest(of look: Look) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return (try? enc.encode(look)).map(hex) ?? ""
    }

    /// Stable bytes (sorted keys), so equal segmentations compare equal.
    public static func encode(_ segmentation: CaptionPreset) -> Data? {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return try? enc.encode(segmentation)
    }

    public static func segmentation(of look: Look) -> CaptionPreset? {
        look.captionSegmentation.flatMap { try? JSONDecoder().decode(CaptionPreset.self, from: $0) }
    }

    // MARK: Private

    /// Runs `body` on the library under the lock; when the library changed (or `body` set `dirty`), updates the
    /// registry, writes the file and, after the lock is released, tells the observers. `mirror`: a followed Look that
    /// `body` deleted takes its `.caption` preset along.
    private func change<T>(mirror: Bool = true, _ body: (inout LookLibrary) -> T) throws -> T {
        var changed = false, readOnly = false
        defer {
            if changed { NotificationCenter.default.post(name: Self.didChange, object: self) }
            if readOnly { NotificationCenter.default.post(name: Self.writeFailed, object: self) }
        }
        lock.lock(); defer { lock.unlock() }
        let before = lib
        let result = body(&lib)
        changed = lib != before
        if mirror, changed, let presets, let seen = presetsSeen {
            let gone = before.user.map(\.id).filter { seen[$0] != nil && lib.look($0) == nil }.compactMap(UUID.init(uuidString:))
            if !gone.isEmpty {
                // The digests stay until the next follow sees the presets gone: until then they keep it from adding
                // the Looks again.
                let earlier = mirroring
                mirroring = Task {
                    await earlier?.value
                    for id in gone { try? await presets.delete(id) }
                }
            }
        }
        guard changed || dirty else { return result }
        dirty = false
        syncRegistry()
        do { try persist(); failureReported = false } catch StoreError.readOnly {
            readOnly = !failureReported
            failureReported = true
            throw StoreError.readOnly
        }
        return result
    }

    private func persist() throws {
        guard let url else { return }
        guard writable else { throw StoreError.readOnly }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try enc.encode(File(library: lib, imported: imported, captionPresets: presetsSeen, captionPresetLooks: presetLooks))
        if !unreadable.isEmpty, var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Each one back where it stood (as far as the list still reaches), with the aliases that point at it.
            var looks = obj["looks"] as? [Any] ?? []
            for u in unreadable {
                guard let entry = try? JSONSerialization.jsonObject(with: u.json, options: [.fragmentsAllowed]) else { continue }
                looks.insert(entry, at: min(u.index, looks.count))
            }
            obj["looks"] = looks
            if !unreadableAliases.isEmpty {
                var aliases = obj["aliases"] as? [String: String] ?? [:]
                for (old, kept) in unreadableAliases where aliases[old] == nil && lib.look(old) == nil { aliases[old] = kept }
                obj["aliases"] = aliases
            }
            data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        }
        try data.write(to: url, options: .atomic)
    }

    private func syncRegistry() {
        guard let registry else { return }
        var want: [String: CaptionLook] = [:]
        for l in lib.user { want[l.id] = l.captionLook }
        for (old, kept) in lib.aliases { if let l = want[kept] { want[old] = l } }
        for id in registered.keys where want[id] == nil { registry.unregister(id: id) }
        for (id, look) in want where registered[id] != look { registry.register(look, id: id) }
        registered = want
    }
}
