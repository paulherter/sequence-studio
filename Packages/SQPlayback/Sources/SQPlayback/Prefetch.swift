import Foundation
import Synchronization
import SQCore
import SQMedia

/// One decodable picture the timeline shows at an instant (see `PrefetchPlanner.sources`).
public struct PlanSource: Sendable, Hashable {
    public var media: UUID
    public var sourceTime: Time
    public init(media: UUID, sourceTime: Time) { self.media = media; self.sourceTime = sourceTime }
}

/// Keeps the planner's per-frame `sources` of the last window (PLAYBACK-PERF "Prefetch window memo"). Evaluating every
/// layer of every window frame (`Timeline.videoLayers`: transforms, effects, color, nests) was ~85 % of the render
/// thread's CPU per tick on a 210-clip project; while playing the window moves one frame per tick, so only its new
/// edge is evaluated. `epoch` names the timeline + nested sequences the entries belong to (a new one drops them all).
/// Thread-safe; two planners running at once (render thread, resolve queue) only lose a memo, never mix epochs.
final class PlanSourceMemo: Sendable {
    private let state = Mutex<(epoch: UInt64, revision: UInt64, map: [Time: [PlanSource]])>((0, 0, [:]))

    /// Runs `body` with a memoized `evaluate`; afterwards only the instants `body` asked for are kept (the window).
    /// `revision`: anything else `evaluate` depends on (which sources are known to be opaque: hidden layers).
    func withSources<R>(epoch: UInt64, revision: UInt64 = 0, evaluate: @escaping (Time) -> [PlanSource],
                        _ body: ((Time) -> [PlanSource]) throws -> R) rethrows -> R {
        var old = state.withLock { s -> [Time: [PlanSource]] in
            guard s.epoch == epoch, s.revision == revision else { return [:] }
            defer { s.map = [:] }      // handed over: no second copy while planning
            return s.map
        }
        var used: [Time: [PlanSource]] = [:]
        used.reserveCapacity(old.count + 1)
        let r = try body { t in
            if let v = used[t] { return v }
            let v = old.removeValue(forKey: t) ?? evaluate(t)
            used[t] = v
            return v
        }
        state.withLock { $0 = (epoch, revision, used) }
        return r
    }
}

/// Pure: decides which GOPs to decode next. Tested with synthetic `SampleIndex` + `Timeline`.
///
/// Window (timeline time): forward = `[p - behind, p + lookahead * |rate|]`, reverse mirrored, paused =
/// `[p - pausedRadius, p + pausedRadius]`. Every sequence frame in the window is mapped through
/// `Timeline.videoLayers` -> source time -> frame index -> whole GOP. GOPs whose frames still to be shown are cached are skipped. Priority is the
/// time distance from the playhead (0 = most urgent, rank in the returned order), so a reverse play naturally
/// decodes back to front with the GOP under the playhead first, and stacked clips interleave by time.
public struct PrefetchPlanner: Sendable {
    public struct Job: Sendable, Hashable {
        public var media: UUID
        public var frames: ClosedRange<Int>
        /// Rank in the planned order, 0 first.
        public var priority: Int
        /// Keyframe-only scrub job: once running it is not canceled by a newer queue (one cheap frame that a drag will
        /// likely pass again; canceling it would leave a fast drag with no picture at all), and its frame is stored.
        public var finishesWhenDropped: Bool
        /// First frame of `frames` the window needs (nil = all): the decoder may skip unreferenced pictures before it
        /// (a seek into the middle of a long GOP). Not part of the job's identity.
        public var neededFrom: Int?
        public init(media: UUID, frames: ClosedRange<Int>, priority: Int, finishesWhenDropped: Bool = false) {
            self.media = media; self.frames = frames; self.priority = priority; self.finishesWhenDropped = finishesWhenDropped
        }
        /// Identity of the work, ignoring the priority.
        var key: JobKey { JobKey(media: media, frames: frames) }

        /// `neededFrom` is a hint, not part of equality: while playing it moves with the playhead every tick, and an
        /// unchanged queue must not be re-posted for that (see `RenderLoop.needsPost`).
        public static func == (a: Job, b: Job) -> Bool {
            a.media == b.media && a.frames == b.frames && a.priority == b.priority && a.finishesWhenDropped == b.finishesWhenDropped
        }
        public func hash(into h: inout Hasher) {
            h.combine(media); h.combine(frames); h.combine(priority); h.combine(finishesWhenDropped)
        }
    }

    struct JobKey: Hashable, Sendable { var media: UUID; var frames: ClosedRange<Int> }

    /// Ahead in play direction, multiplied by |rate|.
    public var lookahead: Time
    /// Opposite to the play direction.
    public var behind: Time
    /// Half width of the window while paused.
    public var pausedRadius: Time

    public init(lookahead: Time = Time(2, 1), behind: Time = Time(1, 2), pausedRadius: Time = Time(1, 4)) {
        self.lookahead = lookahead; self.behind = behind; self.pausedRadius = pausedRadius
    }

    /// `sequences` resolves nested clips (the project's other sequences): their inner clips are planned like top-level ones.
    /// `maxFrames`: how many decoded frames the cache holds. The window is cut where the frames it shows from its GOPs
    /// (cached ones included, in priority order) would exceed it, so prefetch never evicts frames it planned itself (decode thrash with large
    /// frames). GOPs under the playhead (distance 0) are always planned. `running`: GOPs the scheduler is decoding now.
    public func jobs(timeline: Timeline, sequences: [Timeline.ID: Timeline] = [:], playhead: Time, rate: PlaybackRate,
                     indexes: [UUID: SampleIndex], cached: (UUID, Int) -> Bool, maxFrames: Int? = nil,
                     running: (UUID, ClosedRange<Int>) -> Bool = { _, _ in false }) -> [Job] {
        jobs(timeline: timeline, playhead: playhead, rate: rate, indexes: indexes, cached: cached, maxFrames: maxFrames,
             running: running, sources: { Self.sources(timeline, sequences: sequences, at: $0) })
    }

    /// The decodable pictures (media + source time) the timeline shows at `t`, bottom to top: what the planner needs of
    /// `Timeline.videoLayers` (generators carry no media).
    public static func sources(_ timeline: Timeline, sequences: [Timeline.ID: Timeline], at t: Time) -> [PlanSource] {
        sources(timeline.videoLayers(at: t, sequences: { sequences[$0] }))
    }

    /// The pictures of these layers (the render loop passes the layers that can show: hidden ones are not decoded).
    public static func sources(_ layers: [LayerRequest]) -> [PlanSource] {
        layers.compactMap { $0.generator == nil ? PlanSource(media: $0.media, sourceTime: $0.sourceTime) : nil }
    }

    /// `sources(t)`: the pictures at timeline time `t` (`PrefetchPlanner.sources`, or a `PlanSourceMemo` of it).
    public func jobs(timeline: Timeline, playhead: Time, rate: PlaybackRate,
                     indexes: [UUID: SampleIndex], cached: (UUID, Int) -> Bool, maxFrames: Int? = nil,
                     running: (UUID, ClosedRange<Int>) -> Bool = { _, _ in false },
                     sources: (Time) -> [PlanSource]) -> [Job] {
        let fd = timeline.format.frameDuration
        guard fd > .zero else { return [] }
        let (before, after): (Time, Time)
        if rate.isPaused { (before, after) = (pausedRadius, pausedRadius) }
        else {
            let ahead = Time(lookahead.value * Int64(abs(rate.num)), lookahead.timescale * Int64(rate.den))
            (before, after) = rate.isReverse ? (ahead, behind) : (behind, ahead)
        }
        let back = Int(max(0, before.frameIndex(frameDuration: fd)))
        let fwd = Int(max(0, after.frameIndex(frameDuration: fd)))
        let end = timeline.duration

        var best: [JobKey: (distance: Time, order: Int)] = [:]
        // Frames the window shows per GOP, still to come (`ahead`, at the playhead included) and already passed. A GOP is
        // cached when the frames still to come are (or, for a GOP only behind, the passed ones): frames already shown or
        // outside the clip are evicted first, and must not make the GOP under the playhead decode again (thrash).
        var ahead: [JobKey: Set<Int>] = [:], passed: [JobKey: Set<Int>] = [:]
        let sign = rate.isPaused ? 0 : (rate.isReverse ? -1 : 1)
        var order = 0
        func visit(_ k: Int) {
            let t = playhead + fd * Int64(k)
            guard t >= .zero, t < end else { return }
            let distance = k < 0 ? -(fd * Int64(k)) : fd * Int64(k)
            for layer in sources(t) {
                defer { order += 1 }
                guard let index = indexes[layer.media], let f = index.frame(at: layer.sourceTime) else { continue }
                let key = JobKey(media: layer.media, frames: index.gop(containing: f))
                if k * sign >= 0 { ahead[key, default: []].insert(f) } else { passed[key, default: []].insert(f) }
                if let b = best[key], b.distance <= distance { continue }
                best[key] = (distance, order)
            }
        }
        visit(0)
        let limit = max(back, fwd)
        if limit > 0 {
            for k in 1...limit {
                if k <= fwd { visit(k) }
                if k <= back { visit(-k) }
            }
        }

        let ordered = best.sorted {
            $0.value.distance != $1.value.distance ? $0.value.distance < $1.value.distance : $0.value.order < $1.value.order
        }
        var out: [Job] = []
        var frames = 0
        for (key, value) in ordered {
            // A GOP occupies the cache with the frames the window shows from it: its other frames (already passed, outside
            // the clip, beyond the window) are farther from the playhead than anything planned and go first. Counting whole
            // GOPs kept the next long GOP (150 frames) out until its first frame was due.
            frames += ahead[key, default: []].union(passed[key, default: []]).count
            if let maxFrames, frames > maxFrames, value.distance > .zero { break }
            let shown = ahead[key].flatMap { $0.isEmpty ? nil : $0 } ?? passed[key] ?? []
            // A GOP being decoded stays listed (dropping it would cancel it once its first frames are in, and the next
            // tick would start it again from the sync frame).
            guard !shown.allSatisfy({ cached(key.media, $0) }) || running(key.media, key.frames) else { continue }
            var job = Job(media: key.media, frames: key.frames, priority: out.count)
            job.neededFrom = shown.min()
            out.append(job)
        }
        return out
    }

    // MARK: Keyframe-only scrub (W6.6)

    /// The frame a scrub shows for source frame `f`: the latest sync frame presented at or before it (decodable alone, and
    /// never later than the target, so the cache's nearest-earlier lookup finds it). A leading picture of an open GOP,
    /// presented before its own sync sample, gets the previous GOP's sync frame.
    /// A sync sample an edit list hides (zero duration) is never shown: the first shown frame after it (at most `f`) is.
    public static func scrubFrame(for f: Int, in index: SampleIndex) -> Int {
        scrubRange(for: f, in: index).upperBound
    }

    /// The frames a scrub decodes for source frame `f`: its sync frame alone, or, when that sync is hidden by an edit list,
    /// from the sync to the first shown frame after it.
    public static func scrubRange(for f: Int, in index: SampleIndex) -> ClosedRange<Int> {
        guard f >= 0, f < index.count else { let c = max(0, min(f, index.count - 1)); return c...c }
        let k = index.entries[f].isSync ? f : index.previousSync(before: f)
        guard index.entries[k].duration == .zero, k < f else { return k...k }
        let shown = (k + 1...f).first { index.entries[$0].duration > .zero } ?? f
        return k...shown
    }

    /// While a scrub gesture runs: per picture layer at `playhead`, one single-frame job for its `scrubFrame`, unless that
    /// frame or the exact frame is cached already. No window around the playhead: a drag only ever needs where it is now.
    /// Jobs are ordered by layer (bottom first) and marked `finishesWhenDropped`.
    /// `velocity`: the drag's last move in sequence frames (signed, 0 = unknown). The keyframes of the first position
    /// ahead (at most `scrubLookMoves` moves of that size) whose keyframe differs from the current one are queued behind
    /// the current ones, so the next GOP's picture is decoded before the playhead gets there.
    /// `layers`: the layers drawn at a time (nil = every layer of the timeline there).
    public func scrubJobs(timeline: Timeline, sequences: [Timeline.ID: Timeline] = [:], playhead: Time,
                          indexes: [UUID: SampleIndex], velocity: Int = 0, layers: ((Time) -> [LayerRequest])? = nil,
                          cached: (UUID, Int) -> Bool) -> [Job] {
        guard playhead >= .zero, playhead < timeline.duration else { return [] }
        let layers = layers ?? { timeline.videoLayers(at: $0, sequences: { sequences[$0] }) }
        var out: [Job] = []
        var here = Set<JobKey>()
        for layer in layers(playhead) where layer.generator == nil {
            guard let index = indexes[layer.media], index.count > 0 else { continue }
            let f = index.clampedFrame(at: layer.sourceTime)
            let r = Self.scrubRange(for: f, in: index)
            here.insert(JobKey(media: layer.media, frames: r))
            if cached(layer.media, f) || cached(layer.media, r.upperBound) { continue }
            if out.contains(where: { $0.media == layer.media && $0.frames == r }) { continue }
            out.append(Job(media: layer.media, frames: r, priority: out.count, finishesWhenDropped: true))
        }
        let fd = timeline.format.frameDuration
        guard velocity != 0, fd > .zero else { return out }
        for k in 1...Self.scrubLookMoves {
            let t = playhead + fd * Int64(velocity * k)
            guard t >= .zero, t < timeline.duration else { break }
            var found = false
            for layer in layers(t) where layer.generator == nil {
                guard let index = indexes[layer.media], index.count > 0 else { continue }
                let f = index.clampedFrame(at: layer.sourceTime)
                let r = Self.scrubRange(for: f, in: index)
                guard !here.contains(JobKey(media: layer.media, frames: r)) else { continue }
                found = true
                if cached(layer.media, f) || cached(layer.media, r.upperBound) { continue }
                if out.contains(where: { $0.media == layer.media && $0.frames == r }) { continue }
                out.append(Job(media: layer.media, frames: r, priority: out.count, finishesWhenDropped: true))
            }
            if found { break }
        }
        return out
    }

    /// How many moves of the drag's velocity `scrubJobs` looks ahead for the next keyframe.
    public static let scrubLookMoves = 8
}
