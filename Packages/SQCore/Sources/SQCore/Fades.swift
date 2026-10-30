import Foundation

/// The keys a fade created, by ID (v20, optional on decode). A fade only ever modifies or removes the keys listed here;
/// every other key on the line belongs to the user (or to Auto Duck) and is never touched by a fade.
public struct FadeMarks: Sendable, Hashable, Codable {
    /// Head fade: the silent key at the clip start and the key where the line reaches its level (two IDs, in that order).
    public var head: [UUID] = []
    /// Tail fade: the key where the fade starts and the silent key at the clip end.
    public var tail: [UUID] = []
    public init(head: [UUID] = [], tail: [UUID] = []) { self.head = head; self.tail = tail }
    public var isEmpty: Bool { head.isEmpty && tail.isEmpty }
}

/// Fade handles on the edges of a clip, expressed as keys on an `AnimatedProperty<Double>` (clip-local time).
/// Shared by the audio volume line (this stream) and, later, by video opacity: both call these functions, each with its
/// own `FadeMarks`.
///
/// A head fade is two keys: the first key silent (`floor`), the second key at the level the line had there, so the line
/// rises between them. A tail fade mirrors that. Both keys are recorded in `FadeMarks`, which is the only way a fade is
/// recognized: the length is read from the marked keys (so a fade shortened by a trim shows the remaining length), and
/// removing a fade removes just those keys.
///
/// Keys of the user or of Auto Duck that lie INSIDE the fade region are kept as they are and keep their own value: the
/// line goes floor, then through them, then to the level (they are not scaled). Only a key exactly on a fade's end
/// time is absorbed (it has the same value by construction). Lengths are whole frames: less than one frame means no fade.
public enum FadeKeys {
    /// Length of the head fade (time of its second key), nil when there is none.
    public static func headLength(of p: AnimatedProperty<Double>, marks: FadeMarks) -> Time? {
        guard let k = keys(p, marks.head) else { return nil }
        return max(k[1].time, .zero)
    }

    /// Length of the tail fade inside a clip of `duration`, nil when there is none.
    public static func tailLength(of p: AnimatedProperty<Double>, duration: Time, marks: FadeMarks) -> Time? {
        guard let k = keys(p, marks.tail) else { return nil }
        return max(duration - k[0].time, .zero)
    }

    /// The property with a head fade of `length` (snapped down to whole frames; below one frame = no fade, and an
    /// existing head fade is removed). `marks` is updated. The level the fade rises to is the level the line had there.
    public static func settingHead(_ prop: AnimatedProperty<Double>, marks: inout FadeMarks, length: Time, duration: Time,
                                   frameDuration: Time, floor: Double = 0) -> AnimatedProperty<Double> {
        var p = removingHead(prop, marks: &marks)
        let tailLen = tailLength(of: p, duration: duration, marks: marks) ?? .zero
        let l = min(snapDown(length, frameDuration), max(snapDown(duration - tailLen, frameDuration), .zero))
        guard l > .zero else { return p }
        let level = p.value(atLocal: l)
        let a = place(Keyframe(time: .zero, value: floor), in: &p, shared: marks.tail)
        let b = place(Keyframe(time: l, value: level), in: &p, shared: marks.tail)
        marks.head = [a, b]
        return p
    }

    /// The property with a tail fade of `length`; same rules as `settingHead`.
    public static func settingTail(_ prop: AnimatedProperty<Double>, marks: inout FadeMarks, length: Time, duration: Time,
                                   frameDuration: Time, floor: Double = 0) -> AnimatedProperty<Double> {
        var p = removingTail(prop, marks: &marks)
        let headLen = headLength(of: p, marks: marks) ?? .zero
        let l = min(snapDown(length, frameDuration), max(snapDown(duration - headLen, frameDuration), .zero))
        guard l > .zero else { return p }
        let from = duration - l
        let level = p.value(atLocal: from)
        let a = place(Keyframe(time: from, value: level), in: &p, shared: marks.head)
        let b = place(Keyframe(time: duration, value: floor), in: &p, shared: marks.head)
        marks.tail = [a, b]
        return p
    }

    /// Removes the head fade's two keys and nothing else. A line left without keys becomes a constant at the level the
    /// fade rose to.
    public static func removingHead(_ prop: AnimatedProperty<Double>, marks: inout FadeMarks) -> AnimatedProperty<Double> {
        defer { marks.head = [] }
        return removing(prop, ids: marks.head, keeping: marks.tail, levelKey: 1)
    }

    public static func removingTail(_ prop: AnimatedProperty<Double>, marks: inout FadeMarks) -> AnimatedProperty<Double> {
        defer { marks.tail = [] }
        return removing(prop, ids: marks.tail, keeping: marks.head, levelKey: 0)
    }

    /// Marks that still point at both of their keys; a fade whose key was deleted or replaced is no longer a fade (its
    /// remaining key is an ordinary key).
    public static func pruned(_ marks: FadeMarks, in p: AnimatedProperty<Double>) -> FadeMarks {
        FadeMarks(head: keys(p, marks.head) == nil ? [] : marks.head, tail: keys(p, marks.tail) == nil ? [] : marks.tail)
    }

    // MARK: internals

    /// The two marked keys in `ids` order, nil unless both are on the line.
    private static func keys(_ p: AnimatedProperty<Double>, _ ids: [UUID]) -> [Keyframe<Double>]? {
        guard ids.count == 2, let a = p.track.key(id: ids[0]), let b = p.track.key(id: ids[1]) else { return nil }
        return [a, b]
    }

    /// Inserts `key`, or, when a key of the OTHER fade (`shared`) already sits at that time (the two fades meet), reuses
    /// that key: both fades then point at it and it stays until both are gone. Returns the ID the mark should hold.
    private static func place(_ key: Keyframe<Double>, in p: inout AnimatedProperty<Double>, shared: [UUID]) -> UUID {
        if let e = p.track.keys.first(where: { $0.time == key.time && shared.contains($0.id) }) { return e.id }
        p.track.insert(key)
        return key.id
    }

    private static func removing(_ prop: AnimatedProperty<Double>, ids: [UUID], keeping other: [UUID], levelKey: Int) -> AnimatedProperty<Double> {
        guard let k = keys(prop, ids) else { return prop }
        var p = prop
        p.track.keys.removeAll { ids.contains($0.id) && !other.contains($0.id) }
        if p.track.keys.isEmpty { p.value = k[levelKey].value }
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
    public var audioFadeIn: Time { FadeKeys.headLength(of: animation.volume, marks: audioFades) ?? .zero }
    public var audioFadeOut: Time { FadeKeys.tailLength(of: animation.volume, duration: timeline.duration, marks: audioFades) ?? .zero }

    public mutating func setAudioFadeIn(_ length: Time, frameDuration: Time) {
        let curve = audioFadeInCurve
        defer { if let curve, curve != .linear, audioFadeInCurve != nil { setAudioFadeCurve(curve, head: true) } }
        animation.volume = FadeKeys.settingHead(animation.volume, marks: &audioFades, length: length, duration: timeline.duration, frameDuration: frameDuration)
        pruneAudioKeyMarks()
    }
    public mutating func setAudioFadeOut(_ length: Time, frameDuration: Time) {
        let curve = audioFadeOutCurve
        defer { if let curve, curve != .linear, audioFadeOutCurve != nil { setAudioFadeCurve(curve, head: false) } }
        animation.volume = FadeKeys.settingTail(animation.volume, marks: &audioFades, length: length, duration: timeline.duration, frameDuration: frameDuration)
        pruneAudioKeyMarks()
    }

    /// Drops the IDs of keys that are gone: Auto Duck's `duckKeyIDs` and fades that lost one of their keys.
    public mutating func pruneAudioKeyMarks() {
        let p = animation.volume
        if !duckKeyIDs.isEmpty { duckKeyIDs = duckKeyIDs.filter { p.track.key(id: $0) != nil } }
        if !audioFades.isEmpty { audioFades = FadeKeys.pruned(audioFades, in: p) }
    }
}

extension Timeline {
    /// Housekeeping after every edit: prunes key marks, and lets an audio transition replace the fade on its edge (the
    /// transition wins, like Premiere where a transition takes the place of the fade handle): the fade's two keys on an
    /// edge that has a transition are removed.
    public mutating func normalizeAudioKeyMarks() {
        var changed: [Clip] = []
        for track in tracks where track.kind == .audio {
            let heads = Set(track.transitions.compactMap(\.incoming)), tails = Set(track.transitions.compactMap(\.outgoing))
            for original in track.clips where !original.audioFades.isEmpty || !original.duckKeyIDs.isEmpty {
                var c = original
                var m = c.audioFades
                if heads.contains(c.id), !m.head.isEmpty { c.animation.volume = FadeKeys.removingHead(c.animation.volume, marks: &m) }
                if tails.contains(c.id), !m.tail.isEmpty { c.animation.volume = FadeKeys.removingTail(c.animation.volume, marks: &m) }
                c.audioFades = m
                c.pruneAudioKeyMarks()
                if c != original { changed.append(c) }
            }
        }
        for c in changed { try? replaceClip(c) }
    }

    /// Whether the head / tail edge of `clip` carries an audio transition (no fade handle there).
    public func hasAudioTransition(clip id: Clip.ID, head: Bool) -> Bool {
        tracks.contains { $0.transitions.contains { head ? $0.incoming == id : $0.outgoing == id } }
    }
}
