import Foundation

extension KeyframeTrack {
    /// Replaces the segment `a` -> `b` by linear keys sampling the spring (the file format has no spring). `a` and `b` keep
    /// their ids and values; `a` turns linear and both handles of the segment are reset so the baked keys are not reshaped.
    mutating func bakeSpring(_ spring: SpringEasing, from a: UUID, to b: UUID, samplesPerSecond: Int = 30) -> Bool {
        let shown = keys
        guard let i = shown.firstIndex(where: { $0.id == a }), i + 1 < shown.count, shown[i + 1].id == b else { return false }
        let l = shown[i], r = shown[i + 1]
        let baked = spring.bakedKeys(from: l.value, to: r.value, start: l.time, end: r.time, samplesPerSecond: samplesPerSecond)
        update(a) { $0.interpolation = .linear; $0.outHandle = .linear }
        update(b) { $0.inHandle = .linear }
        for k in baked.dropFirst().dropLast() { insert(k) }
        return true
    }
}

extension PropertyTrack {
    mutating func bakeSpring(_ spring: SpringEasing, from a: UUID, to b: UUID) -> Bool {
        switch self {
        case .scalar(var t): let ok = t.bakeSpring(spring, from: a, to: b); self = .scalar(t); return ok
        case .vector(var t): let ok = t.bakeSpring(spring, from: a, to: b); self = .vector(t); return ok
        case .color(var t): let ok = t.bakeSpring(spring, from: a, to: b); self = .color(t); return ok
        case .path(var t): let ok = t.bakeSpring(spring, from: a, to: b); self = .path(t); return ok
        }
    }
}

extension EaseSelection {
    /// Bakes the spring into every selected segment. Returns segments baked.
    @discardableResult
    public func bake(_ spring: SpringEasing, in summary: inout KeyframeSummary) -> Int {
        var n = 0
        for seg in segments {
            guard var t = summary.tracks[seg.property], t.bakeSpring(spring, from: seg.from, to: seg.to) else { continue }
            summary.tracks[seg.property] = t
            n += 1
        }
        return n
    }
}
