import Foundation
import SSCore

// Playback of anchored templates on a clip. Durations are never scaled: an in-animation starts at clip
// start, an out-animation ends at clip end. Clip-local `Time` everywhere in this file.

extension KeyframeTemplate {
    /// Clip time at which template-local time 0 plays (may be negative when the clip is shorter than an
    /// end-anchored animation: the first part of the animation is then simply never seen).
    public func startOffset(clipDuration: Time) -> Time {
        anchor == .start ? .zero : clipDuration - duration
    }

    /// Value of `property` at clip time `clipTime`. Exact (no key rewriting). Before the animation it holds
    /// the first key's value, after it the last key's value; nil if the property has no keys.
    public func value(of property: String, clipTime: Time, clipDuration: Time) -> Double? {
        value(of: property, at: clipTime - startOffset(clipDuration: clipDuration))
    }

    /// The tracks with key times moved to clip-local time (`startOffset` added).
    ///
    /// Clamping: keys are kept inside `0...clipDuration`. When the animation does not fit (clip shorter than
    /// the animation, or a non-positive clip), keys outside the range are dropped and replaced by boundary keys
    /// at 0 / `clipDuration` carrying the exact value there; curve handles of a cut bezier segment are then only
    /// approximated. For a non-positive clip duration each track collapses to one key at 0 (value at clip time 0).
    /// Use `value(of:clipTime:clipDuration:)` for exact evaluation.
    public func resolved(clipDuration: Time) -> [AnimationTrack] {
        let offset = startOffset(clipDuration: clipDuration)
        let lo = Time.zero, hi = max(clipDuration, .zero)
        return tracks.map { AnimationTrack(property: $0.property, track: Self.place($0.track, offset: offset, lo: lo, hi: hi)) }
    }

    static func place(_ track: KeyframeTrack<Double>, offset: Time, lo: Time, hi: Time) -> KeyframeTrack<Double> {
        guard let first = track.keys.first, let last = track.keys.last else { return track }
        func shifted(_ k: Keyframe<Double>) -> Keyframe<Double> { var c = k; c.time = k.time + offset; return c }
        func boundary(_ t: Time, _ like: Keyframe<Double>) -> Keyframe<Double> {
            Keyframe(id: like.id, time: t, value: track.value(at: t - offset) ?? like.value, interpolation: .linear,
                     inHandle: .linear, outHandle: .linear)
        }
        var out: [Keyframe<Double>] = []
        // Later wins on identical times, so the order makes the lower boundary win for an empty range.
        if last.time + offset > hi { out.append(boundary(hi, last)) }
        out += track.keys.map(shifted).filter { $0.time >= lo && $0.time <= hi }
        if first.time + offset < lo { out.append(boundary(lo, first)) }
        return KeyframeTrack(keys: out)
    }
}

/// An in-animation (start-anchored) plus an out-animation (end-anchored) on one clip.
///
/// Both sides are optional. The anchors of the passed templates are overridden (`in` -> `.start`, `out` -> `.end`).
/// Crossing policy: the in-animation has priority. The out-animation starts at `clipDuration - out.duration`,
/// but never before the in-animation ended; if that leaves no room (in-animation as long as the clip or longer)
/// the out-animation does not play at all. When it is pushed later it is cut by the clip end (not scaled).
/// Per property, while the out-animation plays its value wins if it animates that property, else the
/// in-animation's (clamped) value applies.
public struct AnimationSet: Sendable, Hashable, Codable {
    public var animationIn: KeyframeTemplate?
    public var animationOut: KeyframeTemplate?

    public init(in animationIn: KeyframeTemplate?, out animationOut: KeyframeTemplate?) {
        self.animationIn = animationIn.map { var a = $0; a.anchor = .start; return a }
        self.animationOut = animationOut.map { var a = $0; a.anchor = .end; return a }
    }

    /// Clip time where the out-animation starts; nil if there is none or it does not play (see type docs).
    public func outStart(clipDuration: Time) -> Time? {
        guard let out = animationOut else { return nil }
        let start = max(clipDuration - out.duration, animationIn?.duration ?? .zero, .zero)
        return start < clipDuration ? start : nil
    }

    public func value(of property: String, clipTime: Time, clipDuration: Time) -> Double? {
        let inValue = animationIn?.value(of: property, at: clipTime)
        guard let out = animationOut else { return inValue }
        guard let start = outStart(clipDuration: clipDuration) else { return inValue }
        let outValue = out.value(of: property, at: clipTime - start)
        return clipTime >= start ? (outValue ?? inValue) : (inValue ?? outValue)
    }
}

// MARK: - Retiming (authoring only)

extension KeyframeTemplate {
    /// Copy with template-local key times scaled by `newDuration / duration` (exact rational arithmetic, key ids,
    /// values, shapes and anchor unchanged). For authoring/editing ("make this animation longer"), never used
    /// by anchored playback: playing a template on a clip does not scale it (see `resolved(clipDuration:)`).
    ///
    /// Degenerate cases: a negative `newDuration` is treated as zero; with zero target all keys collapse to time 0
    /// (per track the last key wins); a zero source duration has no scale, so key times stay as they are.
    public func retimed(toDuration newDuration: Time) -> KeyframeTemplate {
        let target = max(newDuration, .zero)
        var copy = self
        copy.duration = target
        guard duration > .zero, target != duration else { return copy }
        copy.tracks = tracks.map { track in
            let keys = track.track.keys.map { k -> Keyframe<Double> in
                var c = k
                c.time = Self.scale(k.time, from: duration, to: target)
                return c
            }
            return AnimationTrack(property: track.property, track: KeyframeTrack(keys: keys))
        }
        return copy
    }

    /// t * to / from as a reduced rational (Int128 intermediates; traps only if the result leaves Int64).
    static func scale(_ t: Time, from: Time, to: Time) -> Time {
        var num = Int128(t.value) * Int128(to.value) * Int128(from.timescale)
        var den = Int128(t.timescale) * Int128(to.timescale) * Int128(from.value)
        var a = num.magnitude, b = den.magnitude
        while b != 0 { (a, b) = (b, a % b) }
        if a > 1 { num /= Int128(a); den /= Int128(a) }
        return Time(Int64(num), Int64(den))
    }
}
