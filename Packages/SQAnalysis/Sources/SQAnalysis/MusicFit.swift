import Foundation
import SQCore

/// Fit a music track to a target length by cutting or looping at bar boundaries (pure logic over a `BeatGrid`).
/// Every version keeps the track's intro and outro and joins two bar boundaries, so the beat phase never shifts.
public enum MusicFit {
    public struct Segment: Sendable, Equatable {
        public var source: TimeRange
        public var outputStart: Time
        public init(source: TimeRange, outputStart: Time) { self.source = source; self.outputStart = outputStart }
    }

    public struct Version: Sendable, Equatable {
        public var segments: [Segment]
        /// Output times of the joins; a crossfade of `crossfade` is centered on each (length is unchanged).
        public var joins: [Time]
        public var crossfade: Time
        public var length: Time
        /// `length - target`, signed.
        public var lengthError: Time
        public var jumpBars: Int
        public var removesAudio: Bool
    }

    public struct Settings: Sendable, Equatable {
        public var versionCount = 3
        public var maxRepeats = 8
        public var crossfade = Time(1, 4)
        public init() {}
    }

    /// Bar boundary times of `grid` that lie inside `duration`.
    public static func barBoundaries(grid: BeatGrid, duration: Time) -> [Time] {
        grid.downbeats.filter { $0 >= .zero && $0 <= duration }
    }

    /// Up to `settings.versionCount` auditionable versions, best length match first, joins at different places.
    public static func propose(grid: BeatGrid, duration: Time, target: Time, settings: Settings = Settings()) -> [Version] {
        let bars = barBoundaries(grid: grid, duration: duration)
        guard bars.count >= 2, duration > .zero, target > .zero, duration != target else { return [] }
        let shorter = target < duration
        struct Cand { var a: Int; var b: Int; var reps: Int; var err: Double }
        var cands: [Cand] = []
        func sec(_ t: Time) -> Double { Double(t.value) / Double(t.timescale) }
        let diff = sec(duration) - sec(target)
        for i in 0..<(bars.count - 1) {
            for j in (i + 1)..<bars.count {
                let delta = sec(bars[j]) - sec(bars[i])
                if shorter {
                    // Remove bars i..<j: join at bars[i] to bars[j]. Keep at least the first bar before the cut.
                    cands.append(Cand(a: i, b: j, reps: 0, err: abs(delta - diff)))
                } else {
                    let need = -diff
                    let n = max(1, min(settings.maxRepeats, Int((need / delta).rounded())))
                    cands.append(Cand(a: i, b: j, reps: n, err: abs(Double(n) * delta - need)))
                }
            }
        }
        // Prefer small error, then fewer repeats/shorter jumps, then joins away from the very start.
        cands.sort { l, r in
            if abs(l.err - r.err) > 0.01 { return l.err < r.err }
            if l.reps != r.reps { return l.reps < r.reps }
            return (l.b - l.a) < (r.b - r.a)
        }
        var picked: [Cand] = []
        for c in cands {
            // Distinct versions: join position at least two bars from any chosen one.
            if picked.contains(where: { abs($0.a - c.a) < 2 && abs($0.b - c.b) < 2 }) { continue }
            if picked.contains(where: { $0.a == c.a || $0.b == c.b }) { continue }
            picked.append(c)
            if picked.count == settings.versionCount { break }
        }
        return picked.map { build($0.a, $0.b, $0.reps, bars: bars, duration: duration, target: target, shorter: shorter, cf: settings.crossfade) }
    }

    private static func build(_ a: Int, _ b: Int, _ reps: Int, bars: [Time], duration: Time, target: Time,
                              shorter: Bool, cf: Time) -> Version {
        var segs: [Segment] = []
        var joins: [Time] = []
        var out = Time.zero
        func add(_ from: Time, _ to: Time) {
            segs.append(Segment(source: TimeRange(start: from, end: to), outputStart: out))
            out = out + (to - from)
        }
        if shorter {
            add(.zero, bars[a]); joins.append(out)
            add(bars[b], duration)
        } else {
            add(.zero, bars[b])
            for _ in 0..<reps {
                joins.append(out)
                add(bars[a], bars[b])
            }
            joins.append(out)
            add(bars[b], duration)
        }
        return Version(segments: segs, joins: joins, crossfade: cf, length: out, lengthError: out - target,
                       jumpBars: b - a, removesAudio: shorter)
    }
}
