import Foundation

// "Send to Pro": the Simple grade's values as the Steps of a Color Graph. The Simple sliders are not primaries, so the
// result is the closest Lift / Gamma / Gain / Offset equivalent, not a pixel-exact match; curves, hue curves and the
// look LUT carry over unchanged. Vignette, Color Range, Blacks, Vibrance, Faded Film and the Creative tints stay in the
// Simple grade (it keeps all its values).

extension ColorStep {
    /// One Simple Color effect as a Step (only its enabled sections count).
    public init(simple e: ColorEffect, label: String, isFirst: Bool) {
        self.init(label: label)
        var p = StepPrimaries()
        var saturation: Float = 1
        func mul(_ t: inout ColorTriple, _ r: Float, _ g: Float, _ b: Float) { t.r *= r; t.g *= g; t.b *= b }
        func add(_ t: inout ColorTriple, _ v: SIMD3<Float>) { t.r += v.x; t.g += v.y; t.b += v.z }

        if e.isEnabled(.basicCorrection) {
            let b = e.basic
            let k = powf(2, b.exposure)
            mul(&p.gain, k, k, k)
            let t = b.temperature / 100 * 0.2, ti = b.tint / 100 * 0.2
            mul(&p.gain, 1 + t, 1 - ti, 1 - t)
            let hi = 1 + b.highlights / 100 * 0.15 + b.whites / 100 * 0.2
            mul(&p.gain, hi, hi, hi)
            add(&p.lift, SIMD3(repeating: b.shadows / 100 * 0.15))
            p.contrast = 1 + b.contrast / 100
            saturation *= b.saturation / 100
            if !isFirst, let l = e.inputLUT, l != .automatic, e.inputLUTIntensity > 0 { lut = l; lutIntensity = e.inputLUTIntensity }
        }
        if e.isEnabled(.creative) {
            saturation *= e.creative.saturation / 100
            if e.creative.hasLook { lut = e.creative.look; lutIntensity = e.creative.intensity }
        }
        if e.isEnabled(.curves) { curves = e.curves; hueCurves = e.hueCurves }
        if e.isEnabled(.wheels) {
            let w = e.wheels
            add(&p.lift, Self.offset(w.shadows) * 0.25 + SIMD3(repeating: w.shadowsLuma / 100 * 0.2))
            let m = Self.offset(w.midtones)
            mul(&p.gamma, powf(2, -m.x), powf(2, -m.y), powf(2, -m.z))
            let mg = powf(2, -w.midtonesLuma / 100)
            mul(&p.gamma, mg, mg, mg)
            let h = Self.offset(w.highlights) * 0.5, hl = 1 + w.highlightsLuma / 100 * 0.5
            mul(&p.gain, hl + h.x, hl + h.y, hl + h.z)
            saturation *= w.saturation / 100
        }
        p.saturation = saturation
        primaries = p.clamped()
    }

    /// Zero-mean RGB offset of a wheel puck (hue in degrees, amount 0...1): tints without changing brightness.
    private static func offset(_ w: WheelValue) -> SIMD3<Float> {
        guard w.amount > 0 else { return .zero }
        var h = w.hue / 360
        h -= floorf(h)
        func ch(_ o: Float) -> Float {
            var x = h + o
            x -= floorf(x)
            return min(max(fabsf(x * 6 - 3) - 1, 0), 1)
        }
        let c = SIMD3(ch(0), ch(2.0 / 3), ch(1.0 / 3))
        return min(w.amount, 1) * (c - SIMD3(repeating: (c.x + c.y + c.z) / 3))
    }
}

extension StepPrimaries {
    /// Every value inside its slider range.
    public func clamped() -> StepPrimaries {
        func c(_ v: Float, _ r: ClosedRange<Float>) -> Float { min(max(v, r.lowerBound), r.upperBound) }
        func t(_ v: ColorTriple, _ r: ClosedRange<Float>) -> ColorTriple { ColorTriple(c(v.r, r), c(v.g, r), c(v.b, r)) }
        var p = self
        p.lift = t(lift, Self.liftRange); p.gamma = t(gamma, Self.gammaRange); p.gain = t(gain, Self.gainRange)
        p.offset = t(offset, Self.offsetRange)
        p.contrast = c(contrast, Self.contrastRange); p.pivot = c(pivot, Self.pivotRange)
        p.saturation = c(saturation, Self.saturationRange)
        return p
    }
}

extension ColorGraph {
    /// An active graph that reproduces `color`'s Simple grade: one Step per Color effect that changes the picture (at
    /// least one), the first effect's Input LUT as the In LUT. The Color effects themselves are not touched.
    public init(simple color: ClipColor) {
        var steps: [ColorStep] = []
        for (i, e) in color.effects.enumerated() {
            let s = ColorStep(simple: e, label: "Step \(steps.count + 1)", isFirst: i == 0)
            if !s.isNeutral { steps.append(s) }
        }
        let first = color.effects.first
        let input: LUTRef? = (first?.isEnabled(.basicCorrection) ?? true) ? first?.inputLUT : nil
        self.init(steps: steps, inputLUT: input)
        isActive = true
    }
}
