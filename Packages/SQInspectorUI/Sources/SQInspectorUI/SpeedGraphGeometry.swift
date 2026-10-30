import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import SQCore
import SQUIKit

/// What a press in the inline speed graph grabs (row = index into the drawn rows).
public enum SpeedGraphHit: Sendable, Equatable {
    case handle(row: Int, segment: Int, side: EaseSide)
    case key(row: Int, id: UUID)
    case curve(row: Int, segment: Int)
    case empty
}

/// Pure geometry of the inline speed graph (build.py `egraph`): time across (the same x mapping as the keyframe lanes),
/// speed up. Speed 0 is the baseline 22 pt above the bottom edge, 1.0x (Steady) sits 40 pt above it. A key sits at its
/// own speed; its handle is horizontal and as long as its Reach (a share of the segment).
public struct SpeedGraphGeometry: Sendable, Equatable {
    public var lane: KeyframeLaneGeometry
    public var height: CGFloat
    /// Highest speed that has to fit (the unit height shrinks for a hill taller than the plot).
    public var peak: Double
    /// Lowest speed that has to fit, 0 or negative (a key speed below 0: wind-up, overshoot). The baseline moves up to
    /// make room for it. 0 in the keyframe rows; the curve editor (`EaseSpeedEditorView`) sets it.
    public var low: Double = 0

    public static let baselineInset: CGFloat = 22
    public static let unit: CGFloat = 40
    public static let topInset: CGFloat = 10

    /// Height of the opened row (`ControlsMetrics.graph`).
    public static let defaultHeight: CGFloat = 120

    public init(lane: KeyframeLaneGeometry, height: CGFloat = SpeedGraphGeometry.defaultHeight, peak: Double = 1) {
        self.lane = lane; self.height = height; self.peak = peak
    }

    /// Speeds below 0 the plot makes room for (0...`peakCap`).
    private var depth: CGFloat { CGFloat(min(max(-low, 0), Self.peakCap)) }
    /// y of speed 0.
    public var baseline: CGFloat { height - Self.baselineInset - depth * unitHeight }
    /// The plot scales down to fit a hill of at most this many times the steady speed. A taller one (two long handles
    /// make a sharp peak, a cusp when both are at 100 %) runs off the top and is clipped there, as in Premiere, so the
    /// Steady line and the rest of the hill stay readable instead of being squashed flat.
    public static let peakCap: Double = 4
    /// Points per 1.0x of speed.
    public var unitHeight: CGFloat {
        min(Self.unit, (height - Self.baselineInset - Self.topInset) / (CGFloat(min(max(peak, 1), Self.peakCap)) + depth))
    }

    /// The speed a point at `y` stands for (not clamped: a drag may leave the row).
    public func speed(atY y: CGFloat) -> Double { unitHeight > 0 ? Double((baseline - y) / unitHeight) : 0 }

    /// y of a key or handle at `speed`: kept inside the row, so it can always be seen and grabbed.
    public func y(speed: Double) -> CGFloat {
        min(max(baseline - CGFloat(speed) * unitHeight, 2), height - 2)
    }

    /// y of a curve point at `speed`: not kept inside the row (the view clips), so a peak taller than the plot keeps
    /// its true flanks instead of a flat top.
    public func curveY(speed: Double) -> CGFloat {
        let y = baseline - CGFloat(speed.isFinite ? speed : 0) * unitHeight
        return min(max(y, -4 * height), 4 * height)
    }

    public func x(_ seg: EaseTrackSegment, share: Double) -> CGFloat {
        let a = lane.x(for: seg.start), b = lane.x(for: seg.end)
        return a + CGFloat(share) * (b - a)
    }

    public func width(_ seg: EaseTrackSegment) -> CGFloat { lane.x(for: seg.end) - lane.x(for: seg.start) }

    /// The hill of one segment. 97 samples spread along the bezier parameter, which packs them where time stands
    /// nearly still, i.e. exactly around a sharp peak.
    public func points(_ seg: EaseTrackSegment, count: Int = 97) -> [CGPoint] {
        var s = SpeedHill.samples(seg.shape, count: count)
        // Both handles at 100 % make a cusp: time stands still for an instant, the speed there has no finite value and
        // the sample reads 0. Drawn as it is, the tip of the peak would dive to the baseline: keep it on its flanks.
        if s.count > 2 {
            for i in 1..<(s.count - 1) where s[i].speed == 0 && s[i - 1].speed > Self.peakCap && s[i + 1].speed > Self.peakCap {
                s[i].speed = max(s[i - 1].speed, s[i + 1].speed)
            }
        }
        return s.map { CGPoint(x: x(seg, share: $0.x), y: curveY(speed: $0.speed * seg.scale)) }
    }

    /// Where the key on `side` (`.out` = left key, `.in` = right key) sits.
    public func key(_ seg: EaseTrackSegment, side: EaseSide) -> CGPoint {
        side == .in ? CGPoint(x: x(seg, share: 1), y: y(speed: seg.shape.speedIn * seg.scale))
                    : CGPoint(x: x(seg, share: 0), y: y(speed: seg.shape.speedOut * seg.scale))
    }

    /// A handle is drawn at least this far from its key (shrinking with very narrow segments), so it can be seen and
    /// grabbed even at a tiny influence. Drags keep the grab offset, so the drawn minimum never makes a handle jump.
    public static let minHandleLength: CGFloat = 12
    static let keyHitRadius: CGFloat = 6
    static let handleHitRadius: CGFloat = 7
    static let curveHitDistance: CGFloat = 4

    /// Points between a key and its handle at 100 % influence: half of the segment (`HandleReach.fullInfluence`).
    public func handleSpan(_ seg: EaseTrackSegment) -> CGFloat { width(seg) * CGFloat(HandleReach.fullInfluence) }

    /// Where the handle on `side` really is: level with its key, influence x `handleSpan` away from it.
    public func handleTrueEnd(_ seg: EaseTrackSegment, side: EaseSide) -> CGPoint {
        let k = key(seg, side: side), span = handleSpan(seg)
        return side == .in ? CGPoint(x: k.x - CGFloat(seg.shape.reachIn) * span, y: k.y)
                           : CGPoint(x: k.x + CGFloat(seg.shape.reachOut) * span, y: k.y)
    }

    /// Where the handle is drawn and hit: the true end, pushed out to at least `minHandleLength` (at most 40 % of the
    /// full-influence span, so a narrow segment's two handles still never meet).
    public func handleEnd(_ seg: EaseTrackSegment, side: EaseSide) -> CGPoint {
        let k = key(seg, side: side), e = handleTrueEnd(seg, side: side)
        let dir: CGFloat = side == .in ? -1 : 1
        let minLen = min(Self.minHandleLength, handleSpan(seg) * 0.4 + 2)
        return (e.x - k.x) * dir >= minLen ? e : CGPoint(x: k.x + dir * minLen, y: k.y)
    }

    /// Influence (0...1) for a handle end at `x`: 0 at the key, exactly 1 at `handleSpan`, clamped beyond.
    /// Only x counts: moving the pointer up or down changes nothing.
    public func reach(atX x: CGFloat, _ seg: EaseTrackSegment, side: EaseSide) -> Double {
        let span = handleSpan(seg)
        guard span > 0 else { return 0 }
        let k = key(seg, side: side)
        let r = Double((side == .in ? k.x - x : x - k.x) / span)
        guard r.isFinite else { return 0 }
        // The stop itself is exactly 100 % (no 99.99999 % from point rounding).
        return r >= 1 - 1e-9 ? 1 : max(r, 0)
    }

    // MARK: Hit testing (pure)

    /// Keys of one drawn row in time order with the point their diamond sits at (outgoing speed; the last key its
    /// arriving speed).
    public func keyPoints(_ segments: [EaseTrackSegment]) -> [(id: UUID, point: CGPoint)] {
        guard let last = segments.last else { return [] }
        return segments.map { ($0.from, key($0, side: .out)) } + [(last.to, key(last, side: .in))]
    }

    /// The handles drawn for a row: the side of a segment whose key is selected (Premiere shows handles on selected
    /// keys only), never on Hold.
    public func visibleHandles(_ segments: [EaseTrackSegment], selected: Set<UUID>) -> [(segment: Int, side: EaseSide)] {
        segments.enumerated().flatMap { i, s -> [(segment: Int, side: EaseSide)] in
            guard !s.shape.interpolation.isHold else { return [] }
            var out: [(segment: Int, side: EaseSide)] = []
            if selected.contains(s.from) { out.append((i, .out)) }
            if selected.contains(s.to) { out.append((i, .in)) }
            return out
        }
    }

    /// What a press at `p` grabs. Priority: handle > key > curve > empty (empty starts a marquee).
    /// `rows` are the drawn rows' segments, `selected` their selected key ids (same order).
    public func hitTest(_ p: CGPoint, rows: [[EaseTrackSegment]], selected: [Set<UUID>]) -> SpeedGraphHit {
        var best: (SpeedGraphHit, CGFloat)?
        for (r, segs) in rows.enumerated() {
            for h in visibleHandles(segs, selected: r < selected.count ? selected[r] : []) {
                let e = handleEnd(segs[h.segment], side: h.side)
                let d = hypot(e.x - p.x, e.y - p.y)
                if d <= Self.handleHitRadius, d < (best?.1 ?? .infinity) { best = (.handle(row: r, segment: h.segment, side: h.side), d) }
            }
        }
        if let b = best { return b.0 }
        for (r, segs) in rows.enumerated() {
            for k in keyPoints(segs) {
                let d = hypot(k.point.x - p.x, k.point.y - p.y)
                if d <= Self.keyHitRadius, d < (best?.1 ?? .infinity) { best = (.key(row: r, id: k.id), d) }
            }
        }
        if let b = best { return b.0 }
        for (r, segs) in rows.enumerated() {
            for (i, s) in segs.enumerated() {
                let pts = points(s)
                for (a, b) in zip(pts, pts.dropFirst()) where KeyframeGraphGeometry.distance(p, toSegment: a, b) <= Self.curveHitDistance {
                    return .curve(row: r, segment: i)
                }
            }
        }
        return .empty
    }

    /// Marquee: per row, the keys whose diamond or visible handle end lies inside `rect`. Rows without a hit are left out.
    public func keys(in rect: CGRect, rows: [[EaseTrackSegment]], selected: [Set<UUID>]) -> [Int: Set<UUID>] {
        var out: [Int: Set<UUID>] = [:]
        for (r, segs) in rows.enumerated() {
            var ids = Set(keyPoints(segs).filter { rect.contains($0.point) }.map(\.id))
            for h in visibleHandles(segs, selected: r < selected.count ? selected[r] : []) {
                let s = segs[h.segment]
                if rect.contains(handleEnd(s, side: h.side)) { ids.insert(h.side == .out ? s.from : s.to) }
            }
            if !ids.isEmpty { out[r] = ids }
        }
        return out
    }

    /// Highest speed of the given segments (at least 1, so the Steady line always fits).
    public static func peak(of segments: [EaseTrackSegment]) -> Double {
        segments.reduce(1) { max($0, SpeedHill.peak($1.shape) * $1.scale, $1.shape.speedOut * $1.scale, $1.shape.speedIn * $1.scale) }
    }

    /// Lowest speed of `segments`, at most 0 (for `low`).
    public static func low(of segments: [EaseTrackSegment]) -> Double {
        segments.reduce(0) { r, s in
            let dip = SpeedHill.samples(s.shape, count: 97).map(\.speed).filter(\.isFinite).min() ?? 0
            return min(r, dip * s.scale, s.shape.speedOut * s.scale, s.shape.speedIn * s.scale)
        }
    }
}

/// Line weights of the speed graph (thin curve, hairline stems, small knobs): the Mac painter and the draw pane.
enum SpeedGraphLook {
    static let curveWidth: CGFloat = 1.5
    static let stemWidth: CGFloat = 1
    static let knobDiameter: CGFloat = 7
    /// Ring of a handle knob (v9 `.hh`: well fill, 1.5 pt inner ring).
    static let knobRing: CGFloat = 1.5
    /// Share of the curve's own color under it (v9 `path.fl`: 12 %).
    static let fillAlpha: CGFloat = 0.12
    static let keySide: CGFloat = 7
}
