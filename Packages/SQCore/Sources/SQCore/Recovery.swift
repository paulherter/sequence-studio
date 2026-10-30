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
    /// Set for a named checkpoint (`<timestamp>~<name>.sqproj`): it is never pruned.
    public var name: String? = nil
}

/// One folder per project id under `base`; each version is a `<timestamp>.sqproj` package.
public struct AutosaveStore: Sendable {
    public typealias Writer = @Sendable (Project, URL) throws -> Void

    public let base: URL
    public var policy: AutosavePolicy
    let writer: Writer

    public static var defaultBase: URL {
        // A test process (thousands of throwaway sessions, often killed) writes into its own temp folder: its crash
        // markers piled up to 60k folders in the user's Autosave folder and made the launch recovery scan take 8 s.
        if isTestProcess {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("SequenceStudio-test-autosave-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Sequence Studio/Autosave", isDirectory: true)
    }

    /// XCTest / Swift Testing host (`swift test`, xcodebuild test).
    static let isTestProcess: Bool = {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil || env["XCTestSessionIdentifier"] != nil { return true }
        if ["xctest", "swiftpm-testing-helper"].contains(ProcessInfo.processInfo.processName) { return true }
        return Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
    }()

    public init(base: URL = AutosaveStore.defaultBase, policy: AutosavePolicy = AutosavePolicy(),
                writer: @escaping Writer = { try ProjectFile.write($0, to: $1) }) {
        self.base = base; self.policy = policy; self.writer = writer
    }

    public func folder(for projectID: UUID) -> URL {
        base.appendingPathComponent(projectID.uuidString, isDirectory: true)
    }

    static let ext = ProjectFile.fileExtension

    static func formatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f
    }

    static let nameSeparator = "~"

    /// A file-name safe checkpoint name: path and separator characters become spaces, runs collapse; nil when nothing is left.
    public static func sanitized(_ raw: String) -> String? {
        let bad = CharacterSet(charactersIn: "/:\\~.").union(.controlCharacters).union(.newlines)
        let words = raw.components(separatedBy: bad).flatMap { $0.split(whereSeparator: \.isWhitespace) }
        let s = String(words.joined(separator: " ").prefix(80))
        return s.isEmpty ? nil : s
    }

    /// Writes the snapshot into a hidden temp package, then renames it into place: a failure never leaves a partial version.
    @discardableResult
    public func write(_ project: Project, date: Date = Date(), name checkpoint: String? = nil) throws -> AutosaveVersion {
        let fm = FileManager.default
        let dir = folder(for: project.id)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let checkpointName = checkpoint.flatMap(Self.sanitized)
        let name = Self.formatter().string(from: date) + (checkpointName.map { Self.nameSeparator + $0 } ?? "")
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
        return AutosaveVersion(url: final, date: date, name: checkpointName)
    }

    /// Versions of a project, newest first.
    public func versions(for projectID: UUID) -> [AutosaveVersion] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder(for: projectID),
                                                                  includingPropertiesForKeys: nil)) ?? []
        let f = Self.formatter()
        return items.compactMap { u -> AutosaveVersion? in
            guard ProjectFile.isProjectURL(u), !u.lastPathComponent.hasPrefix(".") else { return nil }
            let base = u.deletingPathExtension().lastPathComponent
            let parts = base.components(separatedBy: Self.nameSeparator)
            guard let d = f.date(from: parts[0]) else { return nil }
            let label = parts.count > 1 ? Self.sanitized(parts.dropFirst().joined(separator: " ")) : nil
            return AutosaveVersion(url: u, date: d, name: label)
        }.sorted { $0.date > $1.date }
    }

    /// Drops plain versions beyond `keep` and older than `maxAge`; the newest version and `keeping` always stay
    /// (and count towards `keep`). Also removes orphaned `.<uuid>.tmp` dirs older than one hour.
    public func prune(_ projectID: UUID, now: Date = Date(), keeping: URL? = nil) throws {
        let fm = FileManager.default
        var kept = 0
        // Named checkpoints are never pruned and do not count towards `keep`.
        for (i, v) in versions(for: projectID).filter({ $0.name == nil }).enumerated() {
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
        /// Set once a crash report was written for this marker, so a marker kept for recovery reports only once.
        public var reported: Bool? = nil
    }

    public let store: AutosaveStore
    public init(store: AutosaveStore) { self.store = store }

    static func fileName(_ pid: Int32) -> String { "running-\(pid).lock" }
    func file(_ id: UUID, pid: Int32) -> URL { store.folder(for: id).appendingPathComponent(Self.fileName(pid)) }

    /// Kernel start time of a process (proc_pidinfo); nil when the process does not exist.
    public static func startTime(of pid: Int32) -> Date? {
        #if canImport(Darwin)
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
        #elseif os(Windows)
        return WindowsProcess.startTime(of: pid)
        #else
        // Linux: field 22 of /proc/<pid>/stat is the start time in clock ticks after boot.
        guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let close = stat.lastIndex(of: ")"),
              let sys = try? String(contentsOfFile: "/proc/stat", encoding: .utf8),
              let btimeLine = sys.split(separator: "\n").first(where: { $0.hasPrefix("btime ") }),
              let btime = TimeInterval(btimeLine.dropFirst(6)) else { return nil }
        // After "(comm)" the fields start at number 3, so starttime is index 19 of the remainder.
        let rest = stat[stat.index(after: close)...].split(separator: " ")
        guard rest.count > 19, let ticks = TimeInterval(rest[19]) else { return nil }
        return Date(timeIntervalSince1970: btime + ticks / TimeInterval(sysconf(Int32(_SC_CLK_TCK))))
        #endif
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

    /// Removes only this process's marker, and the project folder when nothing else is left in it (`rmdir` only
    /// removes an empty folder, so a marker or autosave written meanwhile keeps it).
    public func end(projectID: UUID, pid: Int32 = ProcessInfo.processInfo.processIdentifier) {
        try? FileManager.default.removeItem(at: file(projectID, pid: pid))
        rmdir(store.folder(for: projectID).path)
    }

    /// All markers of a project, one per process.
    public func infos(projectID: UUID) -> [Info] {
        let items = (try? FileManager.default.contentsOfDirectory(at: store.folder(for: projectID), includingPropertiesForKeys: nil)) ?? []
        return Self.markers(in: items).map(\.info)
    }

    static func isMarker(_ u: URL) -> Bool { u.lastPathComponent.hasPrefix("running-") && u.pathExtension == "lock" }

    /// Readable markers among a folder's items, sorted by file name (unreadable ones are skipped, never deleted).
    static func markers(in items: [URL]) -> [(url: URL, info: Info)] {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return items.filter(isMarker)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { u in (try? Data(contentsOf: u)).flatMap { try? d.decode(Info.self, from: $0) }.map { (u, $0) } }
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
        #if os(Windows)
        return WindowsProcess.isAlive(pid)
        #else
        return kill(pid, 0) == 0 || errno == EPERM
        #endif
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
    /// Folders without any autosave version can never be recovered: their dead markers are removed (and the folder when
    /// nothing else is left), so stale markers do not pile up and slow the next launch. Touches the disk: call it off
    /// the main thread.
    public func scan() -> [RecoveryCandidate] { scanSessions().candidates }

    /// `scan()` plus every crashed session found (also those without an autosave or already saved), for crash reports.
    public func scanSessions() -> (candidates: [RecoveryCandidate], crashed: [CrashedSession]) {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: store.base, includingPropertiesForKeys: nil)) ?? []
        var out: [RecoveryCandidate] = []
        var crashed: [CrashedSession] = []
        for dir in dirs {
            guard let id = UUID(uuidString: dir.lastPathComponent) else { continue }
            let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            if items.isEmpty {
                // Left by older builds' clean close. A fresh one may belong to a session about to write its marker.
                let m = (try? fm.attributesOfItem(atPath: dir.path))?[.modificationDate] as? Date
                if let m, Date().timeIntervalSince(m) > 3600 { rmdir(dir.path) }
                continue
            }
            guard items.contains(where: SessionMarker.isMarker) else { continue }
            let markers = SessionMarker.markers(in: items)
            let infos = markers.map(\.info)
            let newestVersion = store.versions(for: id).first
            if let latest = infos.max(by: { $0.started < $1.started }), !infos.contains(where: isAlive), latest.reported != true {
                crashed.append(CrashedSession(projectID: id, info: latest, autosave: newestVersion))
            }
            guard let newest = newestVersion else {
                for m in markers where !isAlive(m.info) { try? fm.removeItem(at: m.url) }
                rmdir(dir.path)      // only when nothing else is left
                continue
            }
            guard let info = infos.max(by: { $0.started < $1.started }), !infos.contains(where: isAlive) else { continue }
            let url = info.projectPath.map { URL(fileURLWithPath: $0) }
            if let url,
               let saved = (try? fm.attributesOfItem(atPath: url.appendingPathComponent("project.json").path))?[.modificationDate] as? Date,
               newest.date <= saved {
                // Saved after the last autosave: nothing to recover, and a dead marker left here would be reported at
                // every launch as a crash (the session is reported once, in this scan's `crashed`).
                for m in markers where !isAlive(m.info) { try? fm.removeItem(at: m.url) }
                rmdir(dir.path)
                continue
            }
            out.append(RecoveryCandidate(projectID: id, projectName: info.projectName, projectURL: url, autosave: newest))
        }
        return (out.sorted { $0.autosave.date > $1.autosave.date }, crashed.sorted { $0.info.started > $1.info.started })
    }

    /// Marks the sessions as reported: a marker kept for the recovery offer no longer raises a crash report.
    public func markReported(_ sessions: [CrashedSession]) {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        let marker = SessionMarker(store: store)
        for s in sessions {
            var info = s.info
            info.reported = true
            let url = marker.file(s.projectID, pid: info.pid)
            guard FileManager.default.fileExists(atPath: url.path), let data = try? e.encode(info) else { continue }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// The autosave as the project it was: same id and name, so it carries on as that project (the session decides where it saves).
    public func recover(_ candidate: RecoveryCandidate) throws -> Project {
        try store.read(candidate.autosave)
    }

    /// Discards the stale markers (user declined recovery or finished it).
    public func dismiss(_ candidate: RecoveryCandidate) {
        let marker = SessionMarker(store: store)
        for info in marker.infos(projectID: candidate.projectID) where !isAlive(info) {
            marker.end(projectID: candidate.projectID, pid: info.pid)
        }
    }
}
