import Foundation
import Testing
@testable import SQCore

@Suite struct MatteRefineTests {
    @Test func identityLeavesEverythingAlone() {
        let r = MatteRefine.identity
        for c in stride(from: 0.0, through: 1.0, by: 0.125) { #expect(r.tone(c) == c) }
        let m: [Float] = [0, 0.3, 1, 0.5]
        #expect(r.refine(m, width: 2, height: 2) == m)
        #expect(r.isToneIdentity && r.isSpatialIdentity)
    }

    @Test func shrinkPushesTowardsGoneGrowTowardsKept() {
        let shrink = MatteRefine(shrink: 0.5), grow = MatteRefine(shrink: -0.5)
        #expect(shrink.tone(0.5) < 0.5 && grow.tone(0.5) > 0.5)
        #expect(shrink.tone(1) == 1 && shrink.tone(0) == 0)          // full coverage and nothing stay put
        #expect(grow.tone(1) == 1 && grow.tone(0) == 0)
        #expect(MatteRefine(shrink: 1).tone(0.9) < 0.01)             // full shrink drops everything under 0.9
        #expect(MatteRefine(shrink: -1).tone(0.1) > 0.99)            // full grow keeps everything over 0.1
    }

    @Test func contrastPivotsOnMidpoint() {
        let r = MatteRefine(contrast: 1, midpoint: 0.5)
        #expect(abs(r.tone(0.5) - 0.5) < 1e-9)
        #expect(r.tone(0.6) > 0.9 && r.tone(0.4) < 0.1)
        let low = MatteRefine(contrast: 1, midpoint: 0.2)
        #expect(abs(low.tone(0.2) - 0.2) < 1e-9 && low.tone(0.3) > 0.9)
        #expect(MatteRefine(contrast: 0, midpoint: 0.9).tone(0.4) == 0.4)   // midpoint alone does nothing
    }

    @Test func toneIsMonotonic() {
        let r = MatteRefine(shrink: 0.3, contrast: 0.5, midpoint: 0.4)
        var last = -1.0
        for c in stride(from: 0.0, through: 1.0, by: 0.01) { let t = r.tone(c); #expect(t >= last); last = t }
    }

    @Test func erodeRemovesThinLineAndDilateGrowsAPoint() {
        let w = 7, h = 7
        var line = [Float](repeating: 0, count: w * h)
        for y in 0..<h { line[y * w + 3] = 1 }
        #expect(MatteRefine(shrinkPx: 1).refine(line, width: w, height: h).allSatisfy { $0 == 0 })
        var dot = [Float](repeating: 0, count: w * h); dot[3 * w + 3] = 1
        let grown = MatteRefine(shrinkPx: -1).refine(dot, width: w, height: h)
        #expect(grown.reduce(0, +) == 9)
        #expect(grown[2 * w + 2] == 1 && grown[4 * w + 4] == 1 && grown[1 * w + 1] == 0)
    }

    @Test func featherSoftensAStep() {
        let w = 9, h = 1
        var step = [Float](repeating: 0, count: w); for x in 4..<w { step[x] = 1 }
        let f = MatteRefine(feather: 1).refine(step, width: w, height: h)
        #expect(f[2] == 0 && f[6] == 1)                              // away from the edge: unchanged
        #expect(f[3] > 0 && f[3] < 1 && f[4] > 0 && f[4] < 1)        // the edge now ramps
        #expect(f[3] < f[4])
    }

    @Test func spatialThenToneOrder() {
        let w = 9
        var step = [Float](repeating: 0, count: w); for x in 4..<w { step[x] = 1 }
        let out = MatteRefine(contrast: 1, feather: 1).refine(step, width: w, height: 1)
        for i in 1..<w { #expect(out[i] >= out[i - 1]) }
        #expect(out.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    // MARK: Fast spatial path (Magic masks refine a 512 px matte per played frame)

    /// Plain per-tap reference of erode/dilate + box feather + tone, edges clamped (the original loops).
    private func reference(_ r: MatteRefine, _ src: [Float], _ w: Int, _ h: Int) -> [Float] {
        func at(_ a: [Float], _ x: Int, _ y: Int) -> Float { a[min(max(y, 0), h - 1) * w + min(max(x, 0), w - 1)] }
        var m = src
        let k = Int(abs(r.shrinkPx).rounded())
        if k > 0 {
            let erode = r.shrinkPx > 0
            var t = m
            for y in 0..<h { for x in 0..<w { var v = at(m, x, y); for d in -k...k { let o = at(m, x + d, y); v = erode ? min(v, o) : max(v, o) }; t[y * w + x] = v } }
            for y in 0..<h { for x in 0..<w { var v = at(t, x, y); for d in -k...k { let o = at(t, x, y + d); v = erode ? min(v, o) : max(v, o) }; m[y * w + x] = v } }
        }
        let f = Int(r.feather.rounded())
        if f > 0 {
            var t = m
            let n = Float(2 * f + 1)
            for y in 0..<h { for x in 0..<w { var s: Float = 0; for d in -f...f { s += at(m, x + d, y) }; t[y * w + x] = s / n } }
            for y in 0..<h { for x in 0..<w { var s: Float = 0; for d in -f...f { s += at(t, x, y + d) }; m[y * w + x] = s / n } }
        }
        return r.isToneIdentity ? m : m.map { r.toneF($0) }
    }

    @Test func fastRefineMatchesThePerTapReference() {
        let w = 37, h = 23
        var g = SystemRandomNumberGenerator()
        let src = (0..<(w * h)).map { _ in Float.random(in: 0...1, using: &g) }
        for r in [MatteRefine(shrinkPx: 3), MatteRefine(feather: 4, shrinkPx: -2), MatteRefine(feather: 30),
                  MatteRefine(shrink: 0.3, contrast: 0.5, feather: 2, shrinkPx: 40), MatteRefine(feather: 1, shrinkPx: -1)] {
            let fast = r.refine(src, width: w, height: h), ref = reference(r, src, w, h)
            #expect(fast.count == ref.count)
            #expect(zip(fast, ref).allSatisfy { abs($0 - $1) < 1e-4 }, "\(r)")
        }
    }

    /// A 512 x 512 matte with Expansion and Feather refines well within a played frame, even in a debug build.
    @Test func refineOfAPlaybackSizedMatteIsFast() {
        let w = 512, h = 512
        let src = (0..<(w * h)).map { Float(($0 % w) > w / 2 ? 1 : 0) }
        let r = MatteRefine(feather: 6, shrinkPx: -4)
        _ = r.refine(src, width: w, height: h)
        let t0 = ContinuousClock.now
        _ = r.refine(src, width: w, height: h)
        let ms = Double((ContinuousClock.now - t0) / .microseconds(1)) / 1000
        print("PERF MatteRefine.refine 512x512 feather 6 grow 4: \(String(format: "%.2f", ms)) ms")
        #if canImport(Accelerate)
        #expect(ms < 60)
        #else
        #expect(ms < 3000)   // plain-Swift path (Linux), debug build
        #endif
    }
}
