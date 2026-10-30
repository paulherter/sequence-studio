import Foundation

/// One-click speed ramps (own names). Each preset is an ordinary speed track (`SpeedKeys`) made of holds and ease-in/out
/// S-curve ramps with a peak of 250-300 %; after applying it the user edits it like any other time remap (keys, curves).
///
/// The preset keeps the clip's whole source range: the speeds are fixed by the shape, so the clip's timeline length
/// follows (a ramp with a fast peak plays the same footage in less time). "Hit on beat" moves the peak onto a timeline
/// time (a beat marker) by stretching the part before the peak against the part after it.
public enum SpeedRampPreset: String, CaseIterable, Sendable, Codable {
    /// Slow start, builds to a fast finish.
    case surge
    /// Fast start, settles into slow motion.
    case rush
    /// Normal, a sharp burst, then a slow-motion beat.
    case punch
    /// Normal, one quick swell, back to normal.
    case pulse
    /// Long even swell: normal, fast plateau, normal.
    case crest

    public var title: String {
        switch self {
        case .surge: "Surge"
        case .rush: "Rush"
        case .punch: "Punch"
        case .pulse: "Pulse"
        case .crest: "Crest"
        }
    }

    public var detail: String {
        switch self {
        case .surge: "Slow in, fast out"
        case .rush: "Fast in, slow out"
        case .punch: "Sharp burst, then slow motion"
        case .pulse: "Quick swell and back"
        case .crest: "Smooth rise, fast plateau, smooth fall"
        }
    }

    /// Weight (relative timeline length), start speed, end speed (ratios). `peak` marks the constant segment at the top.
    struct Piece { var weight: Double; var from: Double; var to: Double }

    var pieces: [Piece] {
        switch self {
        case .surge: [Piece(weight: 0.30, from: 0.4, to: 0.4), Piece(weight: 0.30, from: 0.4, to: 2.8), Piece(weight: 0.30, from: 2.8, to: 2.8), Piece(weight: 0.10, from: 2.8, to: 1)]
        case .rush: [Piece(weight: 0.10, from: 1, to: 2.8), Piece(weight: 0.25, from: 2.8, to: 2.8), Piece(weight: 0.30, from: 2.8, to: 0.4), Piece(weight: 0.35, from: 0.4, to: 0.4)]
        case .punch: [Piece(weight: 0.20, from: 1, to: 1), Piece(weight: 0.12, from: 1, to: 2.8), Piece(weight: 0.08, from: 2.8, to: 2.8),
                      Piece(weight: 0.12, from: 2.8, to: 0.3), Piece(weight: 0.28, from: 0.3, to: 0.3), Piece(weight: 0.20, from: 0.3, to: 1)]
        case .pulse: [Piece(weight: 0.25, from: 1, to: 1), Piece(weight: 0.20, from: 1, to: 2.5), Piece(weight: 0.10, from: 2.5, to: 2.5),
                      Piece(weight: 0.20, from: 2.5, to: 1), Piece(weight: 0.25, from: 1, to: 1)]
        case .crest: [Piece(weight: 0.15, from: 1, to: 1), Piece(weight: 0.25, from: 1, to: 2.75), Piece(weight: 0.20, from: 2.75, to: 2.75),
                      Piece(weight: 0.25, from: 2.75, to: 1), Piece(weight: 0.15, from: 1, to: 1)]
        }
    }

    /// Index of the constant segment at the peak speed.
    var peakIndex: Int {
        let p = pieces
        return p.indices.filter { p[$0].from == p[$0].to }.max { p[$0].from < p[$1].from }!
    }

    /// Ease-in/out S-curve for the ramps.
    static let sCurve = EaseShape(interpolation: .bezier, out: EaseHandle(dx: 0.42, dy: 0), in: EaseHandle(dx: 0.42, dy: 0))

    /// The preset's own peak position as a fraction of its length.
    var defaultPeak: Double {
        let p = pieces, i = peakIndex
        return p[..<i].reduce(0) { $0 + $1.weight } + p[i].weight / 2
    }

    /// The speed track for a clip whose current track is `base`, over the same source range and direction.
    /// `peakAt` (clip-local) puts the peak at that time, clamped to the middle 84 % of the new clip; nil keeps the preset's own.
    public func keys(for base: SpeedKeys, frameDuration fd: Time, peakAt: Time?) -> SpeedKeys {
        let reversed = base.segments[0].reversed
        let hull = base.hull
        let origin = reversed ? hull.end : hull.start
        let fdSec = Rational(fd).double
        let srcFrames = Rational(hull.duration).double / fdSec
        // The plateau keeps its share of the clip; the pieces before and after it share the rest around the peak center `r`.
        let all = pieces, pi = peakIndex
        let pre = Array(all[..<pi]), plateau = all[pi], post = Array(all[(pi + 1)...])
        let q = plateau.weight
        func avg(_ ps: [Piece]) -> Double { ps.reduce(0) { $0 + $1.weight * ($1.from + $1.to) / 2 } }
        let preW = pre.reduce(0) { $0 + $1.weight }, postW = post.reduce(0) { $0 + $1.weight }
        // Timeline frames T for peak center r: source = T * (preShare * avgPre/preW + postShare * avgPost/postW + q * peak).
        func frames(_ r: Double) -> Double {
            srcFrames / ((r - q / 2) * (avg(pre) / preW) + (1 - r - q / 2) * (avg(post) / postW) + q * plateau.from)
        }
        var r = defaultPeak
        if let b = peakAt {
            let want = Rational(b).double / fdSec
            // r * frames(r) rises with r (a Moebius map), so bisection finds the r that lands the peak on `want`.
            var lo = q / 2 + 0.06, hi = 1 - q / 2 - 0.06
            for _ in 0..<50 { let mid = (lo + hi) / 2; if mid * frames(mid) < want { lo = mid } else { hi = mid } }
            r = (lo + hi) / 2
        }
        let total = max(frames(r), 8)
        // Boundaries in whole frames (cumulative rounding), at least one frame per segment.
        var edges: [Double] = [0]
        var acc = 0.0
        for pc in pre { acc += pc.weight / preW * (r - q / 2); edges.append(acc) }
        acc += q; edges.append(acc)
        for pc in post { acc += pc.weight / postW * (1 - r - q / 2); edges.append(acc) }
        var bounds: [Int64] = [0]
        for (i, e) in edges.enumerated().dropFirst() {
            bounds.append(max(Int64((e * total).rounded()), bounds[i - 1] + 1))
        }
        let merged = pre + [plateau] + post
        var segs: [SpeedSegment] = []
        for (i, pc) in merged.enumerated() {
            let ramp = pc.from != pc.to
            segs.append(SpeedSegment(duration: fd * (bounds[i + 1] - bounds[i]), from: ClipSpeed(percent: pc.from * 100),
                                     to: ClipSpeed(percent: pc.to * 100), reversed: reversed, ease: ramp ? Self.sCurve : nil))
        }
        // The two halves of the peak plateau are one constant stretch.
        var out: [SpeedSegment] = []
        for s in segs {
            if var last = out.last, last.joins(s) { last.duration = last.duration + s.duration; out[out.count - 1] = last } else { out.append(s) }
        }
        return SpeedKeys(segments: out, origin: origin)
    }
}

extension SpeedKeys {
    /// Clip-local time of the fastest point: the middle of the fastest constant stretch, else the fastest key.
    public var peakTime: Time {
        // A plateau beats the ramp that ends on it (a hair more, so the tie breaks to the plateau).
        func top(_ s: SpeedSegment) -> Double { max(s.from.percent, s.to.percent) + (s.isRamp ? 0 : 0.001) }
        let b = boundaries
        guard let i = segments.indices.max(by: { top(segments[$0]) < top(segments[$1]) }) else { return .zero }
        let s = segments[i]
        if !s.isRamp { return b[i] + Time(reducing: Int128(s.duration.value), Int128(s.duration.timescale) * 2) }
        return s.to.percent >= s.from.percent ? b[i + 1] : b[i]
    }
}
