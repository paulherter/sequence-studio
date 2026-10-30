import Foundation

/// Auto Tone maths (Basic Correction "Auto Tone"), pure and display-free. Input: the luma of the Program frame as shown
/// (BT.709 display-encoded, 0…1, may exceed 1), which already contains the effect's current Basic Correction. The shown
/// statistics are first un-toned through the current values (a gray-axis model of the Basic Correction tone maths in
/// SQRender `PreparedBasic`, kept in sync by a test there), then the new values are solved absolutely from the untouched
/// picture. So pressing Auto Tone twice changes nothing, and the result does not depend on what the sliders held before.
///
/// Solved: Exposure, Contrast, Whites, Blacks. Kept: Shadows, Highlights, Temperature, Tint, Saturation, Vibrance (the
/// white balance part is `neutralSample`, solved in SQRender because it needs the white-balance matrices).
/// Rules: the brightest 0.5 % land at `whiteTarget` at most and the darkest 0.5 % at `blackTarget` at least, so nothing is
/// pushed into clipping; Blacks only deepens and Whites only brightens (no faded or compressed look); Contrast is used
/// only when Whites/Blacks cannot reach, up to `maxContrast`.
public enum AutoToneSolver {
    public static let blackTarget: Float = 0.02
    public static let whiteTarget: Float = 0.96
    /// Median (display-encoded) the exposure step aims for: brightening stops at the upper bound, darkening of a bright,
    /// nearly clipped picture goes down to it.
    public static let midBand: ClosedRange<Float> = 0.38...0.55
    public static let maxContrast: Float = 30
    static let maxDarken: Float = -2
    static let contrastPivot: Float = 0.45

    // MARK: Tone model (gray axis, Basic Correction after the Input LUT)

    // BT.709 OETF with the same constants as SQRender `TransferFunctions`.
    static let alpha: Float = 1.09929682680944, beta: Float = 0.018053968510807
    static func oetf(_ l: Float) -> Float { l < beta ? 4.5 * l : alpha * powf(l, 0.45) - (alpha - 1) }
    static func inverseOETF(_ v: Float) -> Float { v < 4.5 * beta ? v / 4.5 : powf((v + alpha - 1) / alpha, 1 / 0.45) }

    @inline(__always) static func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// A gray of display value `y` through the tone part of `b` without Whites/Blacks (the value the levels see).
    static func preLevels(_ y: Float, _ b: BasicCorrection) -> Float {
        func clamp(_ v: Float, _ lo: Float, _ hi: Float) -> Float { min(max(v, lo), hi) }
        var t = y
        let ev = clamp(b.exposure, -5, 5)
        if ev != 0 { t = oetf(inverseOETF(t) * exp2f(ev)) }
        let con = clamp(b.contrast, -100, 100) / 100
        if con != 0 { t = contrastPivot + (t - contrastPivot) * (con >= 0 ? 1 + 0.8 * con : 1 + 0.7 * con) }
        let s = clamp(b.shadows, -100, 100) / 100
        if s != 0 { t *= 1 + (s > 0 ? 1.4 * s : s) * (1 - smooth(0, 0.6, t)) }
        let h = clamp(b.highlights, -100, 100) / 100
        if h != 0 { t += 0.3 * h * smooth(0.3, 1.0, t) }
        return t
    }

    static func levels(_ b: BasicCorrection) -> (bp: Float, wp: Float) {
        let w = min(max(b.whites, -100), 100) / 100, k = min(max(b.blacks, -100), 100) / 100
        return (-0.1 * k, 1 - 0.2 * w)
    }

    /// A gray of display value `y` through Basic Correction's tone maths (Temperature/Tint/Saturation do not move grays).
    public static func tone(_ y: Float, _ b: BasicCorrection) -> Float {
        if b.model == .lumetri { return BasicToneCurves.tone(y, b) }
        let (bp, wp) = levels(b)
        return (preLevels(y, b) - bp) / (wp - bp)
    }

    /// Inverse of `tone` (it is monotone): the display value before the Basic Correction.
    public static func untone(_ y: Float, _ b: BasicCorrection) -> Float {
        if b.exposure == 0, b.contrast == 0, b.shadows == 0, b.highlights == 0, b.whites == 0, b.blacks == 0 { return y }
        var lo: Float = -1, hi: Float = 8
        for _ in 0..<48 {
            let m = (lo + hi) / 2
            if tone(m, b) < y { lo = m } else { hi = m }
        }
        return (lo + hi) / 2
    }

    // MARK: When it can measure

    /// Why Auto Tone cannot solve this Color effect from the shown picture (nil = it can). The tone model is the Basic
    /// Correction on a Rec.709 picture with nothing after it, so a Log/HDR source (its Basic Correction runs before the
    /// conversion), an Input LUT, a switched-off Basic Correction, or an active later section would be measured but not
    /// inverted, and the result would be wrong and change again on a second press. The host also blocks other visible
    /// layers and further Color effects.
    public static func blockReason(effect e: ColorEffect, source: ColorSpaceID) -> String? {
        if source != .rec709 {
            return "Auto Tone works on Rec. 709 footage. This clip is interpreted as \(source.displayName); grade it by hand."
        }
        if !e.isEnabled(.basicCorrection) { return "Turn on Basic to use Auto Tone." }
        if !e.inputLUTIsNeutral { return "Auto Tone cannot measure through the Input LUT. Remove the LUT or grade by hand." }
        for k in [ColorSectionKind.creative, .curves, .wheels, .vignette] where e.isEnabled(k) && !e.isNeutral(k) {
            return "Auto Tone would measure \(k.title) too. Reset or switch off \(k.title) first."
        }
        return nil
    }

    // MARK: Solve

    /// New Basic Correction (only Exposure, Contrast, Whites, Blacks differ from `current`), or nil when there is nothing
    /// to do (too few samples, a flat frame, or the values already are what Auto Tone would set).
    /// `linearGain`: how much a white-balance change made in the same step brightens grays (linear, before Exposure);
    /// the picture is solved as if it were already applied.
    public static func solveTone(luma: [Float], current: BasicCorrection, linearGain: Float = 1) -> BasicCorrection? {
        if current.model == .lumetri { return solveLumetri(luma: luma, current: current, linearGain: linearGain) }
        let v = luma.filter(\.isFinite).sorted()
        guard v.count >= 16 else { return nil }
        let gain = linearGain.isFinite && linearGain > 0 ? linearGain : 1
        func pct(_ p: Float) -> Float {
            let y = untone(v[Int(Float(v.count - 1) * p)], current)
            return gain == 1 ? y : oetf(inverseOETF(y) * gain)
        }
        let lo = pct(0.005), mid = pct(0.5), hi = pct(0.995)
        guard hi - lo >= 0.05 else { return nil }

        // Exposure (linear gain): brighten so the bright end reaches white, but not past the midtone band; darken only a
        // bright picture that already touches white.
        func ev(_ from: Float, to target: Float) -> Float {
            log2f(inverseOETF(target) / max(inverseOETF(max(from, 1e-4)), 1e-6))
        }
        var e: Float = 0
        var darkened = false
        if hi < whiteTarget {
            e = max(0, min(ev(hi, to: whiteTarget), mid < midBand.upperBound ? ev(mid, to: midBand.upperBound) : 0))
        } else if mid > midBand.upperBound {
            e = max(ev(mid, to: midBand.upperBound), maxDarken)
            darkened = true
        }
        e = min(max(e, -5), 5)

        var b = current
        b.exposure = e; b.contrast = 0; b.whites = 0; b.blacks = 0

        // Levels for a contrast k: lo -> blackTarget (Blacks deepens only), hi -> whiteTarget (Whites brightens only).
        // feasible: within the slider reach without clamping.
        func solveLevels(k: Float) -> (bp: Float, wp: Float, feasible: Bool) {
            var t = b; t.contrast = (k - 1) / 0.8 * 100
            let l = preLevels(lo, t), h = preLevels(hi, t)
            let needLo = l > blackTarget, needHi = !darkened && h < whiteTarget
            var bp: Float = 0, wp: Float = 1
            if needLo && needHi {
                let scale = (h - l) / (whiteTarget - blackTarget)
                bp = l - blackTarget * scale; wp = bp + scale
            } else if needLo {
                bp = (l - blackTarget) / (1 - blackTarget)
            } else if needHi {
                wp = h / whiteTarget
            }
            let feasible = bp <= 0.1 + 1e-6 && wp >= 0.8 - 1e-6
            // Out of reach: deepen as far as Blacks goes, then place the bright end with the clamped black point (both
            // ends then land inside the targets, never beyond).
            bp = min(bp, 0.1)
            if needHi { wp = bp + (h - bp) / whiteTarget }
            wp = min(max(wp, 0.8), 1)
            return (bp, wp, feasible)
        }

        var k: Float = 1
        var sol = solveLevels(k: 1)
        if !sol.feasible, !darkened {
            // Contrast alone must not push either end past its target (it spreads around the pivot).
            func inside(_ k: Float) -> Bool {
                var t = b; t.contrast = (k - 1) / 0.8 * 100
                return preLevels(lo, t) >= blackTarget && preLevels(hi, t) <= whiteTarget
            }
            var kMax = 1 + 0.8 * maxContrast / 100
            if !inside(kMax) {
                var a: Float = 1, z = kMax
                for _ in 0..<30 { let m = (a + z) / 2; if inside(m) { a = m } else { z = m } }
                kMax = a
            }
            if solveLevels(k: kMax).feasible {
                var a: Float = 1, z = kMax
                for _ in 0..<30 { let m = (a + z) / 2; if solveLevels(k: m).feasible { z = m } else { a = m } }
                k = z
            } else {
                k = kMax
            }
            sol = solveLevels(k: k)
        }

        b.exposure = (e * 100).rounded() / 100
        b.contrast = (min(max((k - 1) / 0.8 * 100, 0), maxContrast) * 10).rounded() / 10
        b.blacks = (min(max(-sol.bp / 0.1 * 100, -100), 0) * 10).rounded() / 10
        b.whites = (min(max((1 - sol.wp) / 0.2 * 100, 0), 100) * 10).rounded() / 10

        let same = abs(b.exposure - current.exposure) < 0.02 && abs(b.contrast - current.contrast) < 0.5
            && abs(b.whites - current.whites) < 0.5 && abs(b.blacks - current.blacks) < 0.5
        return same ? nil : b
    }

    /// `solveTone` for the Lumetri maths: the same rules, solved numerically through `BasicToneCurves` (Whites is a gain,
    /// Blacks a low hinge, Contrast an end-fixed S-curve, Exposure rolls into white).
    static func solveLumetri(luma: [Float], current: BasicCorrection, linearGain: Float) -> BasicCorrection? {
        typealias C = BasicToneCurves
        let v = luma.filter(\.isFinite).sorted()
        guard v.count >= 16 else { return nil }
        let gain = linearGain.isFinite && linearGain > 0 ? linearGain : 1
        func pct(_ p: Float) -> Float {
            let y = untone(v[Int(Float(v.count - 1) * p)], current)
            return gain == 1 ? y : oetf(inverseOETF(y) * gain)
        }
        let lo = pct(0.005), mid = pct(0.5), hi = pct(0.995)
        guard hi - lo >= 0.05 else { return nil }

        /// Increasing f on [a, z]: the x where f(x) = target, clamped to the ends.
        func solve(_ a: Float, _ z: Float, _ target: Float, _ f: (Float) -> Float) -> Float {
            if f(a) >= target { return a }
            if f(z) <= target { return z }
            var a = a, z = z
            for _ in 0..<40 { let m = (a + z) / 2; if f(m) < target { a = m } else { z = m } }
            return (a + z) / 2
        }
        func exposed(_ y: Float, _ ev: Float) -> Float { ev == 0 ? y : oetf(C.exposure(inverseOETF(y), ev)) }

        var e: Float = 0
        var darkened = false
        if hi < whiteTarget {
            let toWhite = solve(0, 5, whiteTarget) { exposed(hi, $0) }
            let toMid = mid < midBand.upperBound ? solve(0, 5, midBand.upperBound) { exposed(mid, $0) } : 0
            e = max(0, min(toWhite, toMid))
            e = (e * 100).rounded(.down) / 100
        } else if mid > midBand.upperBound {
            e = max(solve(maxDarken, 0, midBand.upperBound) { exposed(mid, $0) }, maxDarken)
            e = (e * 100).rounded() / 100
            darkened = true
        }

        var b = current
        b.exposure = e; b.contrast = 0; b.whites = 0; b.blacks = 0
        let eLo = exposed(lo, e), eHi = exposed(hi, e)
        func shown(_ y: Float, _ t: BasicCorrection) -> Float { C.toneAfterExposure(y, t) }

        // Whites (0...100) brings the bright end to the white target, Blacks (-100...0) the dark end to the black target;
        // each barely touches the other's end, so a few alternating solves settle. feasible: both reached in range.
        func levels(contrast c: Float) -> (whites: Float, blacks: Float, feasible: Bool) {
            var t = b; t.contrast = c
            let needLo = shown(eLo, t) > blackTarget
            let needHi = !darkened && shown(eHi, t) < whiteTarget
            var w: Float = 0, k: Float = 0
            for _ in 0..<6 {
                if needHi {
                    w = solve(0, 100, whiteTarget) { var u = t; u.whites = $0; u.blacks = k; return shown(eHi, u) }
                }
                if needLo {
                    k = -solve(0, 100, -blackTarget) { var u = t; u.whites = w; u.blacks = -$0; return -shown(eLo, u) }
                }
            }
            var u = t; u.whites = w; u.blacks = k
            let okHi = !needHi || abs(shown(eHi, u) - whiteTarget) < 1e-3
            let okLo = !needLo || abs(shown(eLo, u) - blackTarget) < 1e-3
            return (w, k, okHi && okLo)
        }

        var con: Float = 0
        var sol = levels(contrast: 0)
        if !sol.feasible, !darkened {
            // Contrast alone must not push either end past its target.
            func inside(_ c: Float) -> Bool {
                var t = b; t.contrast = c
                return shown(eLo, t) >= blackTarget && shown(eHi, t) <= whiteTarget
            }
            var cMax = maxContrast
            if !inside(cMax) {
                var a: Float = 0, z = cMax
                for _ in 0..<30 { let m = (a + z) / 2; if inside(m) { a = m } else { z = m } }
                cMax = a
            }
            if levels(contrast: cMax).feasible {
                var a: Float = 0, z = cMax
                for _ in 0..<30 { let m = (a + z) / 2; if levels(contrast: m).feasible { z = m } else { a = m } }
                con = z
            } else {
                con = cMax
            }
            con = (con * 10).rounded(.down) / 10
            sol = levels(contrast: con)
        }

        b.contrast = con
        // Round towards no clipping: Whites down, Blacks up (both towards 0).
        b.whites = (min(max(sol.whites, 0), 100) * 10).rounded(.down) / 10
        b.blacks = (min(max(sol.blacks, -100), 0) * 10).rounded(.up) / 10

        let same = abs(b.exposure - current.exposure) < 0.02 && abs(b.contrast - current.contrast) < 0.5
            && abs(b.whites - current.whites) < 0.5 && abs(b.blacks - current.blacks) < 0.5
        return same ? nil : b
    }

    // MARK: White balance sample

    /// Conservative gray-world white balance: the mean of the near-gray mid-tone pixels (working-linear Rec.709, as
    /// shown), to be made neutral by the white-balance solver. nil when the frame is already neutral (so a second press
    /// changes nothing), when the cast is strong (likely intended: sunset, tungsten mood) or when too few pixels are gray.
    public static func neutralSample(_ linear: [SIMD3<Float>]) -> SIMD3<Float>? {
        var sum = SIMD3<Float>(repeating: 0)
        var n = 0, valid = 0
        for p in linear where p.x.isFinite && p.y.isFinite && p.z.isFinite {
            valid += 1
            let y = oetf(max(0.2126 * p.x + 0.7152 * p.y + 0.0722 * p.z, 0))
            guard y >= 0.1, y <= 0.9 else { continue }
            let mx = max(p.x, p.y, p.z), mn = min(p.x, p.y, p.z)
            guard mn >= 0, mx > 0, (mx - mn) / mx < 0.3 else { continue }
            sum += p; n += 1
        }
        guard n >= 16, Float(n) >= 0.1 * Float(valid), sum.y > 0 else { return nil }
        let mean = sum / Float(n)
        let cast = max(abs(mean.x / mean.y - 1), abs(mean.z / mean.y - 1))
        guard cast >= 0.015, cast <= 0.25 else { return nil }
        return mean
    }
}
