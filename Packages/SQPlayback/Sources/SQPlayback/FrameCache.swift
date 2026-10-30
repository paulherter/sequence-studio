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

/// Byte-budgeted cache of decoded frames, shared by every clip that uses the same media (keys are media + source PTS,
/// so V1 and V2 showing one file never decode or store a frame twice). Thread-safe (`Mutex`); `frame`/`nearest` only
/// take the lock briefly and never wait on decoding or on eviction scoring.
///
/// Eviction: when a new frame does not fit, the entries farthest from the playhead go first, down to a
/// low-water mark (90 % of budget) so the work is amortised over many inserts. Scores are computed on a
/// snapshot outside the lock; the lock is only taken to remove victims. Distance is
/// `|timelineTime - playhead|` (exact, rational); entries on the behind side of the play direction count
/// double. A source frame shown by several clip instances (one media on several tracks, loop copies) is scored by its
/// nearest instance (`Placements`). Entries no instance places on the timeline go first. Ties evict the oldest
/// insertion first. A new frame that would itself be the first victim is not stored. `usedBytes` never exceeds the
/// budget, not even transiently. A payload larger than the whole budget is not stored.
///
/// Memory pressure (`MemoryPressureSource`): a warning trims to 50 % of the budget, critical to 25 %, keeping the frames
/// nearest the playhead; that limit then caps every insert until the source reports normal again.
///
/// Callers must call `setFocus` before prefetching (and whenever the playhead/direction/timeline mapping
/// changes); until then eviction assumes playhead zero, no direction, identity mapping.
public final class FrameCache<Payload: CacheCost>: Sendable {
    /// Single timeline time of a key (nil = not on the timeline).
    public typealias Mapping = @Sendable (FrameKey) -> Time?
    /// Every timeline time at which a key is shown, one per clip instance (empty = not on the timeline).
    public typealias Placements = @Sendable (FrameKey) -> [Time]

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
        var scale: DecodeScale?
        var placements: Placements = { [$0.pts] }
        /// Set by a pressure warning/critical event, cleared by normal: caps the budget.
        var pressureLimit: Int?
        var pressureLevel: MemoryPressure = .normal
        var pressureEvents = 0
        /// Full budget (Settings > Playback can change it while running: `setBudgetBytes`).
        var full = 0

        func budget(_ full: Int) -> Int { pressureLimit.map { min($0, full) } ?? full }

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
        var scale: DecodeScale?
        var placements: Placements
    }

    /// The full budget (without a pressure limit).
    public var budgetBytes: Int { state.withLock { $0.full } }
    private let state = Mutex(State())
    private let pressure: (any MemoryPressureSource)?

    /// `pressure`: started here and canceled when the cache goes away (nil = no pressure handling).
    public init(budgetBytes: Int, pressure: (any MemoryPressureSource)? = nil) {
        state.withLock { $0.full = max(0, budgetBytes) }
        self.pressure = pressure
        pressure?.start { [weak self] level in self?.handleMemoryPressure(level) }
    }

    /// Default budget per ARCHITECTURE §6: 25 % of physical memory, at most 8 GB; system memory-pressure events.
    public convenience init() {
        self.init(budgetBytes: Self.defaultBudgetBytes(physicalMemory: ProcessInfo.processInfo.physicalMemory),
                  pressure: SystemMemoryPressureSource(name: "frame cache"))
    }

    deinit { pressure?.cancel() }

    public static func defaultBudgetBytes(physicalMemory: UInt64) -> Int {
        Int(min(physicalMemory / 4, 8 * 1024 * 1024 * 1024))
    }

    /// Eviction stops here (90 % of budget) so a pass is not repeated on every insert.
    public var lowWaterBytes: Int { budgetBytes / 10 * 9 }
    /// Budget cap from the last pressure warning/critical event (nil = full budget).
    public var pressureLimitBytes: Int? { state.withLock { s in s.pressureLimit.map { min($0, s.full) } } }
    /// Pressure events handled (stats).
    public var pressureEvents: Int { state.withLock { $0.pressureEvents } }
    /// Budget in force now: the full budget, or the pressure limit.
    public var effectiveBudgetBytes: Int { state.withLock { $0.budget($0.full) } }

    /// How many frames of the cached frames' average size fit below the low-water mark of the budget in force (nil while
    /// empty). The prefetch window is capped to it so decoding ahead never evicts frames it just planned.
    public var capacityFrames: Int? {
        state.withLock { s in
            guard !s.entries.isEmpty, s.used > 0 else { return nil }
            let avg = max(1, s.used / s.entries.count)
            return s.budget(s.full) / 10 * 9 / avg
        }
    }

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

    /// Earliest cached frame of `media` at `scale` with `pts >= atOrAfter`. O(log n).
    public func nearest(media: UUID, atOrAfter pts: Time, scale: DecodeScale) -> Payload? {
        state.withLock { s in
            guard let arr = s.index[IndexKey(media: media, scale: scale)] else { return nil }
            let i = State.lowerBound(arr, pts)
            guard i < arr.count else { return nil }
            return s.entries[FrameKey(media: media, pts: arr[i], scale: scale)]?.payload
        }
    }

    public func insert(_ payload: Payload, for key: FrameKey) {
        let cost = max(0, payload.byteCost)
        for _ in 0..<4 {
            let pass: (snap: Snapshot, target: Int)? = state.withLock { s in
                s.remove(key)
                let budget = s.budget(s.full)
                if cost > budget { return nil }
                if s.used + cost <= budget { s.store(payload, key, cost: cost); return nil }
                s.passes += 1
                return (Self.snapshot(s), min(budget / 10 * 9, budget - cost))
            }
            guard let pass else { return }
            if !evict(pass.snap, target: pass.target, candidate: key) { return }   // candidate rejected
        }
        // Concurrent inserters kept refilling the space: drop this frame rather than exceed the budget.
    }

    /// Updates the playhead/direction used for eviction (`direction`: +1 forward, -1 backward, 0 none).
    /// `mapping` converts a key to timeline time (nil = not on the timeline). It is called outside the
    /// lock, on a snapshot, possibly concurrently: keep it cheap and side-effect free.
    /// `scale`: the decode scale in use; frames of another scale are unplaceable (evicted first), so a quality change does
    /// not leave a second copy of the same pictures competing for the budget. nil = every scale counts.
    public func setFocus(playhead: Time, direction: Int, scale: DecodeScale? = nil, mapping: @escaping Mapping = { $0.pts }) {
        setFocus(playhead: playhead, direction: direction, scale: scale, placements: { mapping($0).map { [$0] } ?? [] })
    }

    /// As `setFocus(mapping:)`, with every clip instance of a key: the key is scored by its nearest instance.
    public func setFocus(playhead: Time, direction: Int, scale: DecodeScale? = nil, placements: @escaping Placements) {
        state.withLock { s in
            s.playhead = playhead
            s.direction = direction.signum()
            s.scale = scale
            s.placements = placements
        }
    }

    /// Applies a memory-pressure level (normally called by the `MemoryPressureSource`; callable directly). Warning caps
    /// the budget at 50 % and trims to it, critical at 25 %; normal lifts the cap. Frames nearest the playhead stay.
    public func handleMemoryPressure(_ level: MemoryPressure) {
        let limit = state.withLock { s -> Int? in
            s.pressureLevel = level
            s.pressureLimit = Self.limit(level, full: s.full)
            s.pressureEvents += 1
            return s.pressureLimit
        }
        if let limit { trim(to: limit) }
    }

    private static func limit(_ level: MemoryPressure, full: Int) -> Int? {
        level == .normal ? nil : level.budget(full)
    }

    /// Changes the full budget (Settings > Playback cache size). A smaller budget trims at once (farthest frames first);
    /// a pressure limit in force is recomputed from the new budget.
    public func setBudgetBytes(_ bytes: Int) {
        let target = state.withLock { s -> Int in
            s.full = max(0, bytes)
            s.pressureLimit = Self.limit(s.pressureLevel, full: s.full)
            return s.budget(s.full)
        }
        trim(to: target)
    }

    /// Evicts (farthest first, as in `insert`) until at most `target` bytes are used.
    public func trim(to target: Int) {
        for _ in 0..<4 {
            let snap: Snapshot? = state.withLock { s in
                guard s.used > target else { return nil }
                s.passes += 1
                return Self.snapshot(s)
            }
            guard let snap else { return }
            _ = evict(snap, target: target, candidate: nil)
        }
    }

    /// Timeline spans that cached frames cover (the "yellow bar" of the ruler): every frame covers one `frameDuration`
    /// from each timeline time it is shown at; frames at most one frame apart merge into one span. Keys the focus mapping
    /// cannot place on the timeline are skipped. Sorted, non-overlapping. A pure query (no side effects).
    public func cachedRanges(frameDuration fd: Time) -> [TimeRange] {
        guard fd > .zero else { return [] }
        let (keys, placements) = state.withLock { s in (Array(s.entries.keys), s.placements) }
        let times = keys.flatMap(placements).sorted()
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

    /// Drops every frame of `media` (it was relinked to another file).
    public func remove(media: UUID) {
        state.withLock { s in
            for key in s.entries.keys where key.media == media { s.remove(key) }
        }
    }

    public func removeAll() {
        state.withLock { $0.entries.removeAll(); $0.index.removeAll(); $0.used = 0; $0.generation += 1 }
    }

    private static func snapshot(_ s: State) -> Snapshot {
        Snapshot(items: s.entries.map { ($0.key, $0.value.seq) }, playhead: s.playhead, direction: s.direction,
                 scale: s.scale, placements: s.placements)
    }

    /// Scores `snap` (plus the candidate, if any) outside the lock, then removes victims until `used <= target`.
    /// Returns false if the candidate itself is the next victim (it is not stored).
    private func evict(_ snap: Snapshot, target: Int, candidate: FrameKey?) -> Bool {
        func weighted(_ t: Time) -> Time {
            let delta = t - snap.playhead
            let behind = (snap.direction > 0 && delta.isNegative) || (snap.direction < 0 && delta > .zero)
            let d = delta.isNegative ? -delta : delta
            return behind ? d * 2 : d
        }
        /// Nearest clip instance; nil = no instance = unplaceable = infinitely far.
        func score(_ k: FrameKey) -> Time? {
            if let sc = snap.scale, k.scale != sc { return nil }
            return snap.placements(k).lazy.map(weighted).min()
        }
        var scored = snap.items.map { Scored(key: $0.key, dist: score($0.key), seq: $0.seq, isCandidate: false) }
        if let candidate { scored.append(Scored(key: candidate, dist: score(candidate), seq: .max, isCandidate: true)) }
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

// MARK: Memory pressure
// `MemoryPressure`, `MemoryPressureSource` and `SystemMemoryPressureSource` live in SQCore (`MemoryPressureRegistry`).
