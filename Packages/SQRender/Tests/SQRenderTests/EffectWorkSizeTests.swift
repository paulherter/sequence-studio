#if canImport(Metal)
import CoreVideo
import Foundation
import Metal
import SQCore
import Testing
@testable import SQRender

private func bgra(_ w: Int, _ h: Int, _ f: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true,
                                  kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
    precondition(CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess)
    let b = pb!
    CVPixelBufferLockBaseAddress(b, [])
    defer { CVPixelBufferUnlockBaseAddress(b, []) }
    let base = CVPixelBufferGetBaseAddress(b)!, stride = CVPixelBufferGetBytesPerRow(b)
    for y in 0..<h {
        for x in 0..<w {
            let px = (base + y * stride + x * 4).assumingMemoryBound(to: UInt8.self)
            let c = f(x, y)
            px[0] = c.0; px[1] = c.1; px[2] = c.2; px[3] = c.3
        }
    }
    return b
}

private func hint(_ w: Int, _ h: Int) -> VideoTrackInfo {
    VideoTrackInfo(width: w, height: h, codec: "hvc1", bitDepth: 8, chroma: "4:2:0",
                   nominalFrameDuration: Time(1, 25), isVariableFrameRate: false)
}

/// Playback perf: a layer with blur, shadow or a filter that is shown at half size or less runs its effect passes at half
/// its own resolution (the draw into the canvas would average 2 x 2 layer px anyway). Same rule in playback and export.
@Suite struct EffectWorkSizeTests {
    @Test func planHonoursAMinimumFactor() {
        let p = GaussianBlur.Plan(layerWidth: 3840, layerHeight: 2160, sigma: 4, minFactor: 2)
        #expect(p.factor == 2 && p.sigma == 2)
        #expect(p.contentWidth == 1920 && p.contentHeight == 1080)
        // A large sigma already reduces further: the larger factor wins.
        let q = GaussianBlur.Plan(layerWidth: 3840, layerHeight: 2160, sigma: 20, minFactor: 2)
        #expect(q.factor == 4)
        // Default stays as before.
        #expect(GaussianBlur.Plan(layerWidth: 3840, layerHeight: 2160, sigma: 4).factor == 1)
    }

    @Test func halfSizeOnlyWhenShownAtHalfOrLess() {
        let big = SIMD2<Float>(3840, 2160)
        #expect(Compositor.effectWorkFactor(transform: ClipTransform(scale: Vec2(0.5, 0.5)), size: big) == 2)
        #expect(Compositor.effectWorkFactor(transform: ClipTransform(scale: Vec2(0.28, 0.28)), size: big) == 2)
        #expect(Compositor.effectWorkFactor(transform: ClipTransform(scale: Vec2(0.6, 0.6)), size: big) == 1)
        // Stretched on one axis beyond half: full size.
        #expect(Compositor.effectWorkFactor(transform: ClipTransform(scale: Vec2(0.4, 0.7)), size: big) == 1)
        // Tiny layers stay full size.
        #expect(Compositor.effectWorkFactor(transform: ClipTransform(scale: Vec2(0.5, 0.5)), size: SIMD2(100, 60)) == 1)
    }

    /// The color stage and the effect chain flip to half size at the same scale, also for values a Float would round.
    @Test func colourAndEffectsShareTheHalfSizeDecision() {
        for s in [0.5, 0.5.nextUp, 0.5.nextDown, 0.500000001, 0.499999999, 0.25, 0.75] {
            let t = ClipTransform(scale: Vec2(s, s))
            let colour = Compositor.colorWork(canvas: SIMD2(1080, 1920), transform: t, size: SIMD2(3840, 2160),
                                              texture: (3840, 2160), texelsPerNativePixel: 1, quarter: 0, onePass: false)
            let effects = Compositor.effectWorkFactor(transform: t, size: SIMD2(3840, 2160))
            #expect((colour.width == 1920) == (effects == 2), "scale \(s)")
            #expect((effects == 2) == (s <= 0.5), "scale \(s)")
        }
    }

    @Test func onlySofteningPassesWorkAtReducedSize() {
        #expect(Compositor.worksAtReducedSize(EffectSegment(blurAfter: 4)))
        #expect(Compositor.worksAtReducedSize(EffectSegment(shadow: DropShadow())))
        #expect(Compositor.worksAtReducedSize(EffectSegment(filter: .directionalBlur(dx: 30, dy: 0))))
        #expect(!Compositor.worksAtReducedSize(EffectSegment(filter: .sharpen(amount: 50))))
        #expect(!Compositor.worksAtReducedSize(EffectSegment(filter: .noise(amount: 0.2, color: false, clip: true, seed: 1))))
        #expect(!Compositor.worksAtReducedSize(EffectSegment()))       // a mask-only pass keeps its edges
        // C5: distance-field and shadow passes measure in texture px (`pf`), so they work at any size.
        #expect(Compositor.worksAtReducedSize(EffectSegment(filter: .outline(width: 8, color: .zero, softness: 0, position: .outside))))
        #expect(Compositor.worksAtReducedSize(EffectSegment(filter: .longShadow(angle: 90, length: 50, color: .zero, fade: 0, opacity: 1))))
    }

    @Test func chainFactorTakesTheMostDemandingPass() {
        let blur4 = EffectSegment(blurAfter: 4), blur1 = EffectSegment(blurAfter: 1), last = EffectSegment()
        // A blur of 2 layer px or more keeps nothing a half-size picture cannot hold: half size at any scale.
        #expect(Compositor.effectChainFactor([blur4, last], display: 1) == 2)
        #expect(Compositor.effectChainFactor([EffectSegment(blurAfter: 2.9), last], display: 1) == 1)
        #expect(Compositor.effectChainFactor([EffectSegment(blurAfter: 3), last], display: 1) == 2)
        #expect(Compositor.effectChainFactor([blur1, last], display: 1) == 1)
        #expect(Compositor.effectChainFactor([blur1, last], display: 2) == 2)
        #expect(Compositor.effectChainFactor([blur4, last], display: 1, strongBlurHalves: false) == 1)
        // Shadow and smears follow the display size.
        #expect(Compositor.effectChainFactor([EffectSegment(shadow: DropShadow()), last], display: 1) == 1)
        #expect(Compositor.effectChainFactor([EffectSegment(shadow: DropShadow()), last], display: 2) == 2)
        // One full-size pass (Sharpen) keeps the whole chain at full size.
        #expect(Compositor.effectChainFactor([blur4, EffectSegment(filter: .sharpen(amount: 50)), last], display: 2) == 1)
    }

    /// GPU: a blur of 3 px on fine detail at full display size: half working size gives the same picture on a graded
    /// (working-linear) layer; an ungraded layer stays at full size (halving encoded values would darken fine detail).
    /// Run at the threshold (`strongBlurPixels`): a blur keyframed through it steps by at most this difference.
    @Test(arguments: [true, false])
    func strongBlurOnFineDetailStaysCloseAtFullScale(graded: Bool) throws {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return }
        let w = 256, h = 192
        let pb = bgra(w, h) { x, y in ((x + y) % 2 == 0 ? 255 : 0, (x / 3) % 2 == 0 ? 220 : 30, UInt8(y * 255 / (h - 1)), 255) }
        let fx = ClipEffects(segments: [EffectSegment(blurAfter: Compositor.strongBlurPixels), EffectSegment()])
        let f = SequenceFormat(width: 300, height: 240, frameDuration: Time(1, 25))
        let pipe = graded ? ColorPipeline(source: .rec709, ops: [.conversion(nil)]) : nil
        let layer = RenderLayer(content: .frame(pb, colorHint: hint(w, h)), colorPipeline: pipe, effects: fx)
        func render(limit: Bool) throws -> [Float16] {
            let comp = try Compositor(device: dev)
            comp.limitsColorWork = limit
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: f.width, height: f.height, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
            let target = dev.makeTexture(descriptor: d)!
            let cb = q.makeCommandBuffer()!
            try comp.render([layer], format: f, into: target, commandBuffer: cb)
            cb.commit(); cb.waitUntilCompleted()
            var px = [Float16](repeating: 0, count: f.width * f.height * 4)
            target.getBytes(&px, bytesPerRow: f.width * 8, from: MTLRegionMake2D(0, 0, f.width, f.height), mipmapLevel: 0)
            return px
        }
        let full = try render(limit: false), half = try render(limit: true)
        let diffs = zip(full, half).map { Swift.abs(Float($0) - Float($1)) }
        let worst = diffs.max() ?? 0, mean = diffs.reduce(0, +) / Float(diffs.count)
        print("PERF effect half size, blur 3 on fine detail at 100 % (graded \(graded)): worst \(worst), mean \(mean)")
        #expect(worst < 0.02 && mean < 0.002, "worst \(worst), mean \(mean)")
        #expect((full != half) == graded, "the half-size path ran only on the graded layer")
    }

    /// GPU: blur, repeat-edge blur and drop shadow on a layer at 50 % look the same at half working size as at full size.
    @Test(arguments: [0, 1, 2])
    func halfSizeEffectsStayClose(kind: Int) throws {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return }
        let w = 512, h = 288
        let pb = bgra(w, h) { x, y in
            (UInt8(x * 255 / (w - 1)), UInt8(y * 255 / (h - 1)), (x / 16 + y / 16) % 2 == 0 ? 200 : 60, 255)
        }
        let fx: ClipEffects
        switch kind {
        case 0: fx = ClipEffects(segments: [EffectSegment(blurAfter: 6), EffectSegment()])
        case 1: fx = ClipEffects(segments: [EffectSegment(blurAfter: 5, blurRepeatsEdges: true), EffectSegment()])
        default: fx = ClipEffects(segments: [EffectSegment(shadow: DropShadow(color: SIMD3(0, 0, 0), opacity: 0.8, dx: 12, dy: 8, sigma: 6)),
                                            EffectSegment()])
        }
        let f = SequenceFormat(width: 200, height: 240, frameDuration: Time(1, 25))
        var t = ClipTransform(scale: Vec2(0.4, 0.4)); t.position = Vec2(-7, 5)
        let layer = RenderLayer(content: .frame(pb, colorHint: hint(w, h)), transform: t, effects: fx)
        func render(limit: Bool) throws -> [Float16] {
            let comp = try Compositor(device: dev)
            comp.limitsColorWork = limit
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: f.width, height: f.height, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
            let target = dev.makeTexture(descriptor: d)!
            let cb = q.makeCommandBuffer()!
            try comp.render([layer], format: f, into: target, commandBuffer: cb)
            cb.commit(); cb.waitUntilCompleted()
            #expect(cb.error == nil)
            var px = [Float16](repeating: 0, count: f.width * f.height * 4)
            target.getBytes(&px, bytesPerRow: f.width * 8, from: MTLRegionMake2D(0, 0, f.width, f.height), mipmapLevel: 0)
            return px
        }
        let full = try render(limit: false), half = try render(limit: true)
        let diffs = zip(full, half).map { Swift.abs(Float($0) - Float($1)) }
        let worst = diffs.max() ?? 0, mean = diffs.reduce(0, +) / Float(diffs.count)
        print("PERF effect half size kind \(kind): worst \(worst), mean \(mean)")
        // Blurs: the same picture. Shadow: the picture stays sharp, only its rim row (partial coverage) is smoothed by up to
        // one canvas px, the way the draw of a half-size picture filters it (worst about 0.13 on that row, mean 0.002).
        #expect(worst < (kind == 2 ? 0.16 : 0.01) && mean < 0.003, "kind \(kind): worst \(worst), mean \(mean)")
        #expect(full != half, "the half-size path ran")
        #expect(full.contains { $0 > 0.05 }, "something was drawn")
    }

    /// GPU: a graded layer at exactly 50 % (color stage at half resolution, canvas px = 2 x 2 layer px) with 1 px detail:
    /// the 2 x 2 average runs in light through the source's own curve, so the picture matches grading at full size and
    /// averaging there (Rec.709, HLG). Log and PQ sources keep the color stage at full size (`averagesBeforeGrading`).
    /// Source 7 = Rec.709 with a straight alpha checker (premultiplied-correct average).
    @Test(arguments: [0, 1, 2, 3, 4, 5, 6, 7])
    func halfSizeColourAveragesInTheSourcesLight(source: Int) throws {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return }
        let w = 512, h = 288, alpha = source == 7
        let pb = bgra(w, h) { x, y in
            let on = (x + y) % 2 == 0
            let b = UInt8(on ? 170 : 80), g = UInt8(x * 120 / (w - 1) + 60), r = UInt8(on ? 90 : 160)
            if alpha {
                let a: UInt8 = (x / 2 + y) % 2 == 0 ? 255 : 64
                func pm(_ c: UInt8) -> UInt8 { UInt8(Int(c) * Int(a) / 255) }
                return (pm(b), pm(g), pm(r), a)
            }
            return (b, g, r, 255)
        }
        let space = SourceColorSpace.allCases[alpha ? 2 : source]
        let pipe = ColorPipeline(source: space, ops: [.conversion(nil)])
        let f = SequenceFormat(width: 256, height: 144, frameDuration: Time(1, 25))
        let layer = RenderLayer(content: .frame(pb, colorHint: hint(w, h)), transform: ClipTransform(scale: Vec2(0.5, 0.5)),
                                colorPipeline: pipe)
        func render(limit: Bool) throws -> [Float16] {
            let comp = try Compositor(device: dev)
            comp.limitsColorWork = limit
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: f.width, height: f.height, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
            let target = dev.makeTexture(descriptor: d)!
            let cb = q.makeCommandBuffer()!
            try comp.render([layer], format: f, into: target, commandBuffer: cb)
            cb.commit(); cb.waitUntilCompleted()
            #expect(cb.error == nil)
            var px = [Float16](repeating: 0, count: f.width * f.height * 4)
            target.getBytes(&px, bytesPerRow: f.width * 8, from: MTLRegionMake2D(0, 0, f.width, f.height), mipmapLevel: 0)
            return px
        }
        let full = try render(limit: false), half = try render(limit: true)
        let diffs = zip(full, half).map { Swift.abs(Float($0) - Float($1)) }
        let worst = diffs.max() ?? 0, mean = diffs.reduce(0, +) / Float(diffs.count)
        print("PERF color half size, source \(source) (\(space)): worst \(worst), mean \(mean)")
        #expect(mean < 0.005, "source \(space): worst \(worst), mean \(mean)")
        #expect((full != half) == Compositor.averagesBeforeGrading(space), "the half-size path ran only where it is exact")
    }

    @Test func strongBlurGradesAtHalfResolution() {
        func work(_ scale: Double, texelsPerNative: Float = 1, strongBlur: Bool) -> Compositor.ColorWork {
            Compositor.colorWork(canvas: SIMD2(1080, 1920), transform: ClipTransform(scale: Vec2(scale, scale)), size: SIMD2(3840, 2160),
                                 texture: texelsPerNative < 1 ? (1920, 1080) : (3840, 2160), texelsPerNativePixel: texelsPerNative,
                                 quarter: 0, onePass: false, strongBlur: strongBlur)
        }
        #expect(work(0.55, strongBlur: false).width == 3840)
        #expect(work(0.55, strongBlur: true).width == 1920)
        // A half-size proxy is not halved again: its texel is already 2 layer px.
        #expect(work(0.55, texelsPerNative: 0.5, strongBlur: true).width == 1920)
    }

    /// GPU: a graded 4K-like layer at 55 % with a strong blur: grading at half resolution gives the same picture.
    @Test func strongBlurOnGradedLayerStaysClose() throws {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return }
        let w = 512, h = 288
        // Hard-edged stripes every 8 px: a strong curve on hard edges is where grading before or after the 2 x 2 average
        // differs most (a 1 px full-swing checker under this grade differs by mean 0.027, see docs/PLAYBACK-PERF.md).
        let pb = bgra(w, h) { x, y in ((x / 8 + y / 8) % 2 == 0 ? 240 : 20, UInt8(x * 255 / (w - 1)), UInt8(y * 255 / (h - 1)), 255) }
        var basic = BasicCorrection(); basic.exposure = 0.6; basic.contrast = 50; basic.saturation = 150
        let pipe = ColorPipeline(source: .rec709, ops: [.conversion(nil), .basic(basic)])
        let fx = ClipEffects(segments: [EffectSegment(blurAfter: 8), EffectSegment()])
        let f = SequenceFormat(width: 200, height: 320, frameDuration: Time(1, 25))
        let layer = RenderLayer(content: .frame(pb, colorHint: hint(w, h)), transform: ClipTransform(scale: Vec2(0.55, 0.55)),
                                colorPipeline: pipe, effects: fx)
        func render(limit: Bool) throws -> [Float16] {
            let comp = try Compositor(device: dev)
            comp.limitsColorWork = limit
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: f.width, height: f.height, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
            let target = dev.makeTexture(descriptor: d)!
            let cb = q.makeCommandBuffer()!
            try comp.render([layer], format: f, into: target, commandBuffer: cb)
            cb.commit(); cb.waitUntilCompleted()
            var px = [Float16](repeating: 0, count: f.width * f.height * 4)
            target.getBytes(&px, bytesPerRow: f.width * 8, from: MTLRegionMake2D(0, 0, f.width, f.height), mipmapLevel: 0)
            return px
        }
        let full = try render(limit: false), half = try render(limit: true)
        let diffs = zip(full, half).map { Swift.abs(Float($0) - Float($1)) }
        let worst = diffs.max() ?? 0, mean = diffs.reduce(0, +) / Float(diffs.count)
        print("PERF effect half size, graded layer at 55 % with blur 8: worst \(worst), mean \(mean)")
        #expect(worst < 0.03 && mean < 0.003, "worst \(worst), mean \(mean)")
        #expect(full != half, "the half-size path ran")
    }

    /// Perf (printed): a 4K layer with blur at 50 % in a vertical canvas must cost clearly less at half working size.
    @Test func halfSizeBlurIsCheaperFor4KInVerticalCanvas() throws {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return }
        let pb = bgra(3840, 2160) { x, y in (UInt8(x & 255), UInt8(y & 255), 128, 255) }
        let f = SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 30))
        let fx = ClipEffects(segments: [EffectSegment(blurAfter: 5), EffectSegment()])
        let layer = RenderLayer(content: .frame(pb, colorHint: hint(3840, 2160)), transform: ClipTransform(scale: Vec2(0.5, 0.5)),
                                effects: fx)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: f.width, height: f.height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
        let target = dev.makeTexture(descriptor: d)!
        func gpu(limit: Bool) throws -> Double {
            let comp = try Compositor(device: dev)
            comp.limitsColorWork = limit
            var best = Double.infinity
            for _ in 0..<12 {
                let cb = q.makeCommandBuffer()!
                try comp.render([layer], format: f, into: target, commandBuffer: cb)
                cb.commit(); cb.waitUntilCompleted()
                best = min(best, (cb.gpuEndTime - cb.gpuStartTime) * 1000)
            }
            return best
        }
        let full = try gpu(limit: false), half = try gpu(limit: true)
        print("PERF blur 4K@50% in 1080x1920: full size \(full) ms, half size \(half) ms")
        #expect(half < full * 0.8)
    }
}
#endif
