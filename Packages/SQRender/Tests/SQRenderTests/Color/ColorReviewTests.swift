import Foundation
import Testing
import Metal
import simd
import SQCore
@testable import SQRender

// Regression tests for the findings of docs/cloud/review-SQPlayback-SQRender.md that were verified on current main.

@Suite(.enabled(if: GPUTest.device != nil, "no Metal device")) struct VignetteQuarterTurnTests {
    private static func vignette() -> ColorPipeline {
        var v = Vignette(); v.amount = -2.5; v.midpoint = 40; v.roundness = 100; v.feather = 60
        return ColorPipeline(source: .rec709, ops: [.vignette(v)])
    }

    /// Finding 17: the colour chain ran on the unrotated buffer, so a phone clip (1920x1080 buffer shown turned) got a
    /// vignette stretched along the wrong axis. `quarterTurned` makes the vignette follow the shown picture.
    @Test func vignetteOnATurnedBufferFollowsTheUprightPicture() throws {
        let device = GPUTest.device!
        let queue = device.makeCommandQueue()!
        let gpu = try ColorPipelineGPUTests.shared(device)
        let (w, h) = (96, 48)                                           // buffer is wider than tall; shown 48 x 96
        let p = Self.vignette()
        let px = [SIMD3<Float>](repeating: SIMD3(0.5, 0.5, 0.5), count: w * h)
        func run(turned: Bool) throws -> [SIMD3<Float>] {
            let s = GPUTest.makeTexture(device, width: w, height: h, format: .rgba32Float)
            let d = GPUTest.makeTexture(device, width: w, height: h, format: .rgba32Float)
            GPUTest.upload(s, px)
            var err: Error?
            _ = GPUTest.run(queue) { do { try gpu.encode(p, source: s, destination: d, commandBuffer: $0, quarterTurned: turned) } catch { err = error } }
            if let err { throw err }
            return GPUTest.download(d)
        }
        let turned = try run(turned: true), plain = try run(turned: false)
        // CPU reference on the shown picture: buffer pixel (x, y) is shown at ((h - 1 - y), x) of a 48 x 96 picture.
        var worst: Float = 0
        for y in 0..<h {
            for x in 0..<w {
                let uv = SIMD2((Float(h - 1 - y) + 0.5) / Float(h), (Float(x) + 0.5) / Float(w))
                let ref = p.process(SIMD3(0.5, 0.5, 0.5), uv: uv, aspect: Float(h) / Float(w))
                worst = max(worst, simd_reduce_max(simd_abs(turned[y * w + x] - ref)))
            }
        }
        #expect(worst < 1e-4, "turned buffer differs from the upright reference by \(worst)")
        // And it really differs from the unturned chain (the bug): the wide buffer is darkened along the other axis.
        var diff: Float = 0
        for i in 0..<(w * h) { diff = max(diff, simd_reduce_max(simd_abs(turned[i] - plain[i]))) }
        #expect(diff > 0.01, "turning must change the vignette (\(diff))")
    }
}

@Suite struct LayerColorResolverReviewTests {
    let media = UUID()
    func make() -> LayerColorResolver {
        let info = MediaInfo(duration: Time(1, 1), detectedColorSpace: .sLog3SGamut3Cine)
        let m = media
        return LayerColorResolver(lutProvider: nil) { $0 == m ? info : nil }
    }
    func graded(_ tint: Float) -> ClipColor { var c = ClipColor.default; c.effects[0].basic.tint = tint; return c }

    /// Finding 19: a cache miss served the last pipeline built for the MEDIA, i.e. another clip's grade.
    @Test func missServesTheSameClipsPreviousGradeNotAnotherClips() async {
        let r = make()
        let (a, b) = (UUID(), UUID())
        let ca = graded(10), cb = ClipColor.default                      // A has a correction (2 ops), B none (1 op)
        for (c, owner) in [(ca, a), (cb, b)] {
            _ = r.pipeline(for: c, media: media, owner: owner)
            await r.waitUntilIdle()
            _ = r.pipeline(for: c, media: media, owner: owner)           // hit: remembered as this clip's pipeline
        }
        r.invalidate()                                                   // e.g. relink: both miss
        #expect(r.pipeline(for: ca, media: media, owner: a)?.ops.count == 2)
        #expect(r.pipeline(for: cb, media: media, owner: b)?.ops.count == 1)
        await r.waitUntilIdle()
    }

    /// Finding 19: a full cache dropped every entry at once (all layers miss in the same frame).
    @Test func aFullCacheDropsOnlyTheOldestEntries() {
        let r = make()
        for i in 0..<300 { _ = r.pipelineBlocking(for: graded(Float(i) / 10 + 0.05), media: media) }
        #expect(r.cachedCount > 150, "kept \(r.cachedCount) of 256")
    }
}

@Suite struct ColorPassCacheTests {
    /// Finding 20: the GPU passes (sections, curve tables) were rebuilt for every graded layer on every frame.
    @Test func passesAreBuiltOnceAndFollowEdits() {
        var p = ColorPipelineGPUTests.heavy()
        #expect(p.gpuPasses.count == ColorPipelineGPU.passes(for: p).count)
        let before = p.gpuPasses.reduce(0) { $0 + $1.sections.count }
        p.ops.append(.vignette(ColorPipelineGPUTests.vignetteParams()))
        #expect(p.gpuPasses.reduce(0) { $0 + $1.sections.count } == before + 1)

        let n = 2000
        let t0 = ContinuousClock.now
        var sink = 0
        for _ in 0..<n { sink &+= ColorPipelineGPU.passes(for: p).count }
        let rebuild = (ContinuousClock.now - t0) / n
        let t1 = ContinuousClock.now
        for _ in 0..<n { sink &+= p.gpuPasses.count }
        let cached = (ContinuousClock.now - t1) / n
        print("[review] colour passes per graded layer per frame: rebuilt \(rebuild), cached \(cached) (\(sink > 0 ? "" : "?"))")
        #expect(cached < rebuild)
    }
}

@Suite struct WhiteBalanceGamutTests {
    /// Finding 21 is not a bug: a white-balance matrix is a chromatic adaptation in XYZ conjugated with the gamut, so applying
    /// it in a clip's source gamut before the conversion equals applying it in Rec.709 after it (same white point). The
    /// eyedropper's Rec.709 solve therefore neutralises a pick exactly for S-Gamut3.Cine clips too.
    @Test func whiteBalanceIsGamutIndependent() {
        let src = Gamut.sGamut3Cine
        let toSource = Gamut.rec709.matrix(to: src), toRec709 = src.matrix(to: .rec709)
        var b = BasicCorrection(); b.temperature = 50; b.tint = 25
        let inSource = toRec709 * PreparedBasic(b, gamut: src).wb * toSource
        let inRec709 = PreparedBasic(b, gamut: .rec709).wb
        for c in 0..<3 { for r in 0..<3 { #expect(abs(inSource[c][r] - inRec709[c][r]) < 1e-4) } }
    }
}
