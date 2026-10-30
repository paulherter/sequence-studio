import Foundation

/// A session that ended without a clean close: its marker was left behind and its process is gone.
public struct CrashedSession: Sendable, Equatable {
    public var projectID: UUID
    public var info: SessionMarker.Info
    /// Newest autosave of the project, nil when none was written.
    public var autosave: AutosaveVersion?
}

/// Plain-text crash report written at the next launch (the process itself cannot write after a crash): what was open,
/// a summary of the last autosaved state (counts and media names only, no paths) and the tail of the app log.
public enum CrashReport {
    /// Counts and media names of a project: no file paths, no text content.
    public static func stateSummary(of project: Project) -> [String] {
        var lines = ["project: \(project.name)",
                     "media items: \(project.media.count)",
                     "sequences: \(project.timelines.count)"]
        for tl in project.timelines.prefix(10) {
            let clips = tl.tracks.reduce(0) { $0 + $1.clips.count }
            lines.append("  sequence \"\(tl.name)\": \(tl.tracks.count) tracks, \(clips) clips")
        }
        let names = project.media.prefix(30).map { "  \($0.name)" }
        if !names.isEmpty { lines.append("media names:"); lines += names }
        if project.media.count > 30 { lines.append("  ... and \(project.media.count - 30) more") }
        return lines
    }

    /// Replaces the home folder in a log line with `~` so a report does not carry the user name.
    public static func redact(_ line: String, home: String = NSHomeDirectory()) -> String {
        guard home.count > 1 else { return line }
        return line.replacingOccurrences(of: home, with: "~")
    }

    /// The last `count` lines of the log files given newest first (`sq.log`, `sq.1.log`, ...), in time order.
    public static func logTail(files: [URL], count: Int = 80) -> [String] {
        var out: [String] = []
        for f in files {
            guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            out = lines + out
            if out.count >= count { break }
        }
        return Array(out.suffix(count))
    }

    public static func render(session: CrashedSession, project: Project?, log: [String], appVersion: String,
                              os: String, systemReport: String?, now: Date = Date(), home: String = NSHomeDirectory()) -> String {
        let iso = ISO8601DateFormatter()
        var out = ["Sequence Studio crash report",
                   "created: \(iso.string(from: now))",
                   "app: \(appVersion)",
                   "system: \(os)",
                   "session started: \(iso.string(from: session.info.started)) (pid \(session.info.pid))",
                   "project open: \(session.info.projectName)",
                   "saved to disk: \(session.info.projectPath == nil ? "never saved" : "yes")"]
        if let a = session.autosave { out.append("last autosave: \(iso.string(from: a.date))") } else { out.append("last autosave: none") }
        if let systemReport { out.append("system crash report: \(systemReport)") }
        out.append("")
        out.append("State at last autosave")
        out += project.map(stateSummary(of:)) ?? ["(no autosave to read)"]
        out.append("")
        out.append("Last log lines")
        out += log.map { redact($0, home: home) }
        return out.joined(separator: "\n") + "\n"
    }
}

/// Folder of written reports (`Sequence Studio/Crash Reports`); the newest ones stay.
public struct CrashReportStore: Sendable {
    public let directory: URL
    public var keep: Int

    public static var defaultDirectory: URL {
        AutosaveStore.defaultBase.deletingLastPathComponent().appendingPathComponent("Crash Reports", isDirectory: true)
    }

    public init(directory: URL = CrashReportStore.defaultDirectory, keep: Int = 10) {
        self.directory = directory; self.keep = max(keep, 1)
    }

    @discardableResult
    public func write(_ text: String, date: Date = Date()) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let url = directory.appendingPathComponent("crash-\(f.string(from: date)).txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        for old in reports().dropFirst(keep) { try? fm.removeItem(at: old) }
        return url
    }

    /// Report files, newest first (the name sorts by time).
    public func reports() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.lastPathComponent.hasPrefix("crash-") && $0.pathExtension == "txt" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}
