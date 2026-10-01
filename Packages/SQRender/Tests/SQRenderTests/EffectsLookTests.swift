import CoreVideo
import Foundation
import Metal
import SQCore
import Testing
@testable import SQRender

// MARK: Helpers

private func makeBGRA(_ w: Int, _ h: Int, _ f: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> CVPixelBuffer {
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

private func fmt(_ w: Int, _ h: Int) -> SequenceFormat { SequenceFormat(width: w, height: h, frameDuration: Time(1, 25)) }

private func target(_ d: MTLDevice, _ w: Int, _ h: Int) -> MTLTexture {
    let t = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
    t.usage = [.renderTarget, .shaderRead]; t.storageMode = .shared
    return d.makeTexture(descriptor: t)!
}

private func setup() -> (MTLDevice, MTLCommandQueue, Compositor)? {
    guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue(), let c = try? Compositor(device: d) else { return nil }
    return (d, q, c)
}

@discardableResult
private func render(_ comp: Compositor, _ q: MTLCommandQueue, _ layers: [RenderLayer], _ w: Int, _ h: Int, into t: MTLTexture) throws -> MTLCommandBuffer {
    let cb = q.makeCommandBuffer()!
    try comp.render(layers, format: fmt(w, h), into: t, commandBuffer: cb)
    cb.commit(); cb.waitUntilCompleted()
    #expect(cb.error == nil)
    return cb
}

private func readAll(_ t: MTLTexture) -> [SIMD4<Float>] {
    var px = [Float16](repeating: 0, count: t.width * t.height * 4)
    t.getBytes(&px, bytesPerRow: t.width * 8, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
    var out: [SIMD4<Float>] = []
    out.reserveCapacity(t.width * t.height)
    for i in 0..<(t.width * t.height) {
        let r = Float(px[i * 4]), g = Float(px[i * 4 + 1]), b = Float(px[i * 4 + 2]), a = Float(px[i * 4 + 3])
        out.append(SIMD4<Float>(r, g, b, a))
    }
    return out
}

private func lin709(_ e: Float) -> Float {
    e < 0.081242858 ? e / 4.5 : powf((e + 0.09929682680944) / 1.09929682680944, 1 / 0.45)
}

/// Linear premultiplied value of an 8-bit BGRA pixel (what the compositor makes of it).
private func linear(_ c: (UInt8, UInt8, UInt8, UInt8)) -> SIMD4<Float> {
    let a = Float(c.3) / 255
    return SIMD4(lin709(Float(c.2) / 255) * a, lin709(Float(c.1) / 255) * a, lin709(Float(c.0) / 255) * a, a)
}

private func layer(_ pb: CVPixelBuffer, _ w: Int, _ h: Int, effects: ClipEffects = .none, blend: BlendMode = .normal) -> RenderLayer {
    RenderLayer(content: .frame(pb, colorHint: hint(w, h)), effects: effects, blendMode: blend)
}

private func near(_ a: SIMD4<Float>, _ e: SIMD4<Float>, _ tol: Float, _ note: String = "") {
    for i in 0..<4 { #expect(abs(a[i] - e[i]) <= tol, "\(note) ch\(i): got \(a[i]) want \(e[i])") }
}

// MARK: Blend modes

@Suite struct BlendModeMathTests {
    @Test func knownValuesOnTwoPixels() {
        let d1 = SIMD4<Float>(0.25, 0.5, 1.0, 1), s1 = SIMD4<Float>(0.5, 0.5, 0.5, 1)
        near(BlendModes.blend(.multiply, source: s1, destination: d1), SIMD4(0.125, 0.25, 0.5, 1), 1e-6)
        near(BlendModes.blend(.screen, source: s1, destination: d1), SIMD4(0.625, 0.75, 1.0, 1), 1e-6)
        near(BlendModes.blend(.add, source: s1, destination: d1), SIMD4(0.75, 1.0, 1.5, 1), 1e-6)
        near(BlendModes.blend(.overlay, source: s1, destination: d1), SIMD4(0.25, 0.5, 1.0, 1), 1e-6)
        near(BlendModes.blend(.normal, source: s1, destination: d1), s1, 1e-6)
        // Second pixel: black and white behave as in every editor.
        let black = SIMD4<Float>(0, 0, 0, 1), white = SIMD4<Float>(1, 1, 1, 1)
        near(BlendModes.blend(.multiply, source: white, destination: d1), d1, 1e-6)
        near(BlendModes.blend(.multiply, source: black, destination: d1), black, 1e-6)
        near(BlendModes.blend(.screen, source: black, destination: d1), d1, 1e-6)
        near(BlendModes.blend(.screen, source: white, destination: d1), white, 1e-6)
    }

    @Test func halfCoverageSourceMixesWithTheBackdrop() {
        let d = SIMD4<Float>(0.4, 0.4, 0.4, 1), s = SIMD4<Float>(0.25, 0.25, 0.25, 0.5)   // premultiplied: colour 0.5 at 50 %
        // Multiply: 0.5 * (0.5 * 0.4) + 0.5 * 0.4 = 0.3
        near(BlendModes.blend(.multiply, source: s, destination: d), SIMD4(0.3, 0.3, 0.3, 1), 1e-6)
        // Over a transparent backdrop every mode leaves the source alone.
        for m in BlendMode.allCases { near(BlendModes.blend(m, source: s, destination: .zero), s, 1e-6, "\(m)") }
    }
}

@Suite struct BlendModeGPUTests {
    @Test func gpuMatchesCPUForEveryMode() throws {
        guard let (dev, q, comp) = setup() else { return }
        let backdrop: [(UInt8, UInt8, UInt8, UInt8)] = [(200, 128, 64, 255), (40, 200, 220, 255)]
        let source: [(UInt8, UInt8, UInt8, UInt8)] = [(100, 180, 90, 255), (230, 60, 10, 255)]
        let bg = makeBGRA(2, 1) { x, _ in backdrop[x] }
        let sp = makeBGRA(2, 1) { x, _ in source[x] }
        for mode in BlendMode.allCases {
            let t = target(dev, 2, 1)
            try render(comp, q, [layer(bg, 2, 1), layer(sp, 2, 1, blend: mode)], 2, 1, into: t)
            let out = readAll(t)
            for x in 0..<2 {
                let want = BlendModes.blend(mode, source: linear(source[x]), destination: linear(backdrop[x]))
                near(out[x], want, 0.004, "\(mode) px\(x)")
            }
        }
    }

    @Test func gpuMatchesCPUWithPartialAlpha() throws {
        guard let (dev, q, comp) = setup() else { return }
        let backdrop: (UInt8, UInt8, UInt8, UInt8) = (150, 100, 60, 255)
        // A still with straight alpha 50 %: BGRA buffers are premultiplied, so store colour * alpha.
        let src: (UInt8, UInt8, UInt8, UInt8) = (60, 90, 120, 128)
        let bg = makeBGRA(1, 1) { _, _ in backdrop }
        let sp = makeBGRA(1, 1) { _, _ in src }
        for mode in [BlendMode.multiply, .screen, .overlay, .add] {
            let t = target(dev, 1, 1)
            try render(comp, q, [layer(bg, 1, 1), layer(sp, 1, 1, blend: mode)], 1, 1, into: t)
            // The compositor un-premultiplies the buffer, linearises, and premultiplies again.
            let a = Float(src.3) / 255
            let straight = SIMD3(Float(src.2), Float(src.1), Float(src.0)) / 255 / a
            let s = SIMD4(lin709(straight.x) * a, lin709(straight.y) * a, lin709(straight.z) * a, a)
            near(readAll(t)[0], BlendModes.blend(mode, source: s, destination: linear(backdrop)), 0.006, "\(mode)")
        }
    }

    @Test func normalIsUntouchedByTheBlendPath() throws {
        guard let (dev, q, comp) = setup() else { return }
        let bg = makeBGRA(4, 4) { _, _ in (10, 20, 30, 255) }
        let sp = makeBGRA(4, 4) { x, _ in (UInt8(x * 60), 90, 120, 255) }
        let a = target(dev, 4, 4), b = target(dev, 4, 4)
        try render(comp, q, [layer(bg, 4, 4), layer(sp, 4, 4)], 4, 4, into: a)
        try render(comp, q, [layer(bg, 4, 4), layer(sp, 4, 4, blend: .normal)], 4, 4, into: b)
        #expect(readAll(a) == readAll(b))
    }
}

// MARK: Crop

@Suite struct CropTests {
    @Test func cpuMaskKeepsTheRectangle() {
        var px = [SIMD4<Float>](repeating: SIMD4(1, 1, 1, 1), count: 8 * 4)
        CropMask.apply(&px, width: 8, height: 4, crop: CropInsets(left: 0.25, top: 0.25, right: 0, bottom: 0), cornerRadius: 0)
        #expect(px[0].w == 0 && px[1].w == 0)                     // x < 2: cropped
        #expect(px[8 + 1].w == 0)                                 // y < 1: cropped
        #expect(px[8 + 2].w == 1 && px[3 * 8 + 7].w == 1)
    }

    @Test func identityCropTouchesNothing() {
        var px = [SIMD4<Float>](repeating: SIMD4(0.3, 0.2, 0.1, 1), count: 16)
        let before = px
        CropMask.apply(&px, width: 4, height: 4, crop: .none, cornerRadius: 0)
        #expect(px == before)
    }

    @Test func gpuMatchesCPU() throws {
        guard let (dev, q, comp) = setup() else { return }
        let w = 64, h = 36
        let color: (UInt8, UInt8, UInt8, UInt8) = (80, 160, 220, 255)
        let pb = makeBGRA(w, h) { _, _ in color }
        let crop = CropInsets(left: 0.25, top: 0.25, right: 0.125, bottom: 0)       // 16 px, 9 px, 8 px: pixel aligned
        var fx = ClipEffects()
        fx.pre.crop = crop
        let t = target(dev, w, h)
        try render(comp, q, [layer(pb, w, h, effects: fx)], w, h, into: t)
        var want = [SIMD4<Float>](repeating: linear(color), count: w * h)
        CropMask.apply(&want, width: w, height: h, crop: crop, cornerRadius: 0)
        let got = readAll(t)
        var worst: Float = 0
        for i in 0..<(w * h) { for c in 0..<3 { let e = abs(got[i][c] - want[i][c]); if e > worst { worst = e; if e > 0.004 { print("CROPDBG", i % w, i / w, got[i], want[i]) } } } }      // over opaque black: compare colour
        #expect(worst < 0.004, "worst channel error \(worst)")
        #expect(got[20 * w + 8].x == 0)            // inside the cropped left strip
        #expect(got[20 * w + 20].x > 0.1)
    }

    @Test func identityEffectsAreBitIdenticalToNone() throws {
        guard let (dev, q, comp) = setup() else { return }
        let pb = makeBGRA(32, 18) { x, y in (UInt8(x * 7), UInt8(y * 13), 100, 255) }
        let a = target(dev, 32, 18), b = target(dev, 32, 18)
        try render(comp, q, [layer(pb, 32, 18)], 32, 18, into: a)
        try render(comp, q, [layer(pb, 32, 18, effects: ClipEffects(pre: EffectMasks(), blur: 0, post: EffectMasks()))], 32, 18, into: b)
        #expect(readAll(a) == readAll(b))
    }

    @Test func totalCropDrawsNothing() throws {
        guard let (dev, q, comp) = setup() else { return }
        let pb = makeBGRA(8, 8) { _, _ in (255, 255, 255, 255) }
        var fx = ClipEffects()
        fx.pre.crop = CropInsets(left: 0.5, top: 0, right: 0.5, bottom: 0)
        let t = target(dev, 8, 8)
        try render(comp, q, [layer(pb, 8, 8, effects: fx)], 8, 8, into: t)
        #expect(readAll(t).allSatisfy { $0.x == 0 && $0.y == 0 && $0.z == 0 })
    }

    @Test func cropAndRoundedCornersCompose() throws {
        guard let (dev, q, comp) = setup() else { return }
        let w = 64, h = 64
        let pb = makeBGRA(w, h) { _, _ in (255, 255, 255, 255) }
        var fx = ClipEffects()
        fx.pre = EffectMasks(crop: CropInsets(left: 0.25, top: 0, right: 0.25, bottom: 0), cornerRadius: 16)
        let t = target(dev, w, h)
        try render(comp, q, [layer(pb, w, h, effects: fx)], w, h, into: t)
        let out = readAll(t)
        #expect(out[32 * w + 32].x > 0.99)                 // middle kept
        #expect(out[32 * w + 8].x < 0.01)                  // cropped strip
        #expect(out[0 * w + 16].x < 0.5)                   // rounded corner of the cropped rectangle, not of the layer
    }
}

// MARK: Gaussian blur

@Suite struct GaussianBlurTests {
    @Test func kernelIsNormalisedAndSymmetric() {
        let w = GaussianBlur.weights(sigma: 4)
        #expect(abs(w.reduce(0, +) - 1) < 1e-5)
        #expect(w.count == 2 * 12 + 1)
        for i in 0..<w.count { #expect(abs(w[i] - w[w.count - 1 - i]) < 1e-7) }
    }

    @Test func zeroSigmaIsIdentity() {
        let px = (0..<20).map { SIMD4<Float>(Float($0), 0, 0, 1) }
        #expect(GaussianBlur.blur(px, width: 5, height: 4, sigma: 0) == px)
    }

    @Test func blurKeepsTotalEnergyAwayFromTheEdges() {
        var px = [SIMD4<Float>](repeating: .zero, count: 41 * 41)
        px[20 * 41 + 20] = SIMD4(1, 1, 1, 1)
        let out = GaussianBlur.blur(px, width: 41, height: 41, sigma: 2)
        let sum = out.reduce(SIMD4<Float>.zero, +)
        #expect(abs(sum.x - 1) < 1e-4)
        #expect(out[20 * 41 + 20].x < 1 && out[20 * 41 + 20].x > out[20 * 41 + 24].x)
    }

    @Test func planShrinksLargeSigmaAndPadsTheMargin() {
        let small = GaussianBlur.Plan(layerWidth: 1920, layerHeight: 1080, sigma: 6)
        #expect(small.factor == 1 && small.radius == 18)
        #expect(small.textureWidth == 1920 + 36)
        let big = GaussianBlur.Plan(layerWidth: 1920, layerHeight: 1080, sigma: 100)
        #expect(big.factor == 17)
        #expect(big.sigma <= 6 && big.radius <= 18)
        #expect(big.outputWidth >= 1920 + 2 * 3 * 100 - 2 * Float(big.factor))      // margin covers 3 sigma
    }

    @Test func gpuMatchesCPU() throws {
        guard let (dev, q, comp) = setup() else { return }
        let w = 48, h = 40
        // A bright block on dark: opaque everywhere, so the blur only mixes colour inside the layer.
        let src: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8) = { x, y in
            (x >= 16 && x < 32 && y >= 12 && y < 28) ? (240, 220, 200, 255) : (20, 30, 40, 255)
        }
        let pb = makeBGRA(w, h, src)
        var fx = ClipEffects(); fx.blur = 3
        let t = target(dev, w, h)
        try render(comp, q, [layer(pb, w, h, effects: fx)], w, h, into: t)
        var cpu = [SIMD4<Float>](repeating: .zero, count: w * h)
        for y in 0..<h { for x in 0..<w { cpu[y * w + x] = linear(src(x, y)) } }
        let want = GaussianBlur.blur(cpu, width: w, height: h, sigma: 3)
        let got = readAll(t)
        var worst: Float = 0
        for i in 0..<(w * h) { for c in 0..<3 { worst = max(worst, abs(got[i][c] - want[i][c])) } }
        #expect(worst < 0.01, "worst channel error \(worst)")
    }

    @Test func blurSpreadsBeyondTheLayerEdge() throws {
        guard let (dev, q, comp) = setup() else { return }
        // A 16 x 16 white layer centred on a 48 x 48 canvas: the halo reaches outside the picture.
        let pb = makeBGRA(16, 16) { _, _ in (255, 255, 255, 255) }
        var fx = ClipEffects(); fx.blur = 4
        let t = target(dev, 48, 48)
        try render(comp, q, [layer(pb, 16, 16, effects: fx)], 48, 48, into: t)
        let out = readAll(t)
        #expect(out[24 * 48 + 14].x > 0.01)        // 2 px outside the layer edge (x = 16): light spilled out
        #expect(out[24 * 48 + 24].x > 0.9)         // the centre is still bright
        #expect(out[24 * 48 + 2].x < 0.001)        // far away: nothing
    }

    @Test func blurAfterTheMasksStaysInsideTheLayerWhenCornersComeLast() throws {
        guard let (dev, q, comp) = setup() else { return }
        let pb = makeBGRA(16, 16) { _, _ in (255, 255, 255, 255) }
        var fx = ClipEffects(); fx.blur = 4
        fx.post = EffectMasks(crop: .none, cornerRadius: 1)        // anything after the blur cuts the halo
        let t = target(dev, 48, 48)
        try render(comp, q, [layer(pb, 16, 16, effects: fx)], 48, 48, into: t)
        #expect(readAll(t)[24 * 48 + 12].x < 0.001)                // outside the layer rectangle
    }

    @Test func largeSigmaRunsThroughTheReducedPath() throws {
        guard let (dev, q, comp) = setup() else { return }
        let pb = makeBGRA(64, 64) { x, _ in x < 32 ? (255, 255, 255, 255) : (0, 0, 0, 255) }
        var fx = ClipEffects(); fx.blur = 40
        let t = target(dev, 64, 64)
        try render(comp, q, [layer(pb, 64, 64, effects: fx)], 64, 64, into: t)
        let out = readAll(t)
        // Smooth falloff over the edge at x = 32, bright on the left and darker on the right, monotonic along the row.
        let row = (0..<64).map { out[32 * 64 + $0].x }
        #expect(row[8] > row[56])
        for i in 1..<64 { #expect(row[i] <= row[i - 1] + 0.01) }
    }
}

// MARK: Cost

@Suite struct GaussianBlurCostTests {
    /// Prints ms per frame (GPU time of the whole command buffer, plain frame vs blurred frame) at 1080p and 4K.
    @Test func measureCost() throws {
        guard let (dev, q, comp) = setup() else { return }
        for (w, h, name) in [(1920, 1080, "1080p"), (3840, 2160, "4K")] {
            let pb = makeBGRA(w, h) { x, y in (UInt8(x & 255), UInt8(y & 255), 128, 255) }
            let t = target(dev, w, h)
            func gpuMs(_ sigma: Double) throws -> Double {
                var fx = ClipEffects(); fx.blur = sigma
                var times: [Double] = []
                for i in 0..<12 {
                    let cb = try render(comp, q, [layer(pb, w, h, effects: fx)], w, h, into: t)
                    if i >= 2 { times.append((cb.gpuEndTime - cb.gpuStartTime) * 1000) }
                }
                return times.sorted()[times.count / 2]
            }
            let base = try gpuMs(0)
            var line = "\(name): plain \(String(format: "%.2f", base)) ms"
            for s in [4.0, 12, 30, 100] { line += ", blur sigma \(Int(s)) \(String(format: "%.2f", try gpuMs(s))) ms" }
            NSLog("SQBLURCOST %@", line)
            print("SQBLURCOST \(line)")
        }
    }
}
