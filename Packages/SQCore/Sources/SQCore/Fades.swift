import Foundation

/// Fade handles on the edges of a clip, expressed as keys on an `AnimatedProperty<Double>` (clip-local time).
/// Shared by the audio volume line (this stream) and, later, by video opacity: both call these functions.
///
/// A head fade is two keys: the first key silent (`floor`), the second key louder, so the line rises between them.
/// A tail fade mirrors that: the last key silent, the one before it louder. The length is read from the keys, so a
/// fade shortened by a trim shows the remaining length. Lengths are whole frames: less than one frame means no fade.
public enum FadeKeys {
    /// Length of the head fade (time of its second key), nil when there is none.
    public static func headLength(of p: AnimatedProperty<Double>, floor: Double = 0) -> Time? {
        guard let h = head(p, floor) else { return nil }
        return max(p.track.keys[h].time, .zero)
    }

    /// Length of the tail fade inside a clip of `duration`, nil when there is none.
    public static func tailLength(of p: AnimatedProperty<Double>, duration: Time, floor: Double = 0) -> Time? {
        guard let t = tail(p, floor) else { return nil }
        return max(duration - p.track.keys[t].time, .zero)
    }

    /// The property with a head fade of `length` (snapped down to whole frames; below one frame = no fade, and an
    /// existing head fade is removed). The level the fade rises to is the level the line had at the fade's end.
    public static func settingHead(_ prop: AnimatedProperty<Double>, length: Time, duration: Time, frameDuration: Time,
                                   floor: Double = 0) -> AnimatedProperty<Double> {
        var p = removingHead(prop, floor)
        let tailLen = tailLength(of: p, duration: duration, floor: floor) ?? .zero
        let l = min(snapDown(length, frameDuration), max(snapDown(duration - tailLen, frameDuration), .zero))
        guard l > .zero else { return p }
        let level = p.value(atLocal: l)
        p.track.keys.removeAll { $0.time < l }
        p.track.insert(Keyframe(time: .zero, value: floor))
        p.track.insert(Keyframe(time: l, value: level))
        return p
    }

    /// The property with a tail fade of `length`; same rules as `settingHead`.
    public static func settingTail(_ prop: AnimatedProperty<Double>, length: Time, duration: Time, frameDuration: Time,
                                   floor: Double = 0) -> AnimatedProperty<Double> {
        var p = removingTail(prop, floor)
        let headLen = headLength(of: p, floor: floor) ?? .zero
        let l = min(snapDown(length, frameDuration), max(snapDown(duration - headLen, frameDuration), .zero))
        guard l > .zero else { return p }
        let from = duration - l
        let level = p.value(atLocal: from)
        p.track.keys.removeAll { $0.time > from }
        p.track.insert(Keyframe(time: from, value: level))
        p.track.insert(Keyframe(time: duration, value: floor))
        return p
    }

    /// Removes a head fade (its two keys); a line that is then flat becomes a plain constant again.
    public static func removingHead(_ prop: AnimatedProperty<Double>, _ floor: Double = 0) -> AnimatedProperty<Double> {
        guard let h = head(prop, floor) else { return prop }
        var p = prop
        p.track.keys.removeSubrange(0...h)
        return flattened(p, keeping: prop.track.keys[h].value)
    }

    public static func removingTail(_ prop: AnimatedProperty<Double>, _ floor: Double = 0) -> AnimatedProperty<Double> {
        guard let t = tail(prop, floor) else { return prop }
        var p = prop
        p.track.keys.removeSubrange(t...)
        return flattened(p, keeping: prop.track.keys[t].value)
    }

    // MARK: internals

    /// Index of the head fade's second key.
    private static func head(_ p: AnimatedProperty<Double>, _ floor: Double) -> Int? {
        let k = p.track.keys
        return k.count >= 2 && k[0].value <= floor && k[1].value > floor ? 1 : nil
    }

    /// Index of the tail fade's first key.
    private static func tail(_ p: AnimatedProperty<Double>, _ floor: Double) -> Int? {
        let k = p.track.keys
        return k.count >= 2 && k[k.count - 1].value <= floor && k[k.count - 2].value > floor ? k.count - 2 : nil
    }

    /// After a fade's keys are gone: nothing left = constant at `level`; one key left = constant at that key.
    private static func flattened(_ p: AnimatedProperty<Double>, keeping level: Double) -> AnimatedProperty<Double> {
        var p = p
        switch p.track.keys.count {
        case 0: p.value = level
        case 1: p.value = p.track.keys[0].value; p.track.keys = []
        default: break
        }
        return p
    }

    /// Largest whole number of frames not above `t`.
    static func snapDown(_ t: Time, _ frame: Time) -> Time {
        guard t > .zero, frame > .zero else { return .zero }
        return frame * t.frameIndex(frameDuration: frame)
    }
}

extension Clip {
    /// Audio fade handles: lengths (timeline time) of the head and tail fade on the volume line.
    public var audioFadeIn: Time { FadeKeys.headLength(of: animation.volume) ?? .zero }
    public var audioFadeOut: Time { FadeKeys.tailLength(of: animation.volume, duration: timeline.duration) ?? .zero }

    public mutating func setAudioFadeIn(_ length: Time, frameDuration: Time) {
        animation.volume = FadeKeys.settingHead(animation.volume, length: length, duration: timeline.duration, frameDuration: frameDuration)
    }
    public mutating func setAudioFadeOut(_ length: Time, frameDuration: Time) {
        animation.volume = FadeKeys.settingTail(animation.volume, length: length, duration: timeline.duration, frameDuration: frameDuration)
    }
}
