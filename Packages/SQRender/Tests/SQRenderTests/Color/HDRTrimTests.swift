import Testing
#if canImport(simd)
import simd
#endif
@testable import SQRender

/// Export HDR to SDR trim: exposure gain and soft gamut compression ahead of the roll-off.
@Suite struct HDRTrimTests {
    @Test func defaultTrimChangesNothing() {
        let tm = ToneMapping()
        let c = SIMD3<Float>(1.4, -0.05, 0.3)
        #expect(tm.trim(c) == c)
        #expect(tm.exposureGain == 1)
    }

    @Test func exposureStopsScaleLightAndAreClamped() {
        var tm = ToneMapping(exposureStops: 1)
        #expect(tm.trim(SIMD3(0.2, 0.1, 0.05)) == SIMD3(0.4, 0.2, 0.1))
        tm.exposureStops = 9
        #expect(tm.exposureStops == 4)
        let dark = ToneMapping(exposureStops: -1)
        #expect(dark.apply(dark.trim(SIMD3(repeating: 0.6))).x < ToneMapping().apply(SIMD3(repeating: 0.6)).x)
    }

    @Test func gamutCompressionPullsNegativesInsideWithoutChangingTheBrightestChannel() {
        let tm = ToneMapping(compressesGamut: true)
        let c = tm.trim(SIMD3<Float>(0.8, -0.2, 0.3))
        #expect(c.x == 0.8)
        #expect(c.y > -0.2)
        #expect(tm.trim(SIMD3(0.5, 0.4, 0.3)) == SIMD3(0.5, 0.4, 0.3))
    }

    @Test func pipelineUsesTheTrimForHDRSourcesOnly() {
        let base = ColorPipeline(source: .hlgBT2020)
        var bright = base
        bright.toneMapping = ToneMapping(exposureStops: 1)
        let px = SIMD3<Float>(0.4, 0.4, 0.4)
        #expect(bright.process(px).x > base.process(px).x)
        var sdr = ColorPipeline(source: .rec709)
        let before = sdr.process(px)
        sdr.toneMapping = ToneMapping(exposureStops: 2)
        #expect(sdr.process(px) == before)
    }
}
