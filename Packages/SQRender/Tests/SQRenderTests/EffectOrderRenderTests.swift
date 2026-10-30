#if canImport(Metal)
import CoreVideo
import Foundation
import Metal
import SQCore
import Testing
@testable import SQRender

private func makeBGRA(_ w: Int, _ h: Int, _ f: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
    precondition(CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess)
    let b = pb!
    CVPixelBufferLockBaseAddress(b, [])
    defer { CVPixelBufferUnlockBaseAddress(b, []) }
    let base = CVPixelBufferGetBaseAddress(b)!, stride = CVPixelBufferGetBytesPerRow(b)
    for y in 0..<h { for x in 0..<w {
        let px = (base + y * stride + x * 4).assumingMemoryBound(to: UInt8.self)
        let c = f(x, y)
        px[0] = c.2; px[1] = c.1; px[2] = c.0; px[3] = 255
    } }
    return b
}

private func lin709(_ e: Float) -> Float {
    e < 0.081242858 ? e / 4.5 : powf((e + 0.09929682680944) / 1.09929682680944, 1 / 0.45)
}
private func linear(_ c: (UInt8, UInt8, UInt8)) -> SIMD3<Float> {
    SIMD3(lin709(Float(c.0) / 255), lin709(Float(c.1) / 255), lin709(Float(c.2) / 255))
}

private func setup() -> (MTLDevice, MTLCommandQueue, Compositor)? {
    guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue(), let c = try? Compositor(device: d) else { return nil }
    return (d, q, c)
}

private func renderRGB(_ comp: Compositor, _ dev: MTLDevice, _ q: MTLCommandQueue, _ pb: CVPixelBuffer, w: Int, h: Int,
                        effects: ClipEffects) throws -> [SIMD3<Float>] {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
    d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
    let t = dev.makeTexture(descriptor: d)!
    let info = VideoTrackInfo(width: w, height: h, codec: "x", bitDepth: 8, chroma: "4:4:4", nominalFrameDuration: Time(1, 25), isVariableFrameRate: false)
    let cb = q.makeCommandBuffer()!
    try comp.render([RenderLayer(content: .frame(pb, colorHint: info), effects: effects)],
                    format: SequenceFormat(width: w, height: h, frameDuration: Time(1, 25)), into: t, commandBuffer: cb)
    cb.commit(); cb.waitUntilCompleted()
    var px = [Float16](repeating: 0, count: w * h * 4)
    t.getBytes(&px, bytesPerRow: w * 8, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    return (0..<(w * h)).map { SIMD3<Float>(Float(px[$0 * 4]), Float(px[$0 * 4 + 1]), Float(px[$0 * 4 + 2])) }
}

private func clip(_ list: [(String, [String: Double])]) -> Clip {
    var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero)
    for (k, v) in list {
        let id = c.addEffect(kind: k)!
        for (key, val) in v { c.setParameter(id, key, to: val) }
    }
    return c
}

private func worst(_ a: [SIMD3<Float>], _ b: [SIMD3<Float>]) -> Float {
    var w: Float = 0
    for i in a.indices { for c in 0..<3 { w = max(w, abs(a[i][c] - b[i][c])) } }
    return w
}

@Suite struct EffectOrderRenderTests {
    private let rc: (String, [String: Double]) = (ClipEffect.roundedCornersKind, [ClipEffect.radiusKey: 20])
    private let crop: (String, [String: Double]) = (ClipEffect.cropKind, [ClipEffect.cropLeftKey: 25])

    /// CPU reference of a mask: white picture times coverage, over black.
    private func cpuMask(_ m: EffectMasks, w: Int, h: Int) -> [SIMD3<Float>] {
        var px = [SIMD4<Float>](repeating: SIMD4(1, 1, 1, 1), count: w * h)
        CropMask.apply(&px, width: w, height: h, crop: m.crop, cornerRadius: Float(m.cornerRadius), roundFirst: m.roundFirst)
        return px.map { SIMD3($0.x, $0.y, $0.z) }
    }

    @Test func roundedCornersBeforeAndAfterCropDifferAndMatchTheCPUReference() throws {
        guard let (dev, q, comp) = setup() else { return }
        let w = 64, h = 64
        let pb = makeBGRA(w, h) { _, _ in (255, 255, 255) }
        let t = Time(1, 1)
        var outputs: [[SIMD3<Float>]] = []
        for order in [[rc, crop], [crop, rc]] {
            let fx = clip(order).effects(at: t)
            #expect(fx.segments.count == 1)
            let gpu = try renderRGB(comp, dev, q, pb, w: w, h: h, effects: fx)
            let cpu = cpuMask(fx.pre, w: w, h: h)
            let wst = worst(gpu, cpu)
            #expect(wst < 0.03, "order \(order.map(\.0)) worst \(wst)")
            outputs.append(gpu)
        }
        #expect(worst(outputs[0], outputs[1]) > 0.5)                       // at the top-left of the crop the two clearly differ
        #expect(outputs[0][1 * w + 17].x > 0.9 && outputs[1][1 * w + 17].x < 0.1)
    }

    @Test func aPassSplitStillMatchesTheReference() throws {
        guard let (dev, q, comp) = setup() else { return }
        // Crop, Rounded Corners, Crop cannot be one mask: two passes. The result is the rounded cropped rectangle cut by the
        // second crop: compare with the CPU product of both masks.
        let w = 64, h = 64
        let pb = makeBGRA(w, h) { _, _ in (255, 255, 255) }
        let c2: (String, [String: Double]) = (ClipEffect.cropKind, [ClipEffect.cropTopKey: 50])
        let fx = clip([crop, rc, c2]).effects(at: Time(1, 1))
        #expect(fx.segments.count == 2)
        let gpu = try renderRGB(comp, dev, q, pb, w: w, h: h, effects: fx)
        var ref = cpuMask(fx.segments[0].masks, w: w, h: h)
        let second = cpuMask(fx.segments[1].masks, w: w, h: h)
        for i in ref.indices { ref[i] *= second[i].x }
        #expect(worst(gpu, ref) < 0.05)
    }

    /// Premultiplied linear picture of a strip: green left, red right, over black (alpha 1).
    private func strip(_ w: Int, _ h: Int) -> (CVPixelBuffer, [SIMD4<Float>]) {
        let colors: (Int) -> (UInt8, UInt8, UInt8) = { $0 < w / 2 ? (20, 200, 30) : (200, 40, 40) }
        let pb = makeBGRA(w, h) { x, _ in colors(x) }
        var px: [SIMD4<Float>] = []
        for _ in 0..<h { for x in 0..<w { let c = linear(colors(x)); px.append(SIMD4(c.x, c.y, c.z, 1)) } }
        return (pb, px)
    }

    private func keyed(_ px: [SIMD4<Float>], _ key: ChromaKey) -> [SIMD4<Float>] {
        px.map { p in
            let c = p.w > 0 ? SIMD3(p.x, p.y, p.z) / p.w : SIMD3<Float>(repeating: 0)
            let r = UltraKey.apply(rgb: c, alpha: p.w, keys: [key])
            return SIMD4(r.rgb.x * r.alpha, r.rgb.y * r.alpha, r.rgb.z * r.alpha, r.alpha)
        }
    }

    @Test func ultraKeyBeforeAndAfterABlurDifferAndMatchTheReference() throws {
        guard let (dev, q, comp) = setup() else { return }
        let w = 32, h = 8
        let (pb, src) = strip(w, h)
        let k = ChromaKey(hue: 120, halfWidth: 30, soft: 10, spill: 0)
        let keyEffect: (String, [String: Double]) = (ClipEffect.ultraKeyKind, [ClipEffect.keyHueKey: 120, ClipEffect.toleranceKey: 33.333333333333336, ClipEffect.softenKey: 16.666666666666668, ClipEffect.spillKey: 0])
        let blurEffect: (String, [String: Double]) = (ClipEffect.gaussianBlurKind, [ClipEffect.blurrinessKey: 2 / ClipEffect.gaussianSigmaPerBlurriness])   // sigma 2
        // key, then blur
        let a = clip([keyEffect, blurEffect]).effects(at: Time(1, 1))
        let refA = GaussianBlur.blur(keyed(src, k), width: w, height: h, sigma: 2).map { SIMD3($0.x, $0.y, $0.z) }
        let gpuA = try renderRGB(comp, dev, q, pb, w: w, h: h, effects: a)
        #expect(worst(gpuA, refA) < 0.03, "key then blur \(worst(gpuA, refA))")
        // blur, then key: the key sees the blurred colors (mixed hue at the seam)
        let b = clip([blurEffect, keyEffect]).effects(at: Time(1, 1))
        #expect(b.segments.count == 2 && b.segments[1].keys.count == 1)
        let refB = keyed(GaussianBlur.blur(src, width: w, height: h, sigma: 2), k).map { SIMD3($0.x, $0.y, $0.z) }
        let gpuB = try renderRGB(comp, dev, q, pb, w: w, h: h, effects: b)
        #expect(worst(gpuB, refB) < 0.03, "blur then key \(worst(gpuB, refB))")
        #expect(worst(gpuA, gpuB) > 0.02)                                   // the orders really differ at the seam
    }

    // MARK: Texture pool and the reduced-size switch

    @Test func animatingSigmaAllocatesABoundedNumberOfTextures() throws {
        guard let (dev, q, comp) = setup() else { return }
        let w = 200, h = 120
        let pb = makeBGRA(w, h) { x, y in (UInt8((x * 5) & 255), UInt8((y * 9) & 255), 90) }
        for i in 0..<60 {
            var fx = ClipEffects(); fx.blur = 3 + 6 * Double(i) / 59
            _ = try renderRGB(comp, dev, q, pb, w: w, h: h, effects: fx)
        }
        #expect(comp.intermediateAllocations <= 10, "allocated \(comp.intermediateAllocations)")
    }

    @Test func crossingTheReducedSizeSwitchDoesNotJump() throws {
        guard let (dev, q, comp) = setup() else { return }
        let w = 128, h = 96
        // A textured picture: the difference between sigma 6 (full size) and 6.1 (reduced) must be of the order of the
        // difference between two neighboring sigmas on the same side, not a visible step.
        let pb = makeBGRA(w, h) { x, y in
            let v = ((x / 6 + y / 6) % 2 == 0) ? UInt8(230) : UInt8(40)
            return (v, UInt8((x * 2) & 255), UInt8((y * 2) & 255))
        }
        func frame(_ s: Double) throws -> [SIMD3<Float>] {
            var fx = ClipEffects(); fx.blur = s
            return try renderRGB(comp, dev, q, pb, w: w, h: h, effects: fx)
        }
        func meanDiff(_ a: [SIMD3<Float>], _ b: [SIMD3<Float>]) -> Float {
            var t: Float = 0
            for i in a.indices { t += (abs(a[i].x - b[i].x) + abs(a[i].y - b[i].y) + abs(a[i].z - b[i].z)) / 3 }
            return t / Float(a.count)
        }
        let below = meanDiff(try frame(5.8), try frame(6.0))
        let across = meanDiff(try frame(6.0), try frame(6.2))
        NSLog("SQBLURSWITCH same side %.5f, across %.5f", below, across)
        #expect(across < 0.01, "step across the switch \(across) (same side \(below))")
    }

    // MARK: Nested-sequence groups

    private func groupRender(effects: ClipEffects, blend: BlendMode, under: (UInt8, UInt8, UInt8)? = nil) throws -> [SIMD3<Float>] {
        let (dev, q, comp) = try #require(setup())
        let w = 64, h = 64
        let inner = makeBGRA(w, h) { _, _ in (255, 255, 255) }
        let info = VideoTrackInfo(width: w, height: h, codec: "x", bitDepth: 8, chroma: "4:4:4", nominalFrameDuration: Time(1, 25), isVariableFrameRate: false)
        let f = SequenceFormat(width: w, height: h, frameDuration: Time(1, 25))
        var nodes: [RenderNode] = []
        if let u = under { nodes.append(.layer(RenderLayer(content: .frame(makeBGRA(w, h) { _, _ in u }, colorHint: info)))) }
        nodes.append(.styledGroup(format: f, transform: .identity, opacity: 1, cornerRadius: 0,
                                  children: [.layer(RenderLayer(content: .frame(inner, colorHint: info)))], effects: effects, blendMode: blend))
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
        let t = dev.makeTexture(descriptor: d)!
        let cb = q.makeCommandBuffer()!
        try comp.render(nodes: nodes, format: f, into: t, commandBuffer: cb)
        cb.commit(); cb.waitUntilCompleted()
        var px = [Float16](repeating: 0, count: w * h * 4)
        t.getBytes(&px, bytesPerRow: w * 8, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        var out: [SIMD3<Float>] = []
        for i in 0..<(w * h) {
            let r = Float(px[i * 4]), g = Float(px[i * 4 + 1]), b = Float(px[i * 4 + 2])
            out.append(SIMD3<Float>(r, g, b))
        }
        return out
    }

    @Test func aNestedClipsCropAppliesToTheGroupImage() throws {
        var fx = ClipEffects()
        fx.pre = EffectMasks(crop: CropInsets(left: 0.25, top: 0, right: 0, bottom: 0))
        let out = try groupRender(effects: fx, blend: .normal)
        #expect(out[32 * 64 + 8].x < 0.01 && out[32 * 64 + 40].x > 0.99)
    }

    @Test func aNestedClipsBlurSpreadsTheGroupImage() throws {
        var fx = ClipEffects(); fx.blur = 6
        fx.post = EffectMasks(crop: CropInsets(left: 0.5, top: 0, right: 0, bottom: 0))     // cut at the middle after the blur
        let out = try groupRender(effects: fx, blend: .normal)
        let row = (0..<64).map { out[32 * 64 + $0].x }
        #expect(row[10] < 0.01)                         // cut away
        #expect(row[34] > 0.95)                         // blurred but white inside, away from the group image's own edges
        #expect(row[63] < 0.6 && row[63] > 0.3)         // the group image edge blurs against transparent: it fades there
    }

    @Test func aNestedClipsBlendModeUsesTheBackdrop() throws {
        let out = try groupRender(effects: .none, blend: .multiply, under: (128, 64, 200))
        let bg: [Int] = [128, 64, 200]
        // White multiplied with the backdrop leaves the backdrop (linearised).
        func lin(_ v: Int) -> Float { let e = Float(v) / 255; return e < 0.081242858 ? e / 4.5 : powf((e + 0.09929682680944) / 1.09929682680944, 1 / 0.45) }
        #expect(abs(out[32 * 64 + 32].x - lin(bg[0])) < 0.01 && abs(out[32 * 64 + 32].z - lin(bg[2])) < 0.01)
    }

    // MARK: Transition pairs

    private func pairRender(firstFX: ClipEffects = .none, secondFX: ClipEffects = .none, firstBlend: BlendMode = .normal,
                            secondBlend: BlendMode = .normal) throws -> [SIMD3<Float>] {
        let (dev, q, comp) = try #require(setup())
        let w = 64, h = 64
        let info = VideoTrackInfo(width: w, height: h, codec: "x", bitDepth: 8, chroma: "4:4:4", nominalFrameDuration: Time(1, 25), isVariableFrameRate: false)
        let f = SequenceFormat(width: w, height: h, frameDuration: Time(1, 25))
        func layer(_ c: (UInt8, UInt8, UInt8), _ opacity: Double, _ fx: ClipEffects, _ blend: BlendMode) -> LayerRequest {
            LayerRequest(clip: UUID(), media: UUID(), track: UUID(), sourceTime: .zero, effects: fx, blendMode: blend)
        }
        let pid = UUID()
        var ra = layer((255, 0, 0), 0.5, firstFX, firstBlend), rb = layer((0, 0, 255), 0.5, secondFX, secondBlend)
        ra.pair = LayerRequest.PairInfo(id: pid, role: .first, format: f, depth: 0)
        rb.pair = LayerRequest.PairInfo(id: pid, role: .second, format: f, depth: 0)
        func rl(_ c: (UInt8, UInt8, UInt8), _ fx: ClipEffects, _ blend: BlendMode) -> RenderLayer {
            var t = ClipTransform(); t.opacity = 0.5
            return RenderLayer(content: .frame(makeBGRA(w, h) { _, _ in c }, colorHint: info), transform: t, effects: fx, blendMode: blend)
        }
        let under = RenderLayer(content: .frame(makeBGRA(w, h) { _, _ in (128, 128, 128) }, colorHint: info))
        let tree = RenderNode.tree(requests: [LayerRequest(clip: UUID(), media: UUID(), track: UUID(), sourceTime: .zero), ra, rb],
                                   layers: [under, rl((255, 0, 0), firstFX, firstBlend), rl((0, 0, 255), secondFX, secondBlend)])
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
        let t = dev.makeTexture(descriptor: d)!
        let cb = q.makeCommandBuffer()!
        try comp.render(nodes: tree, format: f, into: t, commandBuffer: cb)
        cb.commit(); cb.waitUntilCompleted()
        var px = [Float16](repeating: 0, count: w * h * 4)
        t.getBytes(&px, bytesPerRow: w * 8, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        var out: [SIMD3<Float>] = []
        for i in 0..<(w * h) { out.append(SIMD3<Float>(Float(px[i * 4]), Float(px[i * 4 + 1]), Float(px[i * 4 + 2]))) }
        return out
    }

    @Test func eachSideOfAPairKeepsItsOwnCrop() throws {
        var fa = ClipEffects(); fa.pre = EffectMasks(crop: CropInsets(left: 0.5, top: 0, right: 0, bottom: 0))
        let out = try pairRender(firstFX: fa)
        let left = out[32 * 64 + 8], right = out[32 * 64 + 56]
        #expect(left.x < right.x - 0.05)                   // A (red) is cropped away on the left half: less red there
        #expect(left.z > 0.1)                               // B (blue) still shows there, over the gray backdrop
    }

    @Test func theIncomingClipsBlendModeAppliesToThePairResult() throws {
        let normal = try pairRender()
        let multiplied = try pairRender(firstBlend: .normal, secondBlend: .multiply)
        let c = 32 * 64 + 32
        #expect(multiplied[c].x < normal[c].x * 0.9 + 1e-6 && multiplied[c].x != normal[c].x)    // pair x gray backdrop, not B x A
        // Outgoing clip's mode is used when the incoming one is Normal.
        let outgoing = try pairRender(firstBlend: .multiply, secondBlend: .normal)
        #expect(abs(outgoing[c].x - multiplied[c].x) < 1e-6 && abs(outgoing[c].z - multiplied[c].z) < 1e-6)
    }
}
#endif
