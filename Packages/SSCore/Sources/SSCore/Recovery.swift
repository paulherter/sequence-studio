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
        try? prune(project.id, now: date, keeping: final)
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

    /// Drops versions beyond `keep` and older than `maxAge`; the newest version and `keeping` always stay
    /// (and count towards `keep`). Also removes orphaned `.<uuid>.tmp` dirs older than one hour.
    public func prune(_ projectID: UUID, now: Date = Date(), keeping: URL? = nil) throws {
        let fm = FileManager.default
        var kept = 0
        for (i, v) in versions(for: projectID).enumerated() {
            if i == 0 || v.url.lastPathComponent == keeping?.lastPathComponent || (kept < policy.keep && now.timeIntervalSince(v.date) <= policy.maxAge) {
                kept += 1
            } else {
                try fm.removeItem(at: v.url)
            }
        }
        let items = (try? fm.contentsOfDirectory(at: folder(for: projectID), includingPropertiesForKeys: nil)) ?? []
        for u in items where u.lastPathComponent.hasPrefix(".") && u.pathExtension == "tmp" {
            let m = (try? fm.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date
            if let m, now.timeIntervalSince(m) > 3600 { try? fm.removeItem(at: u) }
        }
    }

    public func read(_ version: AutosaveVersion) throws -> Project {
        try ProjectFile.read(from: version.url)
    }
}

/// One "running" lock file per process and project (`running-<pid>.lock`): written at open, removed on clean close.
public struct SessionMarker: Sendable {
    public struct Info: Codable, Sendable, Equatable {
        public var pid: Int32
        public var started: Date
        public var projectName: String
        public var projectPath: String?
        /// Start time of the process, to tell a reused pid from the original one. Nil in old markers.
        public var processStart: Date?
    }

    public let store: AutosaveStore
    public init(store: AutosaveStore) { self.store = store }

    static func fileName(_ pid: Int32) -> String { "running-\(pid).lock" }
    func file(_ id: UUID, pid: Int32) -> URL { store.folder(for: id).appendingPathComponent(Self.fileName(pid)) }

    /// Kernel start time of a process (proc_pidinfo); nil when the process does not exist.
    public static func startTime(of pid: Int32) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    }

    public func begin(projectID: UUID, projectURL: URL?, projectName: String,
                      pid: Int32 = ProcessInfo.processInfo.processIdentifier, date: Date = Date(),
                      processStart: Date? = nil) throws {
        try FileManager.default.createDirectory(at: store.folder(for: projectID), withIntermediateDirectories: true)
        let info = Info(pid: pid, started: date, projectName: projectName, projectPath: projectURL?.path,
                        processStart: processStart ?? Self.startTime(of: pid))
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        try e.encode(info).write(to: file(projectID, pid: pid), options: .atomic)
    }

    /// Removes only this process's marker.
    public func end(projectID: UUID, pid: Int32 = ProcessInfo.processInfo.processIdentifier) {
        try? FileManager.default.removeItem(at: file(projectID, pid: pid))
    }

    /// All markers of a project, one per process.
    public func infos(projectID: UUID) -> [Info] {
        let items = (try? FileManager.default.contentsOfDirectory(at: store.folder(for: projectID), includingPropertiesForKeys: nil)) ?? []
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return items.filter { $0.lastPathComponent.hasPrefix("running-") && $0.pathExtension == "lock" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? d.decode(Info.self, from: $0) } }
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
    let processStart: @Sendable (Int32) -> Date?

    public static let systemProcessCheck: @Sendable (Int32) -> Bool = { pid in
        kill(pid, 0) == 0 || errno == EPERM
    }

    public init(store: AutosaveStore,
                isProcessAlive: @escaping @Sendable (Int32) -> Bool = RecoveryScanner.systemProcessCheck,
                processStart: @escaping @Sendable (Int32) -> Date? = { SessionMarker.startTime(of: $0) }) {
        self.store = store; self.isProcessAlive = isProcessAlive; self.processStart = processStart
    }

    /// Alive = the pid exists and, when recorded, the process start time still matches (pid reuse is not alive).
    func isAlive(_ info: SessionMarker.Info) -> Bool {
        guard isProcessAlive(info.pid) else { return false }
        guard let recorded = info.processStart, let current = processStart(info.pid) else { return true }
        return abs(current.timeIntervalSince(recorded)) < 2
    }

    /// Projects with a dead session's marker and no live session, whose newest autosave is newer than the saved file. Newest first.
    public func scan() -> [RecoveryCandidate] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: store.base, includingPropertiesForKeys: nil)) ?? []
        let marker = SessionMarker(store: store)
        var out: [RecoveryCandidate] = []
        for dir in dirs {
            guard let id = UUID(uuidString: dir.lastPathComponent) else { continue }
            let infos = marker.infos(projectID: id)
            guard let info = infos.max(by: { $0.started < $1.started }), !infos.contains(where: isAlive),
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

    /// Discards the stale markers (user declined recovery or finished it).
    public func dismiss(_ candidate: RecoveryCandidate) {
        let marker = SessionMarker(store: store)
        for info in marker.infos(projectID: candidate.projectID) where !isAlive(info) {
            marker.end(projectID: candidate.projectID, pid: info.pid)
        }
    }
}
