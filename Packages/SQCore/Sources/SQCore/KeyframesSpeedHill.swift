import Foundation

/// The speed graph of one eased segment (Controls > opened keyframe row). Everything is normalized to the segment:
/// time runs 0...1 from the left key to the right key, speed is a multiple of the segment's steady speed
/// (1.0 = a straight segment, 0 = standing still). The hill is dy/dx of the value bezier
/// (0,0) (out.dx, out.dy) (1 - in.dx, 1 - in.dy) (1,1), i.e. exactly what `KeyframeTrack.segmentValue` plays.
/// Reach is a handle's `dx` (share of the segment's time), the speed at a key is the handle's slope `dy / dx`.
public enum SpeedHill {
    public struct Sample: Sendable, Hashable {
        /// Share of the segment's time, 0...1.
        public var x: Double
        /// Multiple of the steady speed.
        public var speed: Double
        public init(x: Double, speed: Double) { self.x = x; self.speed = speed }
    }

    /// Shortest reach an edit can give a handle: 0.1 %, the lower end of Premiere's influence range (0.1...100 %,
    /// docs/research/SPEED-GRAPH-INFLUENCE.md). A reach of 0 would collapse the handle onto its key.
    public static let minReach = 0.001

    /// `count` points (min 2) from the left key to the right key, evenly spread along the bezier parameter.
    public static func samples(_ shape: EaseShape, count: Int = 49) -> [Sample] {
        let n = max(count, 2)
        let s = shape.effective
        if s.interpolation.isHold { return (0..<n).map { Sample(x: Double($0) / Double(n - 1), speed: 0) } }
        let x1 = s.out.dx, y1 = s.out.dy, x2 = 1 - s.in.dx, y2 = 1 - s.in.dy
        return (0..<n).map { i in
            let t = Double(i) / Double(n - 1), u = 1 - t
            let x = 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t
            let dx = 3 * u * u * x1 + 6 * u * t * (x2 - x1) + 3 * t * t * (1 - x2)
            let dy = 3 * u * u * y1 + 6 * u * t * (y2 - y1) + 3 * t * t * (1 - y2)
            // A handle of reach 0 has no slope of its own at the key: use the key's speed there.
            let speed = abs(dx) > 1e-9 ? dy / dx : (i == 0 ? s.speedOut : (i == n - 1 ? s.speedIn : 0))
            return Sample(x: i == 0 ? 0 : (i == n - 1 ? 1 : x), speed: speed)
        }
    }

    /// Highest speed on the segment.
    public static func peak(_ shape: EaseShape) -> Double {
        samples(shape, count: 97).map(\.speed).max() ?? 0
    }

    /// Area under the samples (trapezoids): the share of the value delta covered, 1 for any shape that is not Hold.
    public static func area(_ samples: [Sample]) -> Double {
        zip(samples, samples.dropFirst()).reduce(0) { $0 + ($1.1.x - $1.0.x) * ($1.0.speed + $1.1.speed) / 2 }
    }
}

extension EaseShape {
    private static func slope(_ h: EaseHandle) -> Double { h.dx > 1e-9 ? h.dy / h.dx : 0 }

    /// Speed leaving the left key, as a multiple of the steady speed (Smooth = 0, Steady = 1, Hold = 0).
    public var speedOut: Double { let s = effective; return s.interpolation.isHold ? 0 : Self.slope(s.out) }
    /// Speed arriving at the right key.
    public var speedIn: Double { let s = effective; return s.interpolation.isHold ? 0 : Self.slope(s.in) }
    /// Length of the left key's handle as a share of the segment (0...1).
    public var reachOut: Double { effective.out.dx }
    /// Length of the right key's handle.
    public var reachIn: Double { effective.in.dx }

    /// The shape with the handle(s) of `side` made `reach` long. The key's speed stays what it was, so only the
    /// handle's length changes. Each side is clamped to `minReach...1` on its own (Premiere: influence 0...100 % per
    /// handle, independent of the other one; a cubic with both x controls in 0...1 stays a function of time).
    /// Hold has no handles and comes back unchanged.
    public func settingReach(_ reach: Double, side: EaseSide) -> EaseShape {
        let s = effective
        guard !s.interpolation.isHold else { return self }
        var out = s.out, inH = s.in
        func make(_ r: Double, speed: Double) -> EaseHandle {
            let dx = r.isFinite ? min(max(r, SpeedHill.minReach), 1) : (r > 0 ? 1 : SpeedHill.minReach)
            return EaseHandle(dx: dx, dy: speed * dx)
        }
        switch side {
        case .out: out = make(reach, speed: s.speedOut)
        case .in: inH = make(reach, speed: s.speedIn)
        case .both:
            out = make(reach, speed: s.speedOut)
            inH = make(reach, speed: s.speedIn)
        }
        return EaseShape(interpolation: .bezier, out: out, in: inH)
    }

    /// The shape with the key speed of `side` set (multiple of the steady speed); the reach stays what it was.
    /// A negative speed makes the value run backwards at that key: at the left key a wind-up, at the right key an
    /// overshoot that settles. `valueRange` keeps the handle's value part (`dy`) inside what the edited thing can store.
    public func settingSpeed(_ speed: Double, side: EaseSide, valueRange: ClosedRange<Double>? = nil) -> EaseShape {
        let s = effective
        guard !s.interpolation.isHold else { return self }
        var out = s.out, inH = s.in
        func make(_ h: EaseHandle) -> EaseHandle {
            var dy = speed.isFinite ? speed * h.dx : 0
            if let r = valueRange { dy = min(max(dy, r.lowerBound), r.upperBound) }
            return EaseHandle(dx: h.dx, dy: dy)
        }
        if side != .in { out = make(out) }
        if side != .out { inH = make(inH) }
        return EaseShape(interpolation: .bezier, out: out, in: inH)
    }

    /// How far the value leaves the span between its two keys, as shares of the value change: `below` the start value
    /// (wind-up), `above` the end value (overshoot). Both 0 for a curve that stays between its keys.
    public var valueExcursion: (below: Double, above: Double) {
        let s = effective
        guard !s.interpolation.isHold else { return (0, 0) }
        let y1 = s.out.dy, y2 = 1 - s.in.dy
        var lo = 0.0, hi = 1.0
        for i in 1..<128 {
            let t = Double(i) / 128, u = 1 - t
            let y = 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t
            lo = min(lo, y); hi = max(hi, y)
        }
        return (max(-lo, 0), max(hi - 1, 0))
    }
}

/// One segment of a track with its times and effective shape (what the speed graph draws).
public struct EaseTrackSegment: Sendable, Hashable {
    public var from: UUID
    public var to: UUID
    public var start: Time
    public var end: Time
    public var shape: EaseShape
    /// Size of the value change between the two keys (a length for vectors); nil when unknown (the curve editor of a
    /// transition, masks paths): such a segment is drawn on its own normalized scale.
    public var change: Double?
    /// Vertical scale of this segment's curve on the row's one shared scale: its steady speed (value change per second)
    /// over the largest steady speed of the row. 0 = the value does not move (a flat line at speed zero), 1 = the
    /// fastest segment of the row. Normalized segments (no `change`) stay 1.
    public var scale: Double = 1
    public init(from: UUID, to: UUID, start: Time, end: Time, shape: EaseShape, change: Double? = nil) {
        self.from = from; self.to = to; self.start = start; self.end = end; self.shape = shape; self.change = change
    }

    /// Steady speed: value change per second (nil when the change is unknown).
    public var steadySpeed: Double? {
        let span = end - start
        let d = Double(span.value) / Double(max(1, span.timescale))
        guard let change, d > 0 else { return nil }
        return abs(change) / d
    }

    /// Sets `scale` on every segment of one row so they share one vertical scale (speed = value change per second).
    public static func applyingSharedScale(_ segs: [EaseTrackSegment]) -> [EaseTrackSegment] {
        let top = segs.compactMap(\.steadySpeed).max() ?? 0
        return segs.map { s in
            var s = s
            if let v = s.steadySpeed { s.scale = top > 0 ? v / top : 0 }
            return s
        }
    }
}

extension PropertyTrack {
    /// Every segment of the track in time order.
    public var easeSegments: [EaseTrackSegment] {
        let t = times
        let raw: [EaseTrackSegment] = zip(t, t.dropFirst()).compactMap { a, b in
            guard let s = easeShape(from: a.id, to: b.id) else { return nil }
            return EaseTrackSegment(from: a.id, to: b.id, start: a.time, end: b.time, shape: s.effective,
                                    change: valueChange(from: a.id, to: b.id))
        }
        return EaseTrackSegment.applyingSharedScale(raw)
    }

    /// Size of the value change between two keys; nil for path tracks (no single number).
    func valueChange(from a: UUID, to b: UUID) -> Double? {
        switch self {
        case .scalar(let t): t.valueChange(from: a, to: b)
        case .vector(let t): t.valueChange(from: a, to: b)
        case .color(let t): t.valueChange(from: a, to: b)
        case .path: nil
        }
    }
}

extension EaseSelection {
    /// The effective shape of every selected segment, in segment order.
    public func shapes(in summary: KeyframeSummary) -> [(segment: EaseSegment, shape: EaseShape)] {
        segments.compactMap { seg in
            summary.tracks[seg.property]?.easeShape(from: seg.from, to: seg.to).map { (seg, $0.effective) }
        }
    }

    /// Rewrites every selected segment from its own shape (several rows eased together keep their own speeds while one
    /// handle drag changes the reach of all). Only the selected side of a segment is written. Returns segments written.
    @discardableResult
    public func transform(in summary: inout KeyframeSummary, _ change: (EaseSegment, EaseShape) -> EaseShape) -> Int {
        var n = 0
        for seg in segments {
            guard var t = summary.tracks[seg.property], let s = t.easeShape(from: seg.from, to: seg.to)?.effective,
                  t.setEaseShape(change(seg, s), from: seg.from, to: seg.to, side: seg.side) else { continue }
            summary.tracks[seg.property] = t
            n += 1
        }
        return n
    }
}

extension KeyframeTrack {
    func valueChange(from a: UUID, to b: UUID) -> Double? {
        guard let l = key(id: a), let r = key(id: b) else { return nil }
        return abs((r.value - l.value).speedMagnitude)
    }
}
