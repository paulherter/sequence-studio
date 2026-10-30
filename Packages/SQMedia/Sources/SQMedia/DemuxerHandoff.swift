import Foundation
import Synchronization

/// Hands the demuxer `MediaImporter.probe` built (a full sample-table walk) to the first open of the same file right after
/// import (`ProjectMediaResolver.openDemuxer`), so a freshly imported file is not walked twice (docs/PLAYBACK-PERF.md
/// "Import speed"). Demuxers are immutable after init, so sharing one is safe. Keyed by path + size + modification date
/// (a file changed in between is opened anew); each entry is taken once, expires after `lifetime`, and at most `capacity`
/// demuxers / `sampleBudget` index entries are held (oldest dropped first; an hour of 60 fps is 216 000 entries, ~25 MB).
public enum DemuxerHandoff {
    public static let lifetime: TimeInterval = 120
    public static let capacity = 64
    public static let sampleBudget = 1_000_000

    public struct Key: Hashable, Sendable { let path: String; let size: Int64; let modified: Date? }
    private struct Entry { let key: Key; let demuxer: any Demuxing; let stored: Date }
    private static let entries = Mutex<[Entry]>([])
    /// Off for before/after measurements (EngineBench `import-probe`).
    private static let enabled = Atomic<Bool>(true)
    public static var isEnabled: Bool {
        get { enabled.load(ordering: .relaxed) }
        set { enabled.store(newValue, ordering: .relaxed); if !newValue { entries.withLock { $0.removeAll() } } }
    }

    public static func key(_ url: URL) -> Key? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return Key(path: url.standardizedFileURL.path, size: (a[.size] as? NSNumber)?.int64Value ?? -1, modified: a[.modificationDate] as? Date)
    }

    /// Keeps `demuxer` (built from `url`) for the next `take` of the same file.
    public static func store(_ demuxer: any Demuxing, for url: URL, key preKey: Key? = nil, now: Date = Date()) {
        guard isEnabled, let k = preKey ?? key(url) else { return }
        entries.withLock { e in
            e.removeAll { now.timeIntervalSince($0.stored) > lifetime || $0.key.path == k.path }
            e.append(Entry(key: k, demuxer: demuxer, stored: now))
            if e.count > capacity { e.removeFirst(e.count - capacity) }
            var samples = e.reduce(0) { $0 + $1.demuxer.index.count }
            while samples > sampleBudget, let first = e.first {
                samples -= first.demuxer.index.count
                e.removeFirst()
            }
        }
    }

    /// The demuxer stored for `url` if the file is unchanged and the entry not expired; removed either way.
    public static func take(_ url: URL, now: Date = Date()) -> (any Demuxing)? {
        guard isEnabled else { return nil }
        let path = url.standardizedFileURL.path
        guard let hit = entries.withLock({ e -> Entry? in
            e.removeAll { now.timeIntervalSince($0.stored) > lifetime }
            guard let i = e.firstIndex(where: { $0.key.path == path }) else { return nil }
            return e.remove(at: i)
        }) else { return nil }
        return key(url) == hit.key ? hit.demuxer : nil
    }

    /// Number of entries held (tests).
    static var count: Int { entries.withLock { $0.count } }
    static func removeAll() { entries.withLock { $0.removeAll() } }
}
