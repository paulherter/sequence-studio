import Foundation

public enum ProjectFileError: Error, Equatable {
    case missing
    case corrupt
    case newerVersion(found: Int, supported: Int)
}

/// Package directory `Name.sqproj/` with `project.json` and `Autosave/`.
public enum ProjectFile {
    /// The project file extension, in one place. Older builds wrote `legacyFileExtensions`; those still open.
    public static let fileExtension = "sqproj"
    public static let legacyFileExtensions = ["ssproj"]

    public static func isProjectURL(_ url: URL) -> Bool {
        let e = url.pathExtension.lowercased()
        return e == fileExtension || legacyFileExtensions.contains(e)
    }
    public static func isLegacyURL(_ url: URL) -> Bool { legacyFileExtensions.contains(url.pathExtension.lowercased()) }

    /// The sibling `<name>.sqproj` a legacy project is saved to; `<name> 2.sqproj` etc. when that already exists.
    public static func convertedURL(for url: URL, fileManager fm: FileManager = .default) -> URL {
        let dir = url.deletingLastPathComponent(), name = url.deletingPathExtension().lastPathComponent
        var candidate = dir.appendingPathComponent(name).appendingPathExtension(fileExtension)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(name) \(n)").appendingPathExtension(fileExtension)
            n += 1
        }
        return candidate
    }

    public static let currentVersion = 18
    public typealias JSONObject = [String: Any]
    /// Upgrades the top-level object from version N to N+1, keyed by N.
    public typealias Migrations = [Int: (JSONObject) throws -> JSONObject]
    public static var migrations: Migrations { [1: migrateV1toV2, 2: migrateV2toV3, 3: migrateV3toV4, 4: migrateV4toV5, 5: migrateV5toV6, 6: migrateV6toV7, 7: migrateV7toV8, 8: migrateV8toV9, 9: migrateV9toV10, 10: migrateV10toV11, 11: migrateV11toV12, 12: migrateV12toV13, 13: migrateV13toV14, 14: migrateV14toV15, 15: migrateV15toV16, 16: migrateV16toV17, 17: migrateV17toV18] }

    /// v2: `Timeline.frameDuration` moved into `Timeline.format` (defaults 1920x1080, 48 kHz).
    /// Track flags, `inOut` and `markers` are optional on decode, so nothing else changes.
    static func migrateV1toV2(_ obj: JSONObject) throws -> JSONObject {
        var o = obj
        guard var p = o["project"] as? JSONObject else { throw ProjectFileError.corrupt }
        let timelines = (p["timelines"] as? [Any] ?? []).map { item -> Any in
            guard var t = item as? JSONObject, let fd = t.removeValue(forKey: "frameDuration") else { return item }
            t["format"] = ["width": 1920, "height": 1080, "frameDuration": fd, "audioSampleRate": 48_000] as JSONObject
            return t
        }
        if p["timelines"] != nil { p["timelines"] = timelines }
        o["project"] = p
        return o
    }

    /// v3: clips gain `animation` (animatable transform, opacity and volume with static fallbacks).
    /// A v2 clip has no animation key; `Clip` decodes that as all-default static properties and no keyframes,
    /// so the object passes through unchanged.
    static func migrateV2toV3(_ obj: JSONObject) throws -> JSONObject { obj }

    /// v4: `Project.rootBin` and `Project.sourceMarks`. Both are optional on decode: a v3 project gets all media
    /// and timelines in the root bin and no marks, so the object passes through unchanged.
    static func migrateV3toV4(_ obj: JSONObject) throws -> JSONObject { obj }

    /// v5: `Clip.sequence` (nested sequences), `Timeline.captionTracks`, `ClipAnimation.cornerRadius`. All optional on
    /// decode with neutral defaults (no nesting, no caption tracks, radius 0): identity migration.
    static func migrateV4toV5(_ obj: JSONObject) throws -> JSONObject { obj }

    /// v6: `Clip.generator` (text layers and other generator clips). Optional on decode, absent = media or nested
    /// clip: identity migration.
    static func migrateV5toV6(_ obj: JSONObject) throws -> JSONObject { obj }

    /// v7: `Clip.color` (per-clip colour: source override, correction, LUTs) and `MediaInfo.detectedColorSpace` /
    /// `embeddedLUTName`. All optional on decode; absent = defaults (automatic from media, neutral): identity migration.
    static func migrateV6toV7(_ obj: JSONObject) throws -> JSONObject { obj }

    /// v8: `label` (LabelColor) on `MediaRef`, `Timeline` and `Clip`. Optional on decode; nil = default for the type:
    /// identity migration.
    static func migrateV7toV8(_ obj: JSONObject) throws -> JSONObject { obj }

    /// v9: `Clip.effects` (explicitly applied effects). `ClipAnimation.cornerRadius` is gone: `Clip` decoding turns a
    /// non-default radius into an applied Rounded Corners effect and drops a default one (= not applied).
    static func migrateV8toV9(_ obj: JSONObject) throws -> JSONObject { obj }

    /// v10: Scale is relative to the picture's own pixels (100 % = one source pixel per sequence pixel) instead of the
    /// aspect-fitted picture; `Clip.isStill`, `MediaInfo.isStill`, `VideoTrackInfo.rotation` are optional on decode.
    /// Every picture clip's Scale is multiplied by its fit scale (`Project.migrateScaleToSourcePixels`) so nothing moves
    /// on screen. A project that does not decode is passed on unchanged (the final decode then reports it).
    static func migrateV9toV10(_ obj: JSONObject) throws -> JSONObject {
        var o = obj
        guard let projectObj = obj["project"], JSONSerialization.isValidJSONObject(projectObj),
              let raw = try? JSONSerialization.data(withJSONObject: projectObj),
              var project = try? decoder().decode(Project.self, from: raw) else { return obj }
        project.migrateScaleToSourcePixels()
        guard let data = try? encoder().encode(project),
              let migrated = try? JSONSerialization.jsonObject(with: data) else { return obj }
        o["project"] = migrated
        return o
    }

    /// v11: `Clip.color` is an ordered list of colour blocks (Lumetri-like). `ClipColor` decoding maps the v10 single
    /// correction / conversion LUT / creative LUT fields into blocks in the old order: identity on the JSON object.
    static func migrateV10toV11(_ obj: JSONObject) throws -> JSONObject { obj }

    /// v12: `Clip.color` holds Colour effects with fixed sections (`ClipColor.effects`) instead of the block list.
    /// `ClipColor` decoding maps v11 `sections` (first block of each kind into the first effect, extras into further
    /// effects): identity on the JSON object.
    static func migrateV11toV12(_ obj: JSONObject) throws -> JSONObject { obj }
    /// v13: markers gain colour, comment and duration (decoded with defaults).
    static func migrateV12toV13(_ obj: JSONObject) throws -> JSONObject { obj }

    /// v14: `ColorEffect.hueCurves` (Hue vs Sat, Hue vs Hue, Hue vs Luma, Luma vs Sat, Sat vs Sat). A missing key decodes as flat
    /// (neutral) curves: identity on the JSON object.
    static func migrateV13toV14(_ obj: JSONObject) throws -> JSONObject { obj }

    /// v15: `Clip.speed` (ratio), `Clip.reversed`, `Clip.keepsPitch`. All optional on decode; absent = 100 %, not reversed,
    /// pitch kept: identity migration.
    static func migrateV14toV15(_ obj: JSONObject) throws -> JSONObject { obj }

    /// v16: `Clip.audioGainDB` (Audio Gain), `TextStyle.tracking/italic/verticalAlignment`, `TextTemplate.box` (area text) and
    /// `TextShadow.restingAngle` (inside text payloads), `CaptionPreset.gap`. All optional on decode; absent = no gain,
    /// no tracking, upright, point text, no gap: identity migration. Older builds drop these fields on save.
    static func migrateV15toV16(_ obj: JSONObject) throws -> JSONObject { obj }

    /// v17: transitions stream (placeholder so the chain is complete until that stream's migration lands): identity.
    static func migrateV16toV17(_ obj: JSONObject) throws -> JSONObject { obj }

    /// v18 (round 2, timeline-edit): `Clip.isEnabled` (Enable / Disable Clip). Optional on decode; absent = enabled:
    /// identity migration. (v17 belongs to transitions; `currentVersion` is raised to the highest number on merge.)
    static func migrateV17toV18(_ obj: JSONObject) throws -> JSONObject { obj }

    static let fileName = "project.json"
    static let autosaveDir = "Autosave"

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private struct Envelope: Encodable { var formatVersion: Int; var project: Project }

    static func encode(_ project: Project) throws -> Data {
        try encoder().encode(Envelope(formatVersion: currentVersion, project: project))
    }

    /// Decodes file contents, running migrations from older versions.
    static func decode(_ data: Data, migrations: Migrations) throws -> Project {
        guard var obj = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject,
              var version = obj["formatVersion"] as? Int, obj["project"] != nil else { throw ProjectFileError.corrupt }
        if version > currentVersion { throw ProjectFileError.newerVersion(found: version, supported: currentVersion) }
        while version < currentVersion {
            guard let step = migrations[version] else { throw ProjectFileError.corrupt }
            obj = try step(obj)
            version += 1
        }
        // `data(withJSONObject:)` raises (not throws) for a non-container value such as `"project": 5`.
        guard let projectObj = obj["project"], JSONSerialization.isValidJSONObject(projectObj),
              let raw = try? JSONSerialization.data(withJSONObject: projectObj),
              let project = try? decoder().decode(Project.self, from: raw) else { throw ProjectFileError.corrupt }
        return project
    }

    public static func write(_ project: Project, to url: URL, fileManager fm: FileManager = .default) throws {
        let data = try encode(project)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        try atomicWrite(data, to: url.appendingPathComponent(fileName), fileManager: fm)
    }

    public static func read(from url: URL, migrations: Migrations = ProjectFile.migrations) throws -> Project {
        try readFile(url.appendingPathComponent(fileName), migrations: migrations)
    }

    static func readFile(_ file: URL, migrations: Migrations) throws -> Project {
        guard FileManager.default.fileExists(atPath: file.path) else { throw ProjectFileError.missing }
        guard let data = try? Data(contentsOf: file) else { throw ProjectFileError.corrupt }
        return try decode(data, migrations: migrations)
    }

    /// Writes to a temp file next to `file`, then replaces it. The old file survives a failed write.
    static func atomicWrite(_ data: Data, to file: URL, fileManager fm: FileManager) throws {
        let tmp = file.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        try data.write(to: tmp)
        do {
            #if canImport(Darwin)
            if fm.fileExists(atPath: file.path) {
                _ = try fm.replaceItemAt(file, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: file)
            }
            #else
            // swift-corelibs replaceItemAt fails when the target exists; rename(2) replaces atomically.
            guard rename(tmp.path, file.path) == 0 else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path, NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)])
            }
            #endif
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    // MARK: Autosave

    static func timestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f.string(from: date)
    }

    /// Writes `Autosave/<yyyyMMdd-HHmmss-SSS>.json` (UTC) and keeps only the newest `keep` snapshots.
    @discardableResult
    public static func autosave(_ project: Project, in url: URL, keep: Int = 10, date: Date = Date(),
                                fileManager fm: FileManager = .default) throws -> URL {
        let dir = url.appendingPathComponent(autosaveDir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(timestamp(date) + ".json")
        try atomicWrite(try encode(project), to: file, fileManager: fm)
        let all = autosaves(in: url, fileManager: fm)
        for old in all.dropLast(max(keep, 1)) { try? fm.removeItem(at: old) }
        return file
    }

    /// Snapshots, oldest first (names sort chronologically).
    public static func autosaves(in url: URL, fileManager fm: FileManager = .default) -> [URL] {
        let dir = url.appendingPathComponent(autosaveDir)
        let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public static func latestAutosave(in url: URL, migrations: Migrations = ProjectFile.migrations,
                                      fileManager fm: FileManager = .default) -> Project? {
        for f in autosaves(in: url, fileManager: fm).reversed() {
            if let p = try? readFile(f, migrations: migrations) { return p }
        }
        return nil
    }
}
