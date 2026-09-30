import Foundation

public enum ProjectFileError: Error, Equatable {
    case missing
    case corrupt
    case newerVersion(found: Int, supported: Int)
}

/// Package directory `Name.ssproj/` with `project.json` and `Autosave/`.
public enum ProjectFile {
    public static let currentVersion = 4
    public typealias JSONObject = [String: Any]
    /// Upgrades the top-level object from version N to N+1, keyed by N.
    public typealias Migrations = [Int: (JSONObject) throws -> JSONObject]
    public static var migrations: Migrations { [1: migrateV1toV2, 2: migrateV2toV3, 3: migrateV3toV4] }

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
        guard let projectObj = obj["project"],
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
            if fm.fileExists(atPath: file.path) {
                _ = try fm.replaceItemAt(file, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: file)
            }
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
