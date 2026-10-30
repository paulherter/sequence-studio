import Foundation

/// Speed as keyframes (Effect Controls Speed row): the speed track read as "value at a key, ease between keys".
///
/// No second model: a key is a boundary of the speed track, its value is the speed the track has there, and the stretch
/// between two keys is a ramp segment (linear or Bezier, `SpeedKeysEase.swift`). Before the first key and after the last the
/// speed is constant (the first / last key's value), like any other keyframed parameter. Setting a key's value therefore
/// rewrites the two segments around it and nothing else; every segment keeps its timeline length (keys stay on their
/// frames), the source each segment covers follows the integral of the eased speed, so the source time stays continuous.
extension SpeedKeys {
    /// Index of the boundary at clip-local `local` (snapped to a frame), nil when there is none.
    public func keyBoundary(atLocal local: Time, frameDuration fd: Time) -> Int? {
        let x = local.snapped(to: fd)
        guard x >= .zero, x < duration else { return nil }
        return boundaries.firstIndex(of: x).flatMap { $0 < segments.count ? $0 : nil }
    }

    /// Sets the speed at clip-local `local` to `v`. A frame without a key gets one first (holding the speed there, so
    /// nothing else changes). The segment before the key ends on `v` (a ramp from the previous key's value; the stretch
    /// before the first key is constant `v`), the segment after starts on `v` (a ramp to the next key's value; after the
    /// last key constant `v`). Ramps keep their ease curve (also while flat). The clip start is no key: a value set there
    /// goes to the first key. nil when `local` is outside the clip.
    public func settingKeySpeed(atLocal local: Time, to v: ClipSpeed, frameDuration fd: Time) -> SpeedKeys? {
        let x = local.snapped(to: fd)
        guard x >= .zero, x < duration else { return nil }
        var k = self
        var b: Int
        if x == .zero {
            // Clip start is no key: the stretch before the first key takes the value (that is the first key's value).
            if k.segments.count == 1 {
                k.segments[0] = SpeedSegment(duration: k.segments[0].duration, from: v, to: v, reversed: k.segments[0].reversed)
                return k.normalized(collapsingUniform: false)
            }
            b = 1
        } else if let existing = k.boundaries.firstIndex(of: x), existing < k.segments.count {
            b = existing
        } else if let added = k.addingKey(at: x, frameDuration: fd) {
            k = added.keys; b = added.boundary
        } else { return nil }

        func make(_ s: SpeedSegment, from a: ClipSpeed, to c: ClipSpeed) -> SpeedSegment {
            SpeedSegment(duration: s.duration, from: a, to: c, reversed: s.reversed, ease: s.ease)    // a flat ramp keeps its curve, so a drag through the neighbor's value does not lose it
        }
        if b >= 1 {
            let s = k.segments[b - 1]
            if b - 1 == 0 && !s.isRamp { k.segments[b - 1] = make(s, from: v, to: v) }      // before the first key: constant
            else { k.segments[b - 1] = make(s, from: s.from, to: v) }
        }
        let s = k.segments[b]
        if s.isRamp {
            k.segments[b] = make(s, from: v, to: s.to)
        } else {
            let next = b + 1 < k.segments.count ? k.segments[b + 1].from : v
            k.segments[b] = make(s, from: v, to: next)
        }
        return k.normalized(collapsingUniform: false)
    }
}
