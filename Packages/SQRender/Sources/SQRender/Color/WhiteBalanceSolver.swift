import Foundation
import simd
import SQCore

/// White-balance eyedropper maths. Given a colour sampled from the Program monitor (working-linear Rec.709, i.e. after
/// everything the clip already has) it returns the Temperature and Tint that make that colour neutral. The sample
/// already contains the current Temperature/Tint, so the correction is found as an extra white balance on top of it and
/// added to the current values (mired offsets, which is how Temperature is defined, so the sum is exact for
/// Temperature and a close approximation for Tint).
public enum WhiteBalanceSolver {
    public struct Result: Sendable, Equatable { public var temperature: Float; public var tint: Float }

    public static func solve(picked: SIMD3<Float>, temperature: Float, tint: Float) -> Result? {
        guard picked.x.isFinite, picked.y.isFinite, picked.z.isFinite, picked.y > 1e-4, picked.x >= 0, picked.z >= 0 else { return nil }
        func matrix(_ t: Float, _ n: Float) -> simd_float3x3 {
            var b = BasicCorrection(); b.temperature = t; b.tint = n
            return PreparedBasic(b, gamut: .rec709).wb
        }
        // Error = chromaticity ratios of the corrected pick; zero when r = g = b.
        func err(_ t: Float, _ n: Float) -> SIMD2<Float> {
            let c = matrix(t, n) * picked
            return SIMD2(c.x / c.y - 1, c.z / c.y - 1)
        }
        var t: Float = 0, n: Float = 0
        let h: Float = 0.5
        for _ in 0..<24 {
            let e = err(t, n)
            if simd_length(e) < 1e-5 { break }
            let et = (err(t + h, n) - err(t - h, n)) / (2 * h)
            let en = (err(t, n + h) - err(t, n - h)) / (2 * h)
            let j = simd_float2x2(columns: (et, en))
            guard abs(j.determinant) > 1e-12 else { break }
            let d = j.inverse * e
            t = min(max(t - d.x, -200), 200); n = min(max(n - d.y, -200), 200)
        }
        let rt = min(max(temperature + t, -100), 100), rn = min(max(tint + n, -100), 100)
        return Result(temperature: (rt * 10).rounded() / 10, tint: (rn * 10).rounded() / 10)
    }
}
