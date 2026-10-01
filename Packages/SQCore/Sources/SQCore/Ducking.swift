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
    public static func keys(dialogue: [TimeRange], duration: Time, amountDB: Double, fade: Time,
                            base: (Time) -> Double) -> [Keyframe<Double>] {
        guard duration > .zero, amountDB > 0 else { return [] }
        let factor = pow(10, -amountDB / 20)
        var spans: [(Time, Time)] = []
        for r in dialogue.sorted(by: { $0.start < $1.start }) {
            let a = max(r.start, .zero), b = min(r.end, duration)
            guard b > a else { continue }
            if let last = spans.last, a - last.1 <= fade + fade { spans[spans.count - 1].1 = max(last.1, b) }
            else { spans.append((a, b)) }
        }
        var out: [Keyframe<Double>] = []
        func add(_ t: Time, ducked: Bool) {
            let v = base(t)
            out.append(Keyframe(time: t, value: ducked ? v * factor : v))
        }
        for (a, b) in spans {
            if a - fade > .zero { add(a - fade, ducked: false); add(a, ducked: true) } else { add(.zero, ducked: true) }
            if b + fade < duration { add(b, ducked: true); add(b + fade, ducked: false) } else { add(duration, ducked: true) }
        }
        return out
    }
}

extension Clip {
    /// Runs Auto Duck on this (music) clip: removes the keys of the previous run, then adds the new ones.
    /// `dialogue` is in timeline time. The clip's own keys stay; a generated key never replaces one of them.
    /// Returns the number of keys added (0 when there is no dialogue over the clip).
    @discardableResult
    public mutating func applyDucking(dialogue: [TimeRange], amountDB: Double = Ducking.defaultAmountDB,
                                      fade: Time = Ducking.defaultFade) -> Int {
        var v = animation.volume
        let generated = Set(duckKeyIDs)
        let hadKeys = !v.track.isEmpty
        v.track.keys.removeAll { generated.contains($0.id) }
        if hadKeys && v.track.isEmpty { v.value = animation.volume.value }
        let local = dialogue.map { TimeRange(start: $0.start - start, duration: $0.duration) }
        let base = v
        let keys = Ducking.keys(dialogue: local, duration: duration, amountDB: amountDB, fade: fade) { base.value(atLocal: $0) }
        var added: [UUID] = []
        for k in keys where !v.track.keys.contains(where: { $0.time == k.time }) {
            v.track.insert(k); added.append(k.id)
        }
        animation.volume = v
        duckKeyIDs = added
        return added.count
    }
}
