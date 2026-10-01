import Foundation
import Synchronization
import SQCore
import SQMedia

/// Decoded frames are keyed by media + source PTS (never timeline position).
public struct FrameKey: Sendable, Hashable {
    public var media: UUID
    public var pts: Time
    public var scale: DecodeScale
    public init(media: UUID, pts: Time, scale: DecodeScale = .full) {
        self.media = media; self.pts = pts; self.scale = scale
    }
}

public protocol CacheCost: Sendable { var byteCost: Int { get } }

/// Byte-budgeted cache of decoded frames. Thread-safe (`Mutex`); `frame`/`nearest` only take the lock
/// briefly and never wait on decoding or on eviction scoring.
///
/// Eviction: when a new frame does not fit, the entries farthest from the playhead go first, down to a
/// low-water mark (90 % of budget) so the work is amortised over many inserts. Scores are computed on a
/// snapshot outside the lock; the lock is only taken to remove victims. Distance is
/// `|timelineTime - playhead|` (exact, rational); entries on the behind side of the play direction count
/// double. Entries the mapping cannot place on the timeline (nil) go first. Ties evict the oldest insertion
/// first. A new frame that would itself be the first victim is not stored. `usedBytes` never exceeds the
/// budget, not even transiently. A payload larger than the whole budget is not stored.
///
/// Callers must call `setFocus` before prefetching (and whenever the playhead/direction/timeline mapping
/// changes); until then eviction assumes playhead zero, no direction, identity mapping.
public final class FrameCache<Payload: CacheCost>: Sendable {
    public typealias Mapping = @Sendable (FrameKey) -> Time?

    private struct Entry { var payload: Payload; var cost: Int; var seq: UInt64 }
    private struct IndexKey: Hashable { var media: UUID; var scale: DecodeScale }
    private struct State {
        var entries: [FrameKey: Entry] = [:]
        /// Sorted pts per (media, scale): `nearest` is a binary search.
        var index: [IndexKey: [Time]] = [:]
        var used = 0
        var seq: UInt64 = 0
        var passes = 0
        var generation = 0
        var playhead: Time = .zero
        var direction = 0
        var mapping: Mapping = { $0.pts }

        mutating func store(_ payload: Payload, _ key: FrameKey, cost: Int) {
            seq += 1
            generation += 1
            entries[key] = Entry(payload: payload, cost: cost, seq: seq)
            used += cost
            let ik = IndexKey(media: key.media, scale: key.scale)
            var arr = index[ik] ?? []
            arr.insert(key.pts, at: Self.lowerBound(arr, key.pts))
            index[ik] = arr
        }

        @discardableResult
        mutating func remove(_ key: FrameKey) -> Entry? {
            guard let e = entries.removeValue(forKey: key) else { return nil }
            generation += 1
            used -= e.cost
            let ik = IndexKey(media: key.media, scale: key.scale)
            if var arr = index[ik] {
                let i = Self.lowerBound(arr, key.pts)
                if i < arr.count, arr[i] == key.pts { arr.remove(at: i) }
                index[ik] = arr.isEmpty ? nil : arr
            }
            return e
        }

        /// First index with `arr[i] >= t`.
        static func lowerBound(_ arr: [Time], _ t: Time) -> Int {
            var lo = 0, hi = arr.count
            while lo < hi { let m = (lo + hi) / 2; if arr[m] < t { lo = m + 1 } else { hi = m } }
            return lo
        }
    }

    private struct Scored { var key: FrameKey; var dist: Time?; var seq: UInt64; var isCandidate: Bool }

    private struct Snapshot {
        var items: [(key: FrameKey, seq: UInt64)]
        var playhead: Time
        var direction: Int
        var mapping: Mapping
    }

    public let budgetBytes: Int
    private let state = Mutex(State())

    public init(budgetBytes: Int) { self.budgetBytes = max(0, budgetBytes) }

    /// Default budget per ARCHITECTURE §6: 25 % of physical memory, at most 8 GB.
    public convenience init() {
        self.init(budgetBytes: Self.defaultBudgetBytes(physicalMemory: ProcessInfo.processInfo.physicalMemory))
    }

    public static func defaultBudgetBytes(physicalMemory: UInt64) -> Int {
        Int(min(physicalMemory / 4, 8 * 1024 * 1024 * 1024))
    }

    /// Eviction stops here (90 % of budget) so a pass is not repeated on every insert.
    public var lowWaterBytes: Int { budgetBytes / 10 * 9 }

    public var usedBytes: Int { state.withLock { $0.used } }
    public var count: Int { state.withLock { $0.entries.count } }
    /// Bumped on every insert, removal and clear: lets a poller skip `cachedRanges` when nothing changed.
    public var generation: Int { state.withLock { $0.generation } }
    /// Number of eviction passes started (for tests and stats).
    var evictionPasses: Int { state.withLock { $0.passes } }

    public func frame(_ key: FrameKey) -> Payload? {
        state.withLock { $0.entries[key]?.payload }
    }

    /// Latest cached frame of `media` at `scale` with `pts <= atOrBefore`. O(log n).
    public func nearest(media: UUID, atOrBefore pts: Time, scale: DecodeScale) -> Payload? {
        state.withLock { s in
            guard let arr = s.index[IndexKey(media: media, scale: scale)] else { return nil }
            var i = State.lowerBound(arr, pts)            // first >= pts
            if !(i < arr.count && arr[i] == pts) { i -= 1 }
            guard i >= 0 else { return nil }
            return s.entries[FrameKey(media: media, pts: arr[i], scale: scale)]?.payload
        }
    }

    public func insert(_ payload: Payload, for key: FrameKey) {
        let cost = max(0, payload.byteCost)
        let budget = budgetBytes
        for _ in 0..<4 {
            let snap: Snapshot? = state.withLock { s in
                s.remove(key)
                if cost > budget { return nil }
                if s.used + cost <= budget { s.store(payload, key, cost: cost); return nil }
                s.passes += 1
                return Snapshot(items: s.entries.map { ($0.key, $0.value.seq) },
                                playhead: s.playhead, direction: s.direction, mapping: s.mapping)
            }
            guard let snap else { return }
            let target = min(lowWaterBytes, budget - cost)
            if !evict(snap, target: target, candidate: key) { return }   // candidate rejected
        }
        // Concurrent inserters kept refilling the space: drop this frame rather than exceed the budget.
    }

    /// Updates the playhead/direction used for eviction (`direction`: +1 forward, -1 backward, 0 none).
    /// `mapping` converts a key to timeline time (nil = not on the timeline). It is called outside the
    /// lock, on a snapshot, possibly concurrently: keep it cheap and side-effect free.
    public func setFocus(playhead: Time, direction: Int, mapping: @escaping Mapping = { $0.pts }) {
        state.withLock { s in
            s.playhead = playhead
            s.direction = direction.signum()
            s.mapping = mapping
        }
    }

    /// Timeline spans that cached frames cover (the "yellow bar" of the ruler): every frame covers one `frameDuration`
    /// from its timeline time; frames at most one frame apart merge into one span. Keys the focus mapping cannot place
    /// on the timeline are skipped. Sorted, non-overlapping. A pure query (no side effects).
    public func cachedRanges(frameDuration fd: Time) -> [TimeRange] {
        guard fd > .zero else { return [] }
        let (keys, mapping) = state.withLock { s in (Array(s.entries.keys), s.mapping) }
        let times = keys.compactMap(mapping).sorted()
        var out: [TimeRange] = []
        for t in times {
            if let last = out.last, t <= last.end + fd {
                if t + fd > last.end { out[out.count - 1] = TimeRange(start: last.start, end: t + fd) }
            } else {
                out.append(TimeRange(start: t, duration: fd))
            }
        }
        return out
    }

    public func removeAll() {
        state.withLock { $0.entries.removeAll(); $0.index.removeAll(); $0.used = 0; $0.generation += 1 }
    }

    /// Scores `snap` (plus the candidate) outside the lock, then removes victims until `used <= target`.
    /// Returns false if the candidate itself is the next victim (it is not stored).
    private func evict(_ snap: Snapshot, target: Int, candidate: FrameKey) -> Bool {
        func score(_ k: FrameKey) -> Time? {
            guard let t = snap.mapping(k) else { return nil }   // nil = unplaceable = infinitely far
            let delta = t - snap.playhead
            let behind = (snap.direction > 0 && delta.isNegative) || (snap.direction < 0 && delta > .zero)
            let d = delta.isNegative ? -delta : delta
            return behind ? d * 2 : d
        }
        var scored = snap.items.map { Scored(key: $0.key, dist: score($0.key), seq: $0.seq, isCandidate: false) }
        scored.append(Scored(key: candidate, dist: score(candidate), seq: .max, isCandidate: true))
        scored.sort { a, b in
            switch (a.dist, b.dist) {
            case (nil, nil): return a.seq < b.seq
            case (nil, _): return true
            case (_, nil): return false
            case let (x?, y?): return x == y ? a.seq < b.seq : x > y
            }
        }
        return state.withLock { s in
            for item in scored {
                if s.used <= target { return true }
                if item.isCandidate { return false }
                if s.entries[item.key]?.seq == item.seq { s.remove(item.key) }
            }
            return true
        }
    }
}
