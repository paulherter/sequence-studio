import Foundation

// Soft edges of a range grade (v50): the grade's strength ramps 0 -> 1 over `colorFadeIn` at the start of its range and
// 1 -> 0 over `colorFadeOut` at the end. Strength scales every value toward neutral (ColorEffect.scaled). Preview and
// export share `Clip.renderColor`, so they match by construction.

extension ClipEffect {
    public var hasRangeFade: Bool { colorRange != nil && (colorFadeIn != nil || colorFadeOut != nil) }

    /// 0...1 strength of a range grade at clip-local `t`: 1 for effects without a range or fades, 0 outside the range.
    public func rangeStrength(atLocal t: Time) -> Double {
        guard let r = colorRange else { return 1 }
        guard r.contains(t) else { return 0 }
        func s(_ x: Time) -> Double { Double(x.value) / Double(x.timescale) }
        let dur = s(r.duration)
        var w = 1.0
        if let fi = colorFadeIn, fi > .zero {
            let f = min(s(fi), dur)
            if f > 0 { w = min(w, s(t - r.start) / f) }
        }
        if let fo = colorFadeOut, fo > .zero {
            let f = min(s(fo), dur)
            if f > 0 { w = min(w, s(r.end - t) / f) }
        }
        return min(max(w, 0), 1)
    }
}

extension ColorEffect {
    /// The effect at strength `w` (0 = neutral, 1 = unchanged): numeric values move toward their neutral value, curves
    /// toward the identity, the Color Range correction toward no correction. LUTs fade through their intensity.
    func scaled(by w: Float) -> ColorEffect {
        let w = min(max(w, 0), 1)
        var e = self
        let neutral = ColorEffect(id: id)
        let lutKeys: Set<String> = [ClipEffect.colorInputLUTIntensityKey, ClipEffect.colorLookIntensityKey]
        func mix(_ v: Float, _ n: Float) -> Float { n + (v - n) * w }
        for f in ColorGradeFields.scalars where !f.isHue {
            let n: Float = lutKeys.contains(f.key) ? 0 : neutral[keyPath: f.path]
            e[keyPath: f.path] = mix(self[keyPath: f.path], n)
        }
        func pts(_ p: [CurvePoint], flat: Bool) -> [CurvePoint] {
            p.map { CurvePoint($0.x, mix($0.y, flat ? 0.5 : $0.x)) }
        }
        e.curves.master = pts(curves.master, flat: false); e.curves.red = pts(curves.red, flat: false)
        e.curves.green = pts(curves.green, flat: false); e.curves.blue = pts(curves.blue, flat: false)
        e.hueCurves.hueVsSat = pts(hueCurves.hueVsSat, flat: true); e.hueCurves.hueVsHue = pts(hueCurves.hueVsHue, flat: true)
        e.hueCurves.hueVsLuma = pts(hueCurves.hueVsLuma, flat: true); e.hueCurves.lumaVsSat = pts(hueCurves.lumaVsSat, flat: true)
        e.hueCurves.satVsSat = pts(hueCurves.satVsSat, flat: true)
        if var h = hslSecondary {
            h.hueShift = mix(h.hueShift, 0); h.saturation = mix(h.saturation, 100); h.exposure = mix(h.exposure, 0)
            h.temperature = mix(h.temperature, 0); h.tint = mix(h.tint, 0)
            e.hslSecondary = h
        }
        if var z = zoneBoard {
            for zone in BoardZone.allCases {
                var v = z[zone]
                v.puckX = mix(v.puckX, 0.5); v.puckY = mix(v.puckY, 0.5)
                v.saturation = mix(v.saturation, 0.5); v.exposure = mix(v.exposure, 0.5)
                z[zone] = v
            }
            e.zoneBoard = z
        }
        return e
    }
}

extension Project {
    /// Any effect carries fade lengths (with or without a range, so the stamped version matches what is written): v50.
    public var containsRangeFades: Bool {
        allClips().contains { c in c.effects.contains { $0.colorFadeIn != nil || $0.colorFadeOut != nil } }
    }
}

extension Clip {
    /// Sets (or clears with nil) the fade-in / fade-out lengths of range grade `id`; each is clamped to the range length.
    /// Refused for effects without a range.
    @discardableResult
    public mutating func setColorRangeFades(_ id: ClipEffect.ID, fadeIn: Time?, fadeOut: Time?) -> Bool {
        guard let i = effects.firstIndex(where: { $0.id == id && $0.isColor }), let r = effects[i].colorRange else { return false }
        func clean(_ t: Time?) -> Time? { guard let t, t > .zero else { return nil }; return min(t, r.duration) }
        effects[i].colorFadeIn = clean(fadeIn)
        effects[i].colorFadeOut = clean(fadeOut)
        return true
    }
}
