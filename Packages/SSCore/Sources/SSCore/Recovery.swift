import Foundation

/// When and how many autosave copies are made (Premiere defaults: every 5 min, 10 versions).
public struct AutosavePolicy: Sendable, Equatable {
    public var interval: TimeInterval
    public var keep: Int
    /// Versions older than this are pruned, except the newest one.
    public var maxAge: TimeInterval

    public init(interval: TimeInterval = 300, keep: Int = 10, maxAge: TimeInterval = 7 * 24 * 3600) {
        self.interval = interval; self.keep = max(keep, 1); self.maxAge = maxAge
    }

    public func shouldAutosave(isDirty: Bool, lastAutosave: Date?, now: Date) -> Bool {
        guard isDirty else { return false }
        guard let last = lastAutosave else { return true }
        return now.timeIntervalSince(last) >= interval
    }
}

public struct AutosaveVersion: Sendable, Hashable {
    public var url: URL
    public var date: Date
}

/// One folder per project id under `base`; each version is a `<timestamp>.ssproj` package.
public struct AutosaveStore: Sendable {
    public typealias Writer = @Sendable (Project, URL) throws -> Void

    public let base: URL
    public var policy: AutosavePolicy
    let writer: Writer

    public static var defaultBase: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Sequence Studio/Autosave", isDirectory: true)
    }

    public init(base: URL = AutosaveStore.defaultBase, policy: AutosavePolicy = AutosavePolicy(),
                writer: @escaping Writer = { try ProjectFile.write($0, to: $1) }) {
        self.base = base; self.policy = policy; self.writer = writer
    }

    public func folder(for projectID: UUID) -> URL {
        base.appendingPathComponent(projectID.uuidString, isDirectory: true)
    }

    static let ext = "ssproj"

    static func formatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f
    }

    /// Writes the snapshot into a hidden temp package, then renames it into place: a failure never leaves a partial version.
    @discardableResult
    public func write(_ project: Project, date: Date = Date()) throws -> AutosaveVersion {
        let fm = FileManager.default
        let dir = folder(for: project.id)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = Self.formatter().string(from: date)
        let final = dir.appendingPathComponent("\(name).\(Self.ext)", isDirectory: true)
        let tmp = dir.appendingPathComponent(".\(UUID().uuidString).tmp", isDirectory: true)
        do {
            try writer(project, tmp)
            if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
            try fm.moveItem(at: tmp, to: final)
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
        try? prune(project.id, now: date)
        return AutosaveVersion(url: final, date: date)
    }

    /// Versions of a project, newest first.
    public func versions(for projectID: UUID) -> [AutosaveVersion] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder(for: projectID),
                                                                  includingPropertiesForKeys: nil)) ?? []
        let f = Self.formatter()
        return items.compactMap { u -> AutosaveVersion? in
            guard u.pathExtension == Self.ext, !u.lastPathComponent.hasPrefix("."),
                  let d = f.date(from: u.deletingPathExtension().lastPathComponent) else { return nil }
            return AutosaveVersion(url: u, date: d)
        }.sorted { $0.date > $1.date }
    }

    /// Drops versions beyond `keep` and older than `maxAge`; the newest version always stays.
    public func prune(_ projectID: UUID, now: Date = Date()) throws {
        let all = versions(for: projectID)
        for (i, v) in all.enumerated() where i > 0 {
            if i >= policy.keep || now.timeIntervalSince(v.date) > policy.maxAge {
                try FileManager.default.removeItem(at: v.url)
            }
        }
    }

    public func read(_ version: AutosaveVersion) throws -> Project {
        try ProjectFile.read(from: version.url)
    }
}

/// A "running" lock file per project: written at open, removed on clean close.
public struct SessionMarker: Sendable {
    public struct Info: Codable, Sendable, Equatable {
        public var pid: Int32
        public var started: Date
        public var projectName: String
        public var projectPath: String?
    }

    public let store: AutosaveStore
    public init(store: AutosaveStore) { self.store = store }

    static let fileName = "running.lock"
    func file(_ id: UUID) -> URL { store.folder(for: id).appendingPathComponent(Self.fileName) }

    public func begin(projectID: UUID, projectURL: URL?, projectName: String,
                      pid: Int32 = ProcessInfo.processInfo.processIdentifier, date: Date = Date()) throws {
        try FileManager.default.createDirectory(at: store.folder(for: projectID), withIntermediateDirectories: true)
        let info = Info(pid: pid, started: date, projectName: projectName, projectPath: projectURL?.path)
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        try e.encode(info).write(to: file(projectID), options: .atomic)
    }

    public func end(projectID: UUID) { try? FileManager.default.removeItem(at: file(projectID)) }

    public func info(projectID: UUID) -> Info? {
        guard let data = try? Data(contentsOf: file(projectID)) else { return nil }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try? d.decode(Info.self, from: data)
    }
}

public struct RecoveryCandidate: Sendable, Hashable {
    public var projectID: UUID
    public var projectName: String
    /// Saved project package, nil for a project that was never saved.
    public var projectURL: URL?
    public var autosave: AutosaveVersion
}

public struct RecoveryScanner: Sendable {
    public let store: AutosaveStore
    let isProcessAlive: @Sendable (Int32) -> Bool

    public static let systemProcessCheck: @Sendable (Int32) -> Bool = { pid in
        kill(pid, 0) == 0 || errno == EPERM
    }

    public init(store: AutosaveStore,
                isProcessAlive: @escaping @Sendable (Int32) -> Bool = RecoveryScanner.systemProcessCheck) {
        self.store = store; self.isProcessAlive = isProcessAlive
    }

    /// Projects whose marker survived a dead session and whose newest autosave is newer than the saved file. Newest first.
    public func scan() -> [RecoveryCandidate] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: store.base, includingPropertiesForKeys: nil)) ?? []
        let marker = SessionMarker(store: store)
        var out: [RecoveryCandidate] = []
        for dir in dirs {
            guard let id = UUID(uuidString: dir.lastPathComponent),
                  let info = marker.info(projectID: id), !isProcessAlive(info.pid),
                  let newest = store.versions(for: id).first else { continue }
            let url = info.projectPath.map { URL(fileURLWithPath: $0) }
            if let url,
               let saved = (try? fm.attributesOfItem(atPath: url.appendingPathComponent("project.json").path))?[.modificationDate] as? Date,
               newest.date <= saved { continue }
            out.append(RecoveryCandidate(projectID: id, projectName: info.projectName, projectURL: url, autosave: newest))
        }
        return out.sorted { $0.autosave.date > $1.autosave.date }
    }

    /// Opens the autosave as an untitled copy with a new id; the original is never touched.
    public func recover(_ candidate: RecoveryCandidate) throws -> Project {
        var p = try store.read(candidate.autosave)
        p.id = UUID()
        p.name = candidate.projectName + " (Recovered)"
        return p
    }

    /// Discards the stale marker (user declined recovery or finished it).
    public func dismiss(_ candidate: RecoveryCandidate) {
        SessionMarker(store: store).end(projectID: candidate.projectID)
    }
}
