import Foundation

/// Preview render cache, model part 2: which segment keys have a rendered file, how big, last used. Lives next to the
/// files in the cache folder (never in the project file). Entries are keyed by content, so an edit does not "invalidate"
/// anything: the changed segment gets a new key and the old entry ages out (`evict`, `purge`).
public struct RenderCacheIndex: Sendable, Codable, Equatable {
    public struct Entry: Sendable, Codable, Equatable {
        public var bytes: Int64
        public var lastUse: Date
        public var duration: Time
    }
    public private(set) var entries: [String: Entry] = [:]
    public init() {}

    public func contains(_ key: String) -> Bool { entries[key] != nil }
    public var totalBytes: Int64 { entries.values.reduce(0) { $0 + $1.bytes } }

    public mutating func record(key: String, bytes: Int64, duration: Time, now: Date) {
        entries[key] = Entry(bytes: bytes, lastUse: now, duration: duration)
    }
    public mutating func touch(_ key: String, now: Date) { entries[key]?.lastUse = now }
    public mutating func remove(_ key: String) { entries[key] = nil }

    /// Removes entries unused for `maxAge` seconds; returns their keys (the caller deletes the files).
    public mutating func purge(olderThan maxAge: TimeInterval, now: Date, protecting: Set<String> = []) -> [String] {
        let gone = entries.filter { now.timeIntervalSince($0.value.lastUse) > maxAge && !protecting.contains($0.key) }.map(\.key)
        for k in gone { entries[k] = nil }
        return gone.sorted()
    }

    /// Removes least recently used entries until the rest fits `limitBytes`; `protecting` (keys of the current timeline)
    /// stay unless nothing else is left to free.
    public mutating func evict(limitBytes: Int64, protecting: Set<String> = []) -> [String] {
        let list = entries.map { CacheEntry(id: $0.key, bytes: $0.value.bytes, lastUse: $0.value.lastUse) }
        var gone = CacheDiskPolicy.evictionPlan(list, limitBytes: limitBytes, protecting: protecting)
        let freed = gone.reduce(Int64(0)) { $0 + (entries[$1]?.bytes ?? 0) }
        if totalBytes - freed > limitBytes {
            gone = CacheDiskPolicy.evictionPlan(list, limitBytes: limitBytes, protecting: [])
        }
        for k in gone { entries[k] = nil }
        return gone
    }

    /// The cached heavy segment that covers `t`, for playback to read instead of rendering.
    public func cachedSegment(at t: Time, in segments: [RenderCacheSegment]) -> RenderCacheSegment? {
        segments.first { $0.isHeavy && $0.range.contains(t) && contains($0.key) }
    }
}

/// Preview render cache, model part 3: when and what the background renderer works on.
public enum RenderCacheScheduler {
    public static let defaultIdleDelay: TimeInterval = 0.3   // F1: 0.3 s idle

    /// The next heavy, uncached segment to render, or nil to do nothing now. Nothing runs while playing, while the machine
    /// is throttled (`PowerPolicy`), or within `idleDelay` of the last edit. Segments where frames dropped come first,
    /// then the nearest to the playhead. A changed key simply makes a different segment pending, which is how running
    /// work is canceled: the caller re-asks after every edit and drops a job whose key is no longer the answer.
    public static func nextJob(segments: [RenderCacheSegment], index: RenderCacheIndex, playhead: Time,
                               droppedFrames: [Time] = [], playing: Bool, throttled: Bool = false,
                               lastEdit: Date, now: Date, idleDelay: TimeInterval = defaultIdleDelay) -> RenderCacheSegment? {
        guard !playing, !throttled, now.timeIntervalSince(lastEdit) >= idleDelay else { return nil }
        let pending = segments.filter { $0.isHeavy && !index.contains($0.key) }
        func distance(_ s: RenderCacheSegment) -> Time {
            if s.range.contains(playhead) { return .zero }
            return playhead < s.range.start ? s.range.start - playhead : playhead - s.range.end
        }
        func dropped(_ s: RenderCacheSegment) -> Bool { droppedFrames.contains { s.range.contains($0) } }
        return pending.min {
            if dropped($0) != dropped($1) { return dropped($0) }
            let (d0, d1) = (distance($0), distance($1))
            return d0 != d1 ? d0 < d1 : $0.range.start < $1.range.start
        }
    }
}
