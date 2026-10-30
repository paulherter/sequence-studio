import Foundation
import SQCore

/// The audio side of the one time mapping (`Clip.sourceTime` / `SpeedKeys.position`): top-sequence time -> media time through
/// a chain of clips (outermost nested clip first, the media clip last), in Double seconds. Audio only needs positions to a
/// fraction of a sample, so nothing is accumulated: every evaluation is closed form (constant: `source +/- speed * local`;
/// ramp: `a t + (b - a) t^2 / 2T`, the same formula as `SpeedSegment.span`). Direction is the product of the chain's signs.
/// `AudioFeeder` uses this for every clip with a speed track and for every clip inside a retimed nested clip; plain constant
/// clips keep their exact path in the feeder, so they are unchanged.
struct AudioTimeMap: Sendable {
    private struct Segment: Sendable {
        var start: Double       // clip-local seconds
        var duration: Double
        var from: Double, to: Double
        var sign: Double
        var pos: Double         // source seconds at the segment start
    }
    private struct Level: Sendable {
        var clipStart: Double
        var segments: [Segment]
        var total: Double
        /// Source seconds at `local` and the direction sign there.
        func eval(_ t: Double) -> (pos: Double, sign: Double) {
            let raw = t - clipStart
            // Outside the clip (a transition's handle) the track runs on at its end speed and direction.
            if raw < 0 { let s = segments[0]; return (s.pos + s.sign * s.from * raw, s.sign) }
            if raw > total, let l = segments.last {
                return (l.pos + l.sign * l.duration * (l.from + l.to) / 2 + l.sign * l.to * (raw - total), l.sign)
            }
            let local = raw
            var i = segments.count - 1
            for (j, s) in segments.enumerated() where local < s.start + s.duration { i = j; break }
            let s = segments[i]
            let tau = min(max(local - s.start, 0), s.duration)
            let d = s.to == s.from || s.duration == 0 ? s.from * tau : s.from * tau + (s.to - s.from) * tau * tau / (2 * s.duration)
            return (s.pos + s.sign * d, s.sign)
        }
    }

    private var levels: [Level]

    /// `chain`: nested clips outermost first, then the clip that plays media.
    init(chain: [Clip]) {
        levels = chain.map { Self.level($0) }
    }

    private static func sec(_ t: Time) -> Double { Double(t.value) / Double(t.timescale) }
    private static func ratio(_ s: ClipSpeed) -> Double { Double(s.num) / Double(s.den) }

    private static func level(_ c: Clip) -> Level {
        let keys = SpeedKeys.of(c)
        var segs: [Segment] = []
        var t = 0.0, pos = sec(keys.origin)
        for s in keys.segments {
            let sign = s.reversed ? -1.0 : 1.0
            let d = sec(s.duration), a = ratio(s.from), b = ratio(s.to)
            segs.append(Segment(start: t, duration: d, from: a, to: b, sign: sign, pos: pos))
            pos += sign * d * (a + b) / 2
            t += d
        }
        return Level(clipStart: sec(c.start), segments: segs, total: t)
    }

    /// Media position in frames of `rate` at top-sequence frame `frame` (absolute, may be fractional), and the playing direction.
    func position(atFrame frame: Double, rate: Double) -> (frames: Double, reversed: Bool) {
        var t = frame / rate, negative = false
        for l in levels {
            let (p, s) = l.eval(t)
            t = p
            if s < 0 { negative.toggle() }
        }
        return (t * rate, negative)
    }
}
