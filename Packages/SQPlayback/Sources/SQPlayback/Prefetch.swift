import Foundation
import SQCore
import SQMedia

/// Pure: decides which GOPs to decode next. Tested with synthetic `SampleIndex` + `Timeline`.
///
/// Window (timeline time): forward = `[p - behind, p + lookahead * |rate|]`, reverse mirrored, paused =
/// `[p - pausedRadius, p + pausedRadius]`. Every sequence frame in the window is mapped through
/// `Timeline.videoLayers` -> source time -> frame index -> whole GOP. GOPs fully cached are skipped. Priority is the
/// time distance from the playhead (0 = most urgent, rank in the returned order), so a reverse play naturally
/// decodes back to front with the GOP under the playhead first, and stacked clips interleave by time.
public struct PrefetchPlanner: Sendable {
    public struct Job: Sendable, Hashable {
        public var media: UUID
        public var frames: ClosedRange<Int>
        /// Rank in the planned order, 0 first.
        public var priority: Int
        public init(media: UUID, frames: ClosedRange<Int>, priority: Int) {
            self.media = media; self.frames = frames; self.priority = priority
        }
        /// Identity of the work, ignoring the priority.
        var key: JobKey { JobKey(media: media, frames: frames) }
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
    public func jobs(timeline: Timeline, sequences: [Timeline.ID: Timeline] = [:], playhead: Time, rate: PlaybackRate,
                     indexes: [UUID: SampleIndex], cached: (UUID, Int) -> Bool) -> [Job] {
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
        var order = 0
        func visit(_ k: Int) {
            let t = playhead + fd * Int64(k)
            guard t >= .zero, t < end else { return }
            let distance = k < 0 ? -(fd * Int64(k)) : fd * Int64(k)
            for layer in timeline.videoLayers(at: t, sequences: { sequences[$0] }) where layer.generator == nil {
                defer { order += 1 }
                guard let index = indexes[layer.media], let f = index.frame(at: layer.sourceTime) else { continue }
                let key = JobKey(media: layer.media, frames: index.gop(containing: f))
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
        for (key, _) in ordered where !key.frames.allSatisfy({ cached(key.media, $0) }) {
            out.append(Job(media: key.media, frames: key.frames, priority: out.count))
        }
        return out
    }
}
