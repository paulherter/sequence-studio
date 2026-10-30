import Foundation

/// Size and modification time of a media file. A change means the file grew (capture in progress) or was
/// re-rendered over the same path, so the item must be refreshed (FILMCRAFT-PRS #625).
public struct MediaFileStamp: Equatable, Sendable {
    public var size: Int64
    public var modified: Date

    public init(size: Int64, modified: Date) {
        self.size = size
        self.modified = modified
    }

    /// nil when the file is missing or unreadable.
    public static func read(_ url: URL) -> MediaFileStamp? {
        // FileManager, not URLResourceValues: URL caches resource values and would hide later changes.
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              let modified = attrs[.modificationDate] as? Date else { return nil }
        return MediaFileStamp(size: Int64(size), modified: modified)
    }
}

/// Remembers the stamp of each tracked file; `poll()` returns the URLs whose stamp changed since the last
/// poll. A file that disappears or reappears counts as changed once (relink handles the rest).
/// Plain value type: the caller drives it from a timer and owns the interval and the on/off preference.
public struct MediaFileStampTracker: Sendable {
    private struct Entry: Sendable { var stamp: MediaFileStamp? }
    private var stamps: [URL: Entry] = [:]
    private let reader: @Sendable (URL) -> MediaFileStamp?

    public init(reader: @escaping @Sendable (URL) -> MediaFileStamp? = { MediaFileStamp.read($0) }) {
        self.reader = reader
    }

    public var tracked: Set<URL> { Set(stamps.keys) }

    /// Starts tracking `url` with its current stamp (no change reported for it).
    public mutating func track(_ url: URL) {
        if stamps.index(forKey: url) == nil { stamps[url] = Entry(stamp: reader(url)) }
    }

    public mutating func untrack(_ url: URL) { stamps.removeValue(forKey: url) }

    /// Replaces the tracked set: adds new URLs, drops the ones no longer present.
    public mutating func setTracked(_ urls: some Sequence<URL>) {
        let wanted = Set(urls)
        for url in Array(stamps.keys) where !wanted.contains(url) { stamps.removeValue(forKey: url) }
        for url in wanted { track(url) }
    }

    /// URLs whose stamp differs from the remembered one, sorted by path; remembered stamps are updated.
    public mutating func poll() -> [URL] {
        var changed: [URL] = []
        for (url, old) in stamps {
            let now = reader(url)
            if now != old.stamp {
                stamps[url] = Entry(stamp: now)
                changed.append(url)
            }
        }
        return changed.sorted { $0.path < $1.path }
    }
}
