import Foundation
import SQCore

/// What a start card shows of a recent project: the active sequence's frame size, rate and length. Shared by the Mac start
/// window and the portable start screen (SQDrawShell `ShellStartScreen`).
public struct StartProjectInfo: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var fps: Double
    public var seconds: Int64
    /// First video or still clip on the active sequence: its file and the time of its first used frame (the card poster).
    public var posterPath: String?
    public var posterSeconds: Double
    /// The poster file is not on disk: the card says "Locate media…".
    public var mediaMissing = false

    public nonisolated init(width: Int, height: Int, fps: Double, seconds: Int64, posterPath: String? = nil, posterSeconds: Double = 0) {
        self.width = width; self.height = height; self.fps = fps; self.seconds = seconds
        self.posterPath = posterPath; self.posterSeconds = posterSeconds
    }

    public nonisolated init?(project: Project) {
        guard let tl = project.timelines.first(where: { $0.id == project.activeTimeline }) ?? project.timelines.first else { return nil }
        let fd = tl.format.frameDuration, d = tl.duration
        let first = tl.tracks.filter { $0.kind == .video }.flatMap(\.clips).min { $0.start < $1.start }
        let ref = first.flatMap { c in project.media.first { $0.id == c.media } }
        let at = first.map { Double($0.source.start.value) / Double(max($0.source.start.timescale, 1)) } ?? 0
        self.init(width: tl.format.width, height: tl.format.height,
                  fps: Double(fd.timescale) / Double(max(fd.value, 1)), seconds: d.value / d.timescale,
                  posterPath: ref?.path, posterSeconds: at)
    }

    /// Reads each project file (off the main thread; unreadable ones are left out).
    public nonisolated static func read(_ paths: [String]) -> [String: StartProjectInfo] {
        var out: [String: StartProjectInfo] = [:]
        for p in paths {
            guard let project = try? ProjectFile.read(from: URL(fileURLWithPath: p)),
                  var info = StartProjectInfo(project: project) else { continue }
            if let m = info.posterPath { info.mediaMissing = !FileManager.default.fileExists(atPath: m) }
            out[p] = info
        }
        return out
    }

    /// "9:16", "4:5", "1:1", "16:9" (reduced ratio), "2.39:1" when the reduced ratio is not a common one.
    public nonisolated static func aspect(_ w: Int, _ h: Int) -> String {
        guard w > 0, h > 0 else { return "" }
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let g = gcd(w, h), a = w / g, b = h / g
        if max(a, b) <= 21 { return "\(a):\(b)" }
        return String(format: "%.2f:1", Double(w) / Double(h))
    }

    public var aspect: String { Self.aspect(width, height) }
    public var size: String { "\(width) × \(height)" }
    public var rate: String {
        let r = fps.rounded()
        return abs(fps - r) < 0.01 ? "\(Int(r)) fps" : String(format: "%.2f fps", fps)
    }
    /// "02:14", "1:02:14".
    public var length: String {
        let s = max(seconds, 0), h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }
}

/// The start screen's date wording (board "Start Screen B"; English UI).
public enum StartLabels {
    /// "Today", "Yesterday", otherwise a short date like "28 Sep".
    public static func day(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) { return "Yesterday" }
        return date.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "en_GB")))
    }

    /// Group heading of the Recent grid: Today, This week (last 7 days), Earlier.
    public static let groups = ["Today", "This week", "Earlier"]
    public static func group(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let week = calendar.date(byAdding: .day, value: -7, to: now), date > week { return "This week" }
        return "Earlier"
    }

    /// Card caption time: "Just now", "12 min ago", "2 h ago", then the day label.
    public static func relative(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let s = now.timeIntervalSince(date)
        if s < 60 { return "Just now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        if s < 86_400, calendar.isDate(date, inSameDayAs: now) { return "\(Int(s / 3600)) h ago" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) { return "Yesterday" }
        if s < 6 * 86_400 { return date.formatted(.dateTime.weekday(.abbreviated).locale(Locale(identifier: "en_GB"))) }
        return day(date, now: now, calendar: calendar)
    }
}

extension TemplateFolder {
    /// Where the user's templates live: Application Support (AppData on Windows) / Sequence Studio / Templates, never inside
    /// a project file. The Mac `TemplateStore` and the portable start screen read the same folder.
    public static var standard: TemplateFolder {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return TemplateFolder(url: base.appendingPathComponent("Sequence Studio/Templates", isDirectory: true))
    }
}
