import Foundation

// C2 (filmcraft follow-up, ideas only, no code copied): Color Match measured perceptually. Both clips' stored band means
// are compared in Oklab (Björn Ottosson, "A perceptual color space for image processing", 2020: the published matrices),
// each tone band gets its own shift, skin hues keep only a fifth of the change, clearly colored pixels turn by at most a
// few degrees of hue, and the result is fitted onto the ordinary Color Wheels by running the real wheels model on a few
// hundred sample colors, so it stays an editable grade. The stored `ColorMatchStats` are unchanged (display RGB).

/// Oklab of a display-encoded color (BT.1886 gamma 2.4 to linear light, sign kept for out-of-range values).
public enum Oklab {
    @inline(__always) static func signedPow(_ v: Float, _ e: Float) -> Float { v < 0 ? -powf(-v, e) : powf(v, e) }

    public static func fromLinear(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let l = 0.4122214708 * c.x + 0.5363325363 * c.y + 0.0514459929 * c.z
        let m = 0.2119034982 * c.x + 0.6806995451 * c.y + 0.1073969566 * c.z
        let s = 0.0883024619 * c.x + 0.2817188376 * c.y + 0.6299787005 * c.z
        let l_ = cbrtf(l), m_ = cbrtf(m), s_ = cbrtf(s)
        return SIMD3(0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
                     1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
                     0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_)
    }

    public static func toLinear(_ lab: SIMD3<Float>) -> SIMD3<Float> {
        let l_ = lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z
        let m_ = lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z
        let s_ = lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z
        let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
        return SIMD3(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                     -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                     -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    }

    public static func fromDisplay(_ c: SIMD3<Float>) -> SIMD3<Float> {
        fromLinear(SIMD3(signedPow(c.x, 2.4), signedPow(c.y, 2.4), signedPow(c.z, 2.4)))
    }

    public static func toDisplay(_ lab: SIMD3<Float>) -> SIMD3<Float> {
        let c = toLinear(lab)
        return SIMD3(signedPow(c.x, 1 / 2.4), signedPow(c.y, 1 / 2.4), signedPow(c.z, 1 / 2.4))
    }
}


/// Where Match wants each color of the clip to go (in Oklab): the per-band shift from the clip's to the reference's band
/// means and the chroma ratio, then two protections judged on how much a pixel stands out from its band's average color
/// (so a scene-wide cast is always corrected): clearly colored pixels turn by at most `maxHueCastDegrees` of hue, and
/// skin keeps only `skinKeep` of the change.
struct ColorMatchTargets {
    /// Share of the correction skin hues keep.
    static let skinKeep: Float = 0.2
    /// Largest hue turn of a pixel that stands out from its band's cast by Oklab chroma 0.07 or more.
    static let maxHueCastDegrees: Float = 8

    /// Oklab shift per band (x L, y a, z b) applied after the chroma scale.
    private(set) var shift: [SIMD3<Float>]
    /// Chroma scale (reference colorfulness over the clip's).
    private(set) var chromaScale: Float
    /// Oklab a/b of the clip's band means per unit lightness: the cast a pixel's own color is judged against (a cast
    /// scales with lightness, so a dark pixel carries less of it).
    let clipCast: [SIMD2<Float>]

    /// `calibrateOn`: clip samples on which the plain (unprotected) targets are checked against the reference statistics
    /// and the shifts corrected, so the band means land on the reference's despite Oklab being nonlinear.
    init(clip: ColorMatchStats, reference: ColorMatchStats, calibrateOn samples: [SIMD3<Float>] = []) {
        // The stored chroma counts a cast as color, so the chroma scale starts at 1 and is found by the calibration below,
        // after the band shifts have taken the cast out.
        var k: Float = 1
        let clipLab = clip.bands.map(Oklab.fromDisplay), refLab = reference.bands.map(Oklab.fromDisplay)
        clipCast = clipLab.map { SIMD2($0.y, $0.z) / max($0.x, 0.05) }
        chromaScale = k
        shift = zip(clipLab, refLab).map { c, r in SIMD3(r.x - c.x, r.y - k * c.y, r.z - k * c.z) }
        // The samples are a subset of the measured clip: aim at the reference plus the subset's own offset from the clip.
        guard samples.count >= 16, let base = ColorMatchStats.measure(samples) else { return }
        let baseLab = base.bands.map(Oklab.fromDisplay)
        let wantLab = (0..<3).map { refLab[$0] + baseLab[$0] - clipLab[$0] }
        let wantChroma = clip.chroma > 1e-4 ? reference.chroma * base.chroma / clip.chroma : reference.chroma
        let labs = samples.map(Oklab.fromDisplay)
        for _ in 0..<3 {
            let shown = samples.indices.map { Oklab.toDisplay(plain(labs[$0], display: samples[$0])) }
            guard let s = ColorMatchStats.measure(shown) else { break }
            let got = s.bands.map(Oklab.fromDisplay)
            for b in 0..<3 { shift[b] += wantLab[b] - got[b] }
            if s.chroma > 1e-4 {
                let k2 = min(max(k * wantChroma / s.chroma, 0.25), 4)
                // Keep the band means where they are while the chroma scale changes.
                for b in 0..<3 { shift[b].y -= (k2 - k) * clipLab[b].y; shift[b].z -= (k2 - k) * clipLab[b].z }
                k = k2
                chromaScale = k
            }
        }
    }

    /// How much a color's hue is skin (0...1): Oklab hue 20-75 degrees (soft 5 degree edges) with some chroma.
    static func skinWeight(_ lab: SIMD3<Float>) -> Float {
        let c = (lab.y * lab.y + lab.z * lab.z).squareRoot()
        guard c > 0.02 else { return 0 }
        var h = atan2f(lab.z, lab.y) * 180 / .pi
        if h < 0 { h += 360 }
        typealias S = AutoToneSolver
        return S.smooth(15, 25, h) * (1 - S.smooth(70, 80, h)) * S.smooth(0.02, 0.04, c)
    }

    @inline(__always) static func bands(_ display: SIMD3<Float>) -> SIMD3<Float> {
        ColorMatchStats.bandWeights((ColorMatchStats.luma * simd_clamp3(display, 0, 1.5)).sum())
    }

    /// The band shift and chroma scale alone.
    func plain(_ lab: SIMD3<Float>, display: SIMD3<Float>) -> SIMD3<Float> {
        let bw = Self.bands(display)
        let d = bw.x * shift[0] + bw.y * shift[1] + bw.z * shift[2]
        return SIMD3(lab.x + d.x, chromaScale * lab.y + d.y, chromaScale * lab.z + d.z)
    }

    /// How far a color stands out from its band's cast (Oklab chroma of the difference).
    func standOut(_ lab: SIMD3<Float>, display: SIMD3<Float>) -> Float {
        let bw = Self.bands(display)
        let cast = (bw.x * clipCast[0] + bw.y * clipCast[1] + bw.z * clipCast[2]) * max(lab.x, 0)
        let r = SIMD2(lab.y, lab.z) - cast
        return (r * r).sum().squareRoot()
    }

    /// Target Oklab of a clip color (`lab` = Oklab of `display`).
    func target(_ lab: SIMD3<Float>, display: SIMD3<Float>) -> SIMD3<Float> {
        var t = plain(lab, display: display)
        let rel = standOut(lab, display: display)
        // Hue-cast clamp: a clearly colored object turns by at most `maxHueCastDegrees`; below that the allowed turn
        // widens smoothly towards any angle (pixels that are just the cast take it all).
        let c0 = (lab.y * lab.y + lab.z * lab.z).squareRoot(), c1 = (t.y * t.y + t.z * t.z).squareRoot()
        let hold = AutoToneSolver.smooth(0.04, 0.07, rel)
        if hold > 0, c0 > 1e-4, c1 > 1e-5 {
            let h0 = atan2f(lab.z, lab.y)
            var dh = atan2f(t.z, t.y) - h0
            if dh > .pi { dh -= 2 * .pi } else if dh < -.pi { dh += 2 * .pi }
            let lim = Self.maxHueCastDegrees * .pi / 180
            let allowed = lim + (Float.pi - lim) * (1 - hold)
            if abs(dh) > allowed {
                let h = h0 + (dh > 0 ? allowed : -allowed)
                t.y = c1 * cosf(h); t.z = c1 * sinf(h)
            }
        }
        // Skin keeps a fifth of the change (interpolating keeps the hue turn within the clamp).
        let s = Self.skinWeight(lab) * AutoToneSolver.smooth(0.03, 0.05, rel)
        if s > 0 { t = lab + (1 - (1 - Self.skinKeep) * s) * (t - lab) }
        return t
    }
}
