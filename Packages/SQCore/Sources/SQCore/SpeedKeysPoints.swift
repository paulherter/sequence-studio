import Foundation

/// Speed points the way a retime curve has them (Resolve): a point is a key that plays the same source frame wherever it
/// sits, so moving it sideways makes the span before it faster or slower and the clip length follows; easing a point
/// opens a short speed transition at it and curves that, like the keyframe easing of any other row.
extension SpeedKeys {
    /// Moves the point at `boundary` by `delta` on the timeline while it keeps its source frame: the constant span before it
    /// grows or shrinks to `delta` frames more or less (whole frames, at least one) and takes the speed that still covers
    /// the same source, within 1 % ... 10000 %. The spans after it keep their speed and shift; the clip length changes by the
    /// same amount. nil when the point is a half of a transition (move that instead) or nothing changes.
    public func retimingKey(atBoundary b: Int, by delta: Time, frameDuration fd: Time) -> SpeedKeys? {
        guard b >= 1, b < segments.count, !segments[b - 1].isRamp, !segments[b].isRamp else { return nil }
        let l = segments[b - 1]
        let n = Swift.max(l.duration + delta.snapped(to: fd), fd)
        guard n != l.duration else { return nil }
        let edited = settingSpeed(ofSegment: b - 1, to: ClipSpeed(source: l.span, over: n), frameDuration: fd)
        return edited == self ? nil : edited
    }

    /// Easing on a speed point (Easy Ease / Ease In / Ease Out): the speed transition at clip-local `local` gets the curve
    /// on the asked side (`.in` the arrival, `.out` the start). `local` inside a transition or on one of its ends eases that
    /// transition; on a plain point between two different speeds a transition a quarter of the shorter neighbor wide
    /// (at least one frame) opens centered on it first. nil when there is nothing to ease (no change of speed at that
    /// point, a Hold curve, or nothing changes).
    public func easingPoint(atLocal local: Time, curve: EasingCurve, side: EaseSide, frameDuration fd: Time) -> SpeedKeys? {
        guard !curve.interpolation.isHold else { return nil }
        let bs = boundaries
        var k = self
        var i: Int
        if let r = segments.indices.first(where: { segments[$0].isRamp && bs[$0] <= local && local <= bs[$0 + 1] }) {
            i = r
        } else if let b = bs.indices.first(where: { $0 >= 1 && $0 < segments.count && bs[$0] == local.snapped(to: fd) }) {
            let l = segments[b - 1], r = segments[b]
            guard !l.isRamp, !r.isRamp, l.from != r.from else { return nil }
            let m = Swift.min(l.duration, r.duration)
            let half = Swift.max(Time(m.value, m.timescale * 4).snapped(to: fd), fd)
            guard let s = splittingKey(atBoundary: b, half: half, frameDuration: fd) else { return nil }
            k = s; i = b
        } else {
            return nil
        }
        let old = k.segments[i].easeShape
        let shape = EaseShape(interpolation: .bezier, out: side == .in ? old.out : curve.outHandle,
                              in: side == .out ? old.in : curve.inHandle)
        guard let eased = k.settingEase(shape, ofSegment: i), eased != self else { return nil }
        return eased
    }
}
