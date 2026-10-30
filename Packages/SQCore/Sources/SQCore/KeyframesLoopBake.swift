import Foundation

// Advanced key operations on one track (the AE-style Loop, Convert to Keys and Wiggle). All of them produce plain
// keys: the file format has no expression, so nothing here needs a project file field.

extension KeyframeTrack {
    /// Repeats the key pattern `cycles` more times after the last key (Loop). The first key of a repeat sits on the previous
    /// cycle's last key and is dropped; new keys get new ids. Needs at least two keys.
    public mutating func loop(cycles: Int) {
        guard cycles > 0, keys.count >= 2, let first = keys.first, let last = keys.last else { return }
        let period = last.time - first.time
        guard period > .zero else { return }
        var out = keys
        for c in 1...cycles {
            let shift = period * Int64(c)
            for k in keys.dropFirst() {
                var n = k
                n.id = UUID()
                n.time = k.time + shift
                out.append(n)
            }
        }
        editKeys { $0 = out }
    }

    /// Replaces the keys in `start...end` by linear keys sampled from the current curve at `samplesPerSecond` (Convert to
    /// Keys). The sampled curve keeps both end values; keys outside the range stay. Returns false for an empty range.
    @discardableResult
    public mutating func bakeSamples(from start: Time, to end: Time, samplesPerSecond: Int) -> Bool {
        guard samplesPerSecond > 0, end > start, !keys.isEmpty else { return false }
        let times = Self.sampleTimes(start, end, samplesPerSecond)
        var out = keys.filter { $0.time < start || $0.time > end }
        for time in times {
            if let v = value(at: time) { out.append(Keyframe<V>(time: time, value: v, interpolation: .linear)) }
        }
        editKeys { $0 = out }
        return true
    }

    fileprivate static func sampleTimes(_ start: Time, _ end: Time, _ perSecond: Int) -> [Time] {
        let step = Time(1, Int64(perSecond))
        var times: [Time] = []
        var t = start
        while t < end { times.append(t); t = t + step }
        times.append(end)
        return times
    }
}

extension KeyframeTrack where V == Double {
    /// Wiggle: bakes `perSecond` random offsets of up to +/- `amount` into `start...end` (deterministic for one `seed`).
    /// The key at `start` and at `end` keeps the curve value so the wiggle blends in and out.
    @discardableResult
    public mutating func wiggle(from start: Time, to end: Time, perSecond: Int, amount: Double, seed: UInt64) -> Bool {
        guard perSecond > 0, end > start, !keys.isEmpty else { return false }
        let times = Self.sampleTimes(start, end, perSecond)
        var rng = SplitMix64(seed: seed)
        var out = keys.filter { $0.time < start || $0.time > end }
        for (i, time) in times.enumerated() {
            guard let base = value(at: time) else { continue }
            let edge = i == 0 || i == times.count - 1
            let noise = edge ? 0 : (rng.nextUnit() * 2 - 1) * amount
            out.append(Keyframe<Double>(time: time, value: base + noise, interpolation: .linear))
        }
        editKeys { $0 = out }
        return true
    }
}

struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// 0..<1
    mutating func nextUnit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
