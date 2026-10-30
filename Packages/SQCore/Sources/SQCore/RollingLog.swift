import Foundation

/// Rolling text log: `sq.log` plus `sq.1.log`, `sq.2.log` (oldest last). A file that would grow past
/// `maxBytesPerFile` is rotated first. Writes happen on a private serial queue, so callers never block on disk.
public final class RollingLog: @unchecked Sendable {
    private let directory: URL
    private let maxBytes: Int
    private let fileCount: Int
    private let queue = DispatchQueue(label: "sq.log", qos: .utility)
    private var handle: FileHandle?
    private var size = 0

    public init(directory: URL, maxBytesPerFile: Int = 700_000, fileCount: Int = 3) {
        self.directory = directory
        self.maxBytes = maxBytesPerFile
        self.fileCount = max(fileCount, 1)
    }

    public var currentFile: URL { url(0) }

    private func url(_ i: Int) -> URL { directory.appendingPathComponent(i == 0 ? "sq.log" : "sq.\(i).log") }

    /// Appends one line (newline added). Returns immediately.
    public func write(_ line: String) {
        queue.async { self.append(line + "\n") }
    }

    /// Waits until everything written so far is on disk.
    public func flush() { queue.sync { try? handle?.synchronize() } }

    private func append(_ text: String) {
        let data = Data(text.utf8)
        if handle == nil { open() }
        if size > 0, size + data.count > maxBytes { rotate() }
        guard let handle else { return }
        do { try handle.write(contentsOf: data); size += data.count } catch { self.handle = nil }
    }

    private func open() {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url(0).path) { fm.createFile(atPath: url(0).path, contents: nil) }
        handle = try? FileHandle(forWritingTo: url(0))
        size = Int((try? handle?.seekToEnd()) ?? 0)
    }

    private func rotate() {
        try? handle?.close(); handle = nil
        let fm = FileManager.default
        try? fm.removeItem(at: url(fileCount - 1))
        for i in stride(from: fileCount - 2, through: 0, by: -1) where fm.fileExists(atPath: url(i).path) {
            try? fm.moveItem(at: url(i), to: url(i + 1))
        }
        open()
    }
}

/// App-wide log (`~/Library/Logs/Sequence Studio/sq.log`). Cheap: one string and one queue hop per call.
public enum SQLog {
    public static let directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Sequence Studio", isDirectory: true)
    public static let shared = RollingLog(directory: directory)

    public static func info(_ message: @autoclosure () -> String) { write("INFO ", message()) }
    public static func error(_ message: @autoclosure () -> String) { write("ERROR", message()) }

    private static func write(_ level: String, _ message: String) {
        shared.write("\(stamp()) \(level) \(message)")
    }

    private static func stamp() -> String {
        let now = Date()
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        let millis = Int((now.timeIntervalSince1970 - now.timeIntervalSince1970.rounded(.down)) * 1000)
        return String(format: "%04d-%02d-%02d %02d:%02d:%02d.%03d", parts.year ?? 0, parts.month ?? 0,
                      parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0, millis)
    }
}
