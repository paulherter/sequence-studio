import Testing
#if canImport(simd)
import simd
#endif
import SQCore
@testable import SQRender

/// CREATOR 8: display-referred HDR (HLG, PQ) rolls off to a known peak instead of saturating early.
@Suite struct ToneMappingPeakTests {
    let tm = ToneMapping()

    @Test func hdrSourcesHaveA1000NitPeak() {
        let hlgPeak = try! #require(SourceColorSpace.hlgBT2020.toneMapPeak)
        #expect(abs(hlgPeak - SourceColorSpace.hlgBT2020.decode(SIMD3(repeating: 1)).x) < 1e-4)
        #expect(abs(hlgPeak - 1000 / 203) < 0.01)
        #expect(SourceColorSpace.pqBT2020.toneMapPeak == 1000 / TransferFunctions.pqReferenceWhite)
        for s in [SourceColorSpace.rec709, .sLog3SGamut3Cine, .vLogVGamut, .appleLog, .dLogDGamut] {
            #expect(s.toneMapPeak == nil, "\(s)")
        }
    }

    @Test func peakCurveIdentityBelowKneeAndHitsWhiteAtPeak() {
        let peak: Float = 1000 / 203
        for m: Float in [0, 0.1, 0.5, tm.knee] { #expect(tm.mapMax(m, peak: peak) == m) }
        #expect(abs(tm.mapMax(peak, peak: peak) - 1) < 1e-6)
        #expect(tm.mapMax(peak * 2, peak: peak) == 1)
        // nil peak = the open-ended exponential roll-off (Log sources).
        #expect(tm.mapMax(3, peak: nil) == tm.mapMax(3))
    }

    @Test func peakCurveIsMonotonicAndC1AtKnee() {
        let peak: Float = 1000 / 203
        let h: Float = 1e-3
        let slope = (tm.mapMax(tm.knee + h, peak: peak) - tm.mapMax(tm.knee, peak: peak)) / h
        #expect(abs(slope - 1) < 0.01)
        var last: Float = -1
        for i in 0...1000 {
            let m = Float(i) / 1000 * peak
            let v = tm.mapMax(m, peak: peak)
            #expect(v > last)
            last = v
        }
    }

    @Test func applyPreservesHueAndUsesPeak() {
        let peak: Float = 1000 / 203
        let c = SIMD3<Float>(4, 2, 1)
        let o = tm.apply(c, peak: peak)
        #expect(abs(o.x - tm.mapMax(4, peak: peak)) < 1e-6)
        #expect(abs(o.y / o.x - 0.5) < 1e-6 && abs(o.z / o.x - 0.25) < 1e-6)
        #expect(tm.apply(SIMD3(0.5, 0.2, 0.1), peak: peak) == SIMD3(0.5, 0.2, 0.1))
    }
}
