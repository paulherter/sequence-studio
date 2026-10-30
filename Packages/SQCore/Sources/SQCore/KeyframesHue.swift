import Foundation

// COL-25: hue parameters (degrees round the color circle) take the short way between keys, so 350 -> 10 passes
// through 0 instead of sweeping through every other hue. Angles that mean a turn (Rotation, Direction, Mirror Angle)
// stay linear. Nothing new is stored: the catalog says which parameters are hues (`EffectParamSpec.isHue`).

enum HueMath {
    /// Signed step from `a` to `b` on the circle, -180...180. An exact half turn keeps the keyed direction.
    static func shortDelta(_ a: Double, _ b: Double) -> Double {
        let d = b - a
        return abs(d) == 180 ? d : remainder(d, 360)
    }

    /// `v` folded into 0...360 (values already there stay untouched, so 360 stays 360).
    static func wrap(_ v: Double) -> Double {
        guard v.isFinite, v < 0 || v > 360 else { return v }
        return v - 360 * (v / 360).rounded(.down)
    }
}

extension ClipEffect {
    /// Unclamped value of parameter `key` at clip-local `t` as the picture shows it: hues the short way round, Color
    /// wheels on the disc. nil when the parameter is not stored. For Effect Controls readouts and new keys.
    public func shownValue(_ key: String, atLocal t: Time) -> Double? {
        if isColor { return colorShownValue(key, atLocal: t) }
        guard let p = parameters[key] else { return nil }
        return EffectCatalog.param(kind, key)?.isHue == true ? p.hueValue(atLocal: t) : p.value(atLocal: t)
    }
}

extension Clip {
    /// After a key edit at clip-local `t` on parameter `key` of effect `id` (`before` = the clip before the edit): a
    /// parameter left without keys keeps the value it showed at `t` (hue the short way, wheel on the disc, not the
    /// straight-line value), and an animated wheel partner gets a key at `t` with its shown value so the puck does not
    /// jump. For per-row edits in Effect Controls (stopwatch off, key delete, add key, value edit).
    public mutating func followShownValues(effect id: UUID, key: String, atLocal t: Time, before: Clip) {
        guard let i = effects.firstIndex(where: { $0.id == id }),
              let b = before.effects.first(where: { $0.id == id }) else { return }
        if effects[i].parameters[key]?.isAnimated == false, b.parameters[key]?.isAnimated == true,
           let v = b.shownValue(key, atLocal: t) {
            effects[i].parameters[key]?.value = v
        }
        if effects[i].isColor { effects[i].keyWheelPartners(atLocal: t, before: b) }
    }
}

extension AnimatedProperty where V == Double {
    /// Value at clip-local `t` of a hue in degrees: each segment runs the shorter way round the circle, keeping its
    /// easing. Key values come back exactly, also the one a Hold or Hold Ahead shows over its whole segment (a step
    /// does not travel, so nothing is folded: a Hold Ahead before a key on 0 reads 0, not 360, and a held 370 reads
    /// 370 on the key and after it); values on the way between two keys lie in 0...360.
    public func hueValue(atLocal t: Time) -> Double {
        let keys = track.keys
        guard let first = keys.first, let last = keys.last else { return value }
        if t <= first.time { return first.value }
        guard let i = track.segmentIndex(at: t) else { return last.value }
        let a = keys[i]
        if t == a.time { return a.value }
        var b = keys[i + 1]
        if a.interpolation == .hold { return a.value }
        if a.interpolation == .holdAhead { return b.value }
        b.value = a.value + HueMath.shortDelta(a.value, b.value)
        return HueMath.wrap(KeyframeTrack<Double>.segmentValue(a, b, KeyframeMath.ratio(t - a.time, b.time - a.time)))
    }
}

extension KeyframeTrack where V == Double {
    /// Key values chained along the short arcs (350, 10, 30 becomes 350, 370, 390), so a straight or eased segment in
    /// this track is exactly the short-arc hue segment. Times, handles and interpolation stay. For drawing graphs.
    public func hueUnwrapped() -> KeyframeTrack<Double> {
        var t = self
        for i in t.keys.indices.dropFirst() {
            t.keys[i].value = t.keys[i - 1].value + HueMath.shortDelta(keys[i - 1].value, keys[i].value)
        }
        return t
    }
}
