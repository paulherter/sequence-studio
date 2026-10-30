import Foundation

/// Auto Duck: lowers a music clip's volume line while dialogue plays. Pure: the caller supplies the dialogue ranges
/// (clip-local times), the function returns volume keys. Rational time throughout.
public enum Ducking {
    public static let defaultAmountDB = 12.0
    /// Ramp length of 0.3 s as a rational (no Double time).
    public static let defaultFade = Time(3, 10)

    /// Keys that duck `base` (the clip's own volume line, evaluated at a clip-local time) by `amountDB` wherever one
    /// of `dialogue` is, with linear ramps of `fade` before and after. Ranges closer than two ramps are merged so
    /// the ramps never overlap. Everything is clamped to `0 ... duration`. Empty without dialogue.
    public static func keys(dialogue: [TimeRange], duration: Time, amountDB: Double, fade: Time, recovery: Time? = nil,
                            base: (Time) -> Double) -> [Keyframe<Double>] {
        let rec = recovery ?? fade
        guard duration > .zero, amountDB > 0 else { return [] }
        let factor = pow(10, -amountDB / 20)
        let spans = spans(dialogue: dialogue, duration: duration, fade: fade, recovery: rec)
        var out: [Keyframe<Double>] = []
        func add(_ t: Time, ducked: Bool) {
            let v = base(t)
            out.append(Keyframe(time: t, value: ducked ? v * factor : v))
        }
        for (a, b) in spans {
            if a - fade > .zero { add(a - fade, ducked: false); add(a, ducked: true) } else { add(.zero, ducked: true) }
            if b + rec < duration { add(b, ducked: true); add(b + rec, ducked: false) } else { add(duration, ducked: true) }
        }
        return out
    }
}

extension Ducking {
    /// The stretches that are fully ducked (start, end): the dialogue clamped to `0 ... duration`, ranges closer than
    /// two ramps merged.
    static func spans(dialogue: [TimeRange], duration: Time, fade: Time, recovery rec: Time) -> [(Time, Time)] {
        var spans: [(Time, Time)] = []
        for r in dialogue.sorted(by: { $0.start < $1.start }) {
            let a = max(r.start, .zero), b = min(r.end, duration)
            guard b > a else { continue }
            if let last = spans.last, a - last.1 <= fade + rec { spans[spans.count - 1].1 = max(last.1, b) }
            else { spans.append((a, b)) }
        }
        return spans
    }
}

extension Clip {
    /// Drops exactly the keys an earlier duck run generated (the clip's own volume line stays). Returns how many went.
    /// The explicit way to remove duck keys: `applyDucking(dialogue: [])` does the same only as a side effect of "no dialogue".
    @discardableResult
    public mutating func removeDuckKeys() -> Int {
        let generated = Set(duckKeyIDs)
        guard !generated.isEmpty else { return 0 }
        var v = animation.volume
        let before = v.track.keys.count
        v.track.keys.removeAll { generated.contains($0.id) }
        if before > 0 && v.track.isEmpty { v.value = animation.volume.value }
        animation.volume = v
        duckKeyIDs = []
        return before - v.track.keys.count
    }

    /// Runs Auto Duck on this (music) clip: removes the keys of the previous run, then adds the new ones.
    /// `dialogue` is in timeline time. The clip's own keys stay; a generated key never replaces one of them.
    /// Returns the number of keys added (0 when there is no dialogue over the clip).
    ///
    /// A generated key that follows a Hold Ahead is the key it shows: the step to the ducked level falls on the Hold
    /// Ahead's own time, inside the fade.
    @discardableResult
    public mutating func applyDucking(dialogue: [TimeRange], amountDB: Double = Ducking.defaultAmountDB,
                                      fade: Time = Ducking.defaultFade, recovery: Time? = nil) -> Int {
        var v = animation.volume
        let generated = Set(duckKeyIDs)
        let hadKeys = !v.track.isEmpty
        v.track.keys.removeAll { generated.contains($0.id) }
        if hadKeys && v.track.isEmpty { v.value = animation.volume.value }
        let local = dialogue.map { TimeRange(start: $0.start - start, duration: $0.duration) }
        let base = v
        let keys = Ducking.keys(dialogue: local, duration: duration, amountDB: amountDB, fade: fade, recovery: recovery) { base.value(atLocal: $0) }
        var added: [UUID] = []
        for k in keys where !v.track.keys.contains(where: { $0.time == k.time }) {
            v.track.insert(k); added.append(k.id)
        }
        animation.volume = v
        duckKeyIDs = added
        return added.count
    }
}
