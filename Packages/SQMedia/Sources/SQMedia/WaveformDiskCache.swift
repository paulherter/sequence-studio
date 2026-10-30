import Foundation
import Synchronization
import SQCore

/// Peaks of a media file kept on disk across launches (`~/Library/Caches/Sequence Studio/Waveforms`), so reopening a
/// project or importing the same footage again draws its waveforms without decoding the audio a second time.
/// Keyed by path, size, modification date, bucket size and `WaveformBuilder.peaksVersion`: an edited or replaced file
/// or a changed peak builder misses. Oldest files (by last use) go first beyond `limitBytes`.
public final class WaveformDiskCache: Sendable {
    public let directory: URL
    public let limitBytes: Int
    private let disk: CacheDiskPolicy
    private let storesSincePrune = Mutex(0)

    /// The app's cache; nil with `SQ_WAVEFORM_CACHE=0`. Sits in `defaultDirectory` until `configureShared(directory:)`
    /// moves it (the Settings cache folder); callers read it per use, so a change applies to the next build.
    public static var shared: WaveformDiskCache? { sharedCache.withLock { $0 } }

    /// `~/Library/Caches/Sequence Studio/Waveforms`.
    public static var defaultDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Sequence Studio", isDirectory: true).appendingPathComponent("Waveforms", isDirectory: true)
    }

    /// Points the shared cache at `directory` (nil: the default). Existing files are not moved; entries rebuild on demand.
    public static func configureShared(directory: URL?) {
        let made = makeShared(directory: directory)
        sharedCache.withLock { $0 = made }
    }

    private static let sharedCache = Mutex<WaveformDiskCache?>(makeShared(directory: nil))

    private static func makeShared(directory: URL?) -> WaveformDiskCache? {
        guard ProcessInfo.processInfo.environment["SQ_WAVEFORM_CACHE"] != "0",
              let dir = directory ?? defaultDirectory else { return nil }
        return WaveformDiskCache(directory: dir, limitBytes: 1 << 30)
    }

    public init(directory: URL, limitBytes: Int, disk: CacheDiskPolicy = .standard) {
        self.directory = directory
        self.disk = disk
        self.limitBytes = limitBytes
    }

    /// Cache file for this source; nil when the source cannot be read.
    /// `channelMap` (F7.10): peaks of chosen channels are their own entry; nil is the key every entry had before.
    func file(url: URL, baseBucketSize: Int, channelMap: AudioChannelMap? = nil) -> URL? {
        // A fresh URL: `URL` caches resource values, and a file rewritten in place must miss.
        // FileWalk.Values, not `resourceValues`: that traps on Windows for 2-4 GiB files (camera clips).
        guard let v = FileWalk.Values.read(URL(fileURLWithPath: url.path), keys: [.fileSizeKey, .contentModificationDateKey]),
              let size = v.fileSize, let date = v.contentModificationDate else { return nil }
        var text = [url.standardizedFileURL.path, "\(size)", "\(date.timeIntervalSinceReferenceDate)", "\(baseBucketSize)",
                    "v\(WaveformBuilder.peaksVersion).\(WaveformData.formatVersion)"].joined(separator: "|")
        if let m = channelMap {
            text += "|L" + m.left.map(String.init).joined(separator: ",") + "R" + m.right.map(String.init).joined(separator: ",")
        }
        var h: UInt64 = 0xcbf29ce484222325      // FNV-1a 64 (stable across launches)
        for b in text.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return directory.appendingPathComponent(String(format: "%016llx.sqwf", h))
    }

    public func load(url: URL, baseBucketSize: Int, channelMap: AudioChannelMap? = nil) -> WaveformData? {
        guard let f = file(url: url, baseBucketSize: baseBucketSize, channelMap: channelMap), let data = try? Data(contentsOf: f, options: .mappedIfSafe),
              let wf = try? WaveformData(serialized: data), wf.baseBucketSize == baseBucketSize else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: f.path)     // last use, for pruning
        return wf
    }

    public func store(_ wf: WaveformData, url: URL, baseBucketSize: Int, channelMap: AudioChannelMap? = nil) {
        guard let f = file(url: url, baseBucketSize: baseBucketSize, channelMap: channelMap) else { return }
        let data = wf.serialized()
        // Low disk: skip the write (peaks are rebuilt on demand) and free what the cache holds.
        guard disk.allowsWrite(bytes: Int64(data.count), at: directory) else { prune(limit: 0); return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: f, options: .atomic)
        let due = storesSincePrune.withLock { n -> Bool in n += 1; if n >= 32 { n = 0; return true }; return false }
        if due { prune() }
    }

    /// Deletes the least recently used files until the folder fits `limitBytes`.
    public func prune() { prune(limit: limitBytes) }

    func prune(limit: Int) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        var entries = files.filter { $0.pathExtension == "sqwf" }.compactMap { u -> (URL, Int, Date)? in
            guard let v = FileWalk.Values.read(u, keys: Set(keys)) else { return nil }
            return (u, v.fileSize ?? 0, v.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        guard total > limit else { return }
        entries.sort { $0.2 < $1.2 }
        for (u, size, _) in entries where total > limit {
            try? FileManager.default.removeItem(at: u)
            total -= size
        }
    }
}
