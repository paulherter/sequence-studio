import Testing
#if canImport(simd)
import simd
#endif
import SQCore
@testable import SQRender

/// FB-B3: SQCore's Color Wheels model (used by the Color Match solver) is the real wheels maths.
@Suite struct ColorMatchModelTests {
    @Test func wheelsModelMatchesPreparedWheels() {
        var w = ColorWheels()
        w.shadows = WheelValue(hue: 200, amount: 0.5); w.shadowsLuma = -20
        w.midtones = WheelValue(hue: 95, amount: 0.3); w.midtonesLuma = 15
        w.highlights = WheelValue(hue: 30, amount: 0.7); w.highlightsLuma = 10
        w.saturation = 140
        let p = PreparedWheels(w, gamut: .rec709)
        var worst: Float = 0
        for r in stride(from: Float(0), through: 1, by: 0.1) {
            for g in stride(from: Float(0), through: 1, by: 0.1) {
                for b in stride(from: Float(0), through: 1, by: 0.25) {
                    let c = SIMD3<Float>(r, g, b)
                    worst = max(worst, simd_reduce_max(simd_abs(p.apply(c, pre: false) - ColorWheelsModel.apply(c, w))))
                }
            }
        }
        #expect(worst < 1e-3)
    }
}
