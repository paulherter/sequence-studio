#if canImport(Metal)
import CoreVideo
import Foundation
import Metal
import SQCore
import Testing
@testable import SQRender

// W6.7 MasksV1 look tests: the compositor's mask coverage (fragment shader) against the CPU reference `MaskCoverage`,
// pixel by pixel ("golden image" = the CPU picture), within one 8-bit step.

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

private func info(_ w: Int, _ h: Int) -> VideoTrackInfo {
    VideoTrackInfo(width: w, height: h, codec: "hvc1", bitDepth: 8, chroma: "4:2:0",
                   nominalFrameDuration: Time(1, 25), isVariableFrameRate: false)
}

private func fmt(_ w: Int, _ h: Int) -> SequenceFormat { SequenceFormat(width: w, height: h, frameDuration: Time(1, 25)) }

private func setup() -> (MTLDevice, MTLCommandQueue, Compositor)? {
    guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue(), let c = try? Compositor(device: d) else { return nil }
    return (d, q, c)
}

private func renderNodes(_ comp: Compositor, _ dev: MTLDevice, _ q: MTLCommandQueue, _ nodes: [RenderNode],
                         _ w: Int, _ h: Int) throws -> [SIMD4<Float>] {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
    d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
    let t = dev.makeTexture(descriptor: d)!
    let cb = q.makeCommandBuffer()!
    try comp.render(nodes: nodes, format: fmt(w, h), into: t, commandBuffer: cb)
    cb.commit(); cb.waitUntilCompleted()
    #expect(cb.error == nil)
    var px = [Float16](repeating: 0, count: w * h * 4)
    t.getBytes(&px, bytesPerRow: w * 8, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    var out: [SIMD4<Float>] = []
    for i in 0..<(w * h) {
        let r = Float(px[i * 4]), g = Float(px[i * 4 + 1]), b = Float(px[i * 4 + 2]), a = Float(px[i * 4 + 3])
        out.append(SIMD4<Float>(r, g, b, a))
    }
    return out
}

private func lin709(_ e: Float) -> Float {
    e < 0.081242858 ? e / 4.5 : powf((e + 0.09929682680944) / 1.09929682680944, 1 / 0.45)
}

private func linear(_ c: (UInt8, UInt8, UInt8, UInt8)) -> SIMD3<Float> {
    SIMD3(lin709(Float(c.2) / 255), lin709(Float(c.1) / 255), lin709(Float(c.0) / 255))
}

private func shape(_ path: MaskPath, feather: Double = 0, expansion: Double = 0, opacity: Double = 1,
                   inverted: Bool = false, mode: MaskMode = .add) -> MaskShape {
    MaskShape(polygon: path.polygon(), feather: feather, expansion: expansion, opacity: opacity, inverted: inverted, mode: mode)
}

/// Renders one opaque `w` x `h` layer of `color` with `masks` 1:1 over black and returns the worst channel error against
/// color * CPU coverage.
private func worstError(_ w: Int, _ h: Int, masks: [MaskShape], blur: Double = 0, matte: SubjectMatte? = nil,
                        mattes: [UUID: SubjectMatte] = [:],
                        color: (UInt8, UInt8, UInt8, UInt8) = (60, 200, 240, 255)) throws -> Float {
    let (dev, q, comp) = try #require(setup())
    let pb = makeBGRA(w, h) { _, _ in color }
    var fx = ClipEffects(segments: [], masks: masks)
    if blur > 0 { fx.blur = blur }
    var layer = RenderLayer(content: .frame(pb, colorHint: info(w, h)), effects: fx)
    layer.subjectMatte = matte
    layer.mattes = mattes
    let got = try renderNodes(comp, dev, q, [.layer(layer)], w, h)
    let c = linear(color)
    var worst: Float = 0
    for y in 0..<h {
        for x in 0..<w {
            let cov = Float(MaskCoverage.coverage(at: Vec2(Double(x) + 0.5, Double(y) + 0.5),
                                                  masks: MaskCoverage.opacityMasks(masks, mattes: mattes),
                                                  frame: Vec2(Double(w), Double(h)), pixel: 1, matte: matte, mattes: mattes))
            let g = got[y * w + x]
            for i in 0..<3 { worst = max(worst, abs(g[i] - c[i] * cov)) }
        }
    }
    return worst
}

/// One 8-bit step plus half-float rounding.
private let tolerance: Float = 1.0 / 255 + 0.001

@Suite struct MaskRenderTests {
    // MARK: W9.8 subject masks

    /// A soft blob matte at a quarter of the layer size (the shader upsamples it, like a Vision matte).
    private func blobMatte(_ w: Int, _ h: Int) -> SubjectMatte {
        var v = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let dx = (Double(x) + 0.5) / Double(w) - 0.45, dy = (Double(y) + 0.5) / Double(h) - 0.5
                v[y * w + x] = Float(min(max(1.5 - (dx * dx + dy * dy).squareRoot() * 6, 0), 1))
            }
        }
        return SubjectMatte(width: w, height: h, values: v)
    }

    private func subject(opacity: Double = 1, inverted: Bool = false, mode: MaskMode = .add) -> MaskShape {
        MaskShape(polygon: [], opacity: opacity, inverted: inverted, mode: mode, source: .subject)
    }

    @Test func subjectMaskMatchesCPU() throws {
        let e = try worstError(64, 36, masks: [subject()], matte: blobMatte(16, 9))
        #expect(e <= tolerance, "worst \(e)")
    }

    @Test func invertedSubjectWithPathMaskMatchesCPU() throws {
        let rect = shape(.rectangle(Vec2(0.1, 0.1), Vec2(0.9, 0.9)), feather: 4)
        let e = try worstError(64, 36, masks: [rect, subject(opacity: 0.7, inverted: true, mode: .intersect)],
                               matte: blobMatte(32, 18))
        #expect(e <= tolerance, "worst \(e)")
    }

    @Test func subjectMaskWithoutMatteMatchesCPU() throws {
        // No matte yet (late or failed segmentation): no person, so a plain subject mask hides the clip, never flashes it.
        let e = try worstError(32, 32, masks: [subject()], matte: nil)
        #expect(e <= tolerance, "worst \(e)")
        let inv = try worstError(32, 32, masks: [subject(opacity: 0.6, inverted: true)], matte: nil)
        #expect(inv <= tolerance, "inverted worst \(inv)")
    }

    @Test func blurPaddingOutsideTheFrameHasNoPerson() throws {
        // A 32 x 24 layer in the middle of a 64 x 48 canvas, blurred (the last pass draws a padded image larger than the
        // clip's frame). The person fills the left half and is cut by the frame edge: the blur that bleeds out past the
        // frame edge is not a person, so it stays black (clamp-to-edge sampling would keep it).
        let (dev, q, comp) = try #require(setup())
        let lw = 32, lh = 24, cw = 64, ch = 48
        let pb = makeBGRA(lw, lh) { _, _ in (60, 200, 240, 255) }
        var fx = ClipEffects(segments: [], masks: [subject()])
        fx.blur = 2
        var layer = RenderLayer(content: .frame(pb, colorHint: info(lw, lh)), effects: fx)
        layer.subjectMatte = SubjectMatte(width: 4, height: 1, values: [1, 1, 0, 0])
        let got = try renderNodes(comp, dev, q, [.layer(layer)], cw, ch)
        let left = (cw - lw) / 2, row = ch / 2
        #expect(got[row * cw + left + 3][1] > 0.3)          // inside the frame, inside the person
        for x in (left - 5)..<left { #expect(got[row * cw + x][1] < 0.002, "x \(x)") }
    }

    @Test func pausedRedrawReusesTheMatteTexture() throws {
        let (dev, q, comp) = try #require(setup())
        let pb = makeBGRA(16, 16) { _, _ in (60, 200, 240, 255) }
        var layer = RenderLayer(content: .frame(pb, colorHint: info(16, 16)), effects: ClipEffects(segments: [], masks: [subject()]))
        layer.subjectMatte = blobMatte(8, 8)
        _ = try renderNodes(comp, dev, q, [.layer(layer)], 16, 16)
        _ = try renderNodes(comp, dev, q, [.layer(layer)], 16, 16)
        #expect(comp.matteUploads == 1)
        layer.subjectMatte = blobMatte(8, 4)
        _ = try renderNodes(comp, dev, q, [.layer(layer)], 16, 16)
        #expect(comp.matteUploads == 2)
    }

    @Test func newMatteEveryFrameReusesPooledTextures() throws {
        // Playback with a Magic mask: a new matte (new storage) every frame. Once the caches are full, evicted textures
        // come back from completed frames and the next upload goes into one of them.
        let (dev, q, comp) = try #require(setup())
        let pb = makeBGRA(16, 16) { _, _ in (60, 200, 240, 255) }
        let a = UUID(), b = UUID()
        var one = RenderLayer(content: .frame(pb, colorHint: info(16, 16)), effects: ClipEffects(segments: [], masks: [magic(a)]))
        var two = RenderLayer(content: .frame(pb, colorHint: info(16, 16)),
                              effects: ClipEffects(segments: [EffectSegment(filter: .invert(channel: 0, blend: 0), scope: [magic(a)]),
                                                              EffectSegment()], masks: [magic(a), magic(b)]))
        for k in 0..<40 {
            one.mattes = [a: blobMatte(8, 8)]
            two.mattes = [a: blobMatte(8, 8), b: SubjectMatte(width: 8, height: 8, values: [Float](repeating: Float(k % 2), count: 64))]
            _ = try renderNodes(comp, dev, q, [.layer(one), .layer(two)], 16, 16)
        }
        #expect(comp.matteUploads >= 80)
        // 8 cached single mattes + 4 cached packed ones, plus at most one frame's worth in flight.
        #expect(comp.matteTexturesMade <= 16, "made \(comp.matteTexturesMade)")
        // A pooled texture holds the new matte, not a stale blob: full matte shows everything; a right-half matte hides the
        // left edge, which the blob never did.
        one.mattes = [a: SubjectMatte(width: 8, height: 8, values: [Float](repeating: 1, count: 64))]
        let full = try renderNodes(comp, dev, q, [.layer(one)], 16, 16)
        #expect(full.allSatisfy { $0[1] > 0.3 })
        one.mattes = [a: SubjectMatte(width: 8, height: 8, values: (0..<64).map { $0 % 8 < 4 ? 0 : 1 })]
        let half = try renderNodes(comp, dev, q, [.layer(one)], 16, 16)
        #expect(half[8 * 16 + 1][1] < 0.002)
        #expect(half[8 * 16 + 14][1] > 0.3)
    }

    @Test func aFullSizeMatteEveryFrameUploadsInAFewMilliseconds() throws {
        // The maintainer's 1 FPS with a subject/Magic mask: every played frame brings a new matte. Its blank test and its upload
        // (Float -> half) ran per-pixel loops on the render thread: 180 + 180 ms (single) and 790 ms (packed) per frame for
        // 1920 px mattes in a debug build.
        let (dev, q, comp) = try #require(setup())
        let pb = makeBGRA(16, 16) { _, _ in (60, 200, 240, 255) }
        let a = UUID(), b = UUID()
        let w = 1920, h = 1080, n = 4
        // A face low in the frame: everything above it is 0 (a blank test that scans pixel by pixel pays for all of them).
        let mattes = (0..<n).map { k in
            SubjectMatte(width: w, height: h, values: (0..<(w * h)).map { $0 / w > h * 9 / 10 ? Float(k + 1) / Float(n) : 0 })
        }
        let others = (0..<n).map { k in SubjectMatte(width: w, height: h, values: [Float](repeating: Float(k + 1) / Float(n + 1), count: w * h)) }
        var single = RenderLayer(content: .frame(pb, colorHint: info(16, 16)), effects: ClipEffects(segments: [], masks: [magic(a)]))
        var packed = RenderLayer(content: .frame(pb, colorHint: info(16, 16)), effects: ClipEffects(segments: [], masks: [magic(a), magic(b)]))
        // Pipelines, pooled textures and staging warm (the first full-size upload allocates them).
        single.mattes = [a: others[0]]
        _ = try renderNodes(comp, dev, q, [.layer(single)], 16, 16)
        packed.mattes = [a: others[1], b: others[2]]
        _ = try renderNodes(comp, dev, q, [.layer(packed)], 16, 16)
        let uploads0 = comp.matteUploads
        let clock = ContinuousClock()
        var singleMS: Double = 0, packedMS: Double = 0
        for k in 0..<n {
            single.mattes = [a: mattes[k]]
            singleMS += Double(clock.measure { _ = try? renderNodes(comp, dev, q, [.layer(single)], 16, 16) } / .microseconds(1)) / 1000
            packed.mattes = [a: mattes[(k + 1) % n], b: others[k]]
            let p = Double(clock.measure { _ = try? renderNodes(comp, dev, q, [.layer(packed)], 16, 16) } / .microseconds(1)) / 1000
            packedMS += p
        }
        singleMS /= Double(n); packedMS /= Double(n)
        print("PERF matte upload 1920x1080: single \(singleMS) ms, packed 2 \(packedMS) ms per frame")
        #expect(comp.matteUploads - uploads0 == 2 * n)
        #expect(singleMS < 12, "single \(singleMS) ms")
        #expect(packedMS < 25, "packed \(packedMS) ms")
        // The upload keeps the values: an all-1 matte shows the picture, an all-0 one hides it.
        single.mattes = [a: SubjectMatte(width: w, height: h, values: [Float](repeating: 1, count: w * h))]
        #expect(try renderNodes(comp, dev, q, [.layer(single)], 16, 16).allSatisfy { $0[1] > 0.3 })
        single.mattes = [a: SubjectMatte(width: w, height: h, values: (0..<(w * h)).map { $0 % w < w / 2 ? 0 : 1 })]
        let half = try renderNodes(comp, dev, q, [.layer(single)], 16, 16)
        #expect(half[8 * 16 + 1][1] < 0.002 && half[8 * 16 + 14][1] > 0.3)
        // Below one 8-bit step everywhere: blank, the mask is left out and the picture stays.
        single.mattes = [a: SubjectMatte(width: w, height: h, values: [Float](repeating: 0.001, count: w * h))]
        #expect(try renderNodes(comp, dev, q, [.layer(single)], 16, 16).allSatisfy { $0[1] > 0.3 })
        // Packed, each matte in its own channel: all of a, minus b's right half.
        var cut = RenderLayer(content: .frame(pb, colorHint: info(16, 16)),
                              effects: ClipEffects(segments: [], masks: [magic(a), magic(b, mode: .subtract)]))
        cut.mattes = [a: SubjectMatte(width: w, height: h, values: [Float](repeating: 1, count: w * h)),
                      b: SubjectMatte(width: w, height: h, values: (0..<(w * h)).map { $0 % w < w / 2 ? 0 : 1 })]
        let left = try renderNodes(comp, dev, q, [.layer(cut)], 16, 16)
        #expect(left[8 * 16 + 1][1] > 0.3 && left[8 * 16 + 14][1] < 0.002)
    }

    @Test func subjectMaskAfterBlurMatchesCPU() throws {
        // Two segments: the mask goes on the last pass, whose `size` is the padded blur image and `maskSize` the layer.
        let (dev, q, comp) = try #require(setup())
        let w = 48, h = 32
        let pb = makeBGRA(w, h) { _, _ in (60, 200, 240, 255) }
        var fx = ClipEffects(segments: [], masks: [subject()])
        fx.blur = 2
        var layer = RenderLayer(content: .frame(pb, colorHint: info(w, h)), effects: fx)
        layer.subjectMatte = blobMatte(12, 8)
        let got = try renderNodes(comp, dev, q, [.layer(layer)], w, h)
        // Over black: center of the blob keeps the color, the far corner is cut to black.
        let green = linear((60, 200, 240, 255)).y
        #expect(abs(got[(h / 2) * w + w * 45 / 100][1] - green) < 0.02)
        #expect(got[0][1] < 0.01)
    }
    // MARK: Magic masks and effect mask inputs

    private func magic(_ id: UUID, opacity: Double = 1, inverted: Bool = false, mode: MaskMode = .add) -> MaskShape {
        MaskShape(polygon: [], opacity: opacity, inverted: inverted, mode: mode, source: .magic, matteKey: id)
    }

    @Test func twoMagicMattesAndThePersonInOneDrawMatchCPU() throws {
        // Three mattes share one packed texture (r, g, b).
        let a = UUID(), b = UUID()
        let ma = blobMatte(16, 9)
        let mb = SubjectMatte(width: 16, height: 9, values: (0..<144).map { Float($0 % 16) / 15 })
        let person = SubjectMatte(width: 16, height: 9, values: (0..<144).map { Float($0 / 16) / 8 })
        let e = try worstError(64, 36, masks: [magic(a), magic(b, opacity: 0.8, inverted: true, mode: .subtract), subject(mode: .intersect)],
                               matte: person, mattes: [a: ma, b: mb])
        #expect(e <= tolerance, "worst \(e)")
    }

    @Test func magicMaskWithoutItsMatteKeepsThePicture() throws {
        // Not tracked on this frame (or picked elsewhere): the mask is left out, the picture is not cut to black.
        let e = try worstError(32, 32, masks: [magic(UUID())], mattes: [UUID(): blobMatte(8, 8)])
        #expect(e <= tolerance, "worst \(e)")
        let (dev, q, comp) = try #require(setup())
        let pb = makeBGRA(16, 16) { _, _ in (60, 200, 240, 255) }
        let id = UUID()
        var layer = RenderLayer(content: .frame(pb, colorHint: info(16, 16)), effects: ClipEffects(segments: [], masks: [magic(id)]))
        layer.mattes = [id: SubjectMatte(width: 8, height: 8, values: [Float](repeating: 0, count: 64))]   // blank pick
        let got = try renderNodes(comp, dev, q, [.layer(layer)], 16, 16)
        #expect(got[8 * 16 + 8][1] > 0.3)
    }

    /// Renders a `w` x `h` layer of `pb` 1:1 with `segs`.
    private func render(_ pb: CVPixelBuffer, _ w: Int, _ h: Int, segs: [EffectSegment], mattes: [UUID: SubjectMatte] = [:]) throws -> [SIMD4<Float>] {
        let (dev, q, comp) = try #require(setup())
        var layer = RenderLayer(content: .frame(pb, colorHint: info(w, h)), effects: ClipEffects(segments: segs, masks: []))
        layer.mattes = mattes
        return try renderNodes(comp, dev, q, [.layer(layer)], w, h)
    }

    @Test func filterWithMaskInputShowsOnlyInsideTheMask() throws {
        let w = 48, h = 32
        let pb = makeBGRA(w, h) { _, _ in (60, 200, 240, 255) }
        let plain = try render(pb, w, h, segs: [])
        let left = shape(.rectangle(Vec2(0, 0), Vec2(0.5, 1)))
        let got = try render(pb, w, h, segs: [EffectSegment(filter: .invert(channel: 0, blend: 0), scope: [left]), EffectSegment()])
        let row = h / 2
        #expect(abs(got[row * w + 5][1] - plain[row * w + 5][1]) > 0.1)              // inverted inside
        for x in [30, 40, 46] { #expect(abs(got[row * w + x][1] - plain[row * w + x][1]) < tolerance, "x \(x)") }
    }

    @Test func blurWithMagicMaskInputBlursOnlyThePickedArea() throws {
        // Columns alternate black / white; the Magic matte covers the left half: the left blurs to gray, the right keeps
        // its stripes.
        let w = 64, h = 32
        let pb = makeBGRA(w, h) { x, _ in x % 2 == 0 ? (0, 0, 0, 255) : (255, 255, 255, 255) }
        let id = UUID()
        let m = SubjectMatte(width: 8, height: 4, values: (0..<32).map { $0 % 8 < 4 ? 1 : 0 })
        let got = try render(pb, w, h, segs: [EffectSegment(blurAfter: 3, scope: [magic(id)]), EffectSegment()], mattes: [id: m])
        let row = h / 2
        #expect(abs(got[row * w + 10][1] - got[row * w + 11][1]) < 0.05)            // blurred: neighbors alike
        #expect(abs(got[row * w + 50][1] - got[row * w + 51][1]) > 0.8)             // sharp stripes
    }

    // MARK: Mask inputs on keys and Color (DECISIONS 2026-10-06)

    @Test func maskedKeyKeysOnlyInsideTheMask() throws {
        // Green everywhere, a green key limited to the left half: the left goes transparent (black over the canvas), the
        // right keeps its green exactly.
        let w = 48, h = 32
        let pb = makeBGRA(w, h) { _, _ in (0, 255, 0, 255) }
        let plain = try render(pb, w, h, segs: [])
        let left = shape(.rectangle(Vec2(0, 0), Vec2(0.5, 1)))
        let key = ChromaKey(hue: 120, halfWidth: 30, soft: 10, spill: 0)
        let got = try render(pb, w, h, segs: [EffectSegment(keys: [key], scope: [left]), EffectSegment()])
        let row = h / 2
        #expect(got[row * w + 5][1] < 0.01)
        for x in [30, 40, 46] { #expect(abs(got[row * w + x][1] - plain[row * w + x][1]) < tolerance, "x \(x)") }
        // The same key without the mask keys everything.
        let all = try render(pb, w, h, segs: [EffectSegment(keys: [key])])
        #expect(all[row * w + 40][1] < 0.01)
    }

    @Test func maskedColourEffectGradesOnlyInsideTheMask() throws {
        let w = 48, h = 32
        let pb = makeBGRA(w, h) { _, _ in (90, 110, 130, 255) }
        let plain = try render(pb, w, h, segs: [])
        let left = shape(.rectangle(Vec2(0, 0), Vec2(0.5, 1)))
        var ce = ColorEffect(id: 2)
        ce.basic.exposure = 1
        let got = try render(pb, w, h, segs: [EffectSegment(scope: [left], grade: ce), EffectSegment()])
        let row = h / 2
        #expect(got[row * w + 5][1] > plain[row * w + 5][1] * 1.3)                  // brighter inside
        for x in [30, 40, 46] { #expect(abs(got[row * w + x][1] - plain[row * w + x][1]) < tolerance, "x \(x)") }
    }

    @Test func lutInsideMaskedColourEffectIsScopedByTheMask() async throws {
        let w = 48, h = 32
        let pb = makeBGRA(w, h) { _, _ in (90, 110, 130, 255) }
        let left = shape(.rectangle(Vec2(0, 0), Vec2(0.5, 1)))
        var ce = ColorEffect(id: 2)
        ce.creative.look = .file("/luts/red.cube")
        let luts = StubProvider()
        luts.table[.file("/luts/red.cube")] = CubeLUT(title: "red", kind: .lut3D, size: 2,
                                                       table: [SIMD3<Float>](repeating: SIMD3(1, 0, 0), count: 8))
        let segs = [EffectSegment(scope: [left], grade: ce), EffectSegment()]
        func run(blocking: Bool, resolver: LayerColorResolver?) async throws -> [SIMD4<Float>] {
            let (dev, q, comp) = try #require(setup())
            comp.colorResolver = resolver
            comp.colorResolverBlocks = blocking
            let layer = RenderLayer(content: .frame(pb, colorHint: info(w, h)), effects: ClipEffects(segments: segs, masks: []))
            if !blocking, let resolver {
                // Playback: the first frame may draw without the LUT; the warm-up (what the engine does on a push) fixes it.
                resolver.warm([(Compositor.maskedGradeColor(ce), Compositor.maskedGradeMedia)])
                await resolver.waitUntilIdle()
            }
            return try renderNodes(comp, dev, q, [.layer(layer)], w, h)
        }
        let plain = try render(pb, w, h, segs: [])
        let noLUT = try await run(blocking: true, resolver: nil)
        let export = try await run(blocking: true, resolver: LayerColorResolver(lutProvider: luts) { _ in nil })
        let playback = try await run(blocking: false, resolver: LayerColorResolver(lutProvider: luts) { _ in nil })
        let row = h / 2
        // Inside the mask the LUT turns the picture red; outside it is untouched; without a resolver the LUT is skipped.
        #expect(export[row * w + 5][0] > 0.3 && export[row * w + 5][1] < 0.02 && export[row * w + 5][2] < 0.02)
        for x in [30, 40, 46] { #expect(abs(export[row * w + x][1] - plain[row * w + x][1]) < tolerance, "x \(x)") }
        #expect(noLUT[row * w + 5][1] > 0.1)
        // Playback and export agree exactly.
        #expect(playback == export)
    }

    @Test func twoClipsWithDifferentLUTsKeepTheirOwnLUT() async throws {
        // Both clips' masked effect has ColorEffect.id 2; the playback fallback must never cross over.
        let w = 48, h = 32
        let pb = makeBGRA(w, h) { _, _ in (90, 110, 130, 255) }
        let all = shape(.rectangle(Vec2(0, 0), Vec2(1, 1)))
        func effect(_ file: String) -> ColorEffect { var e = ColorEffect(id: 2); e.creative.look = .file(file); return e }
        let luts = StubProvider()
        luts.table[.file("/luts/red.cube")] = CubeLUT(title: "r", kind: .lut3D, size: 2,
                                                       table: [SIMD3<Float>](repeating: SIMD3(1, 0, 0), count: 8))
        luts.table[.file("/luts/blue.cube")] = CubeLUT(title: "b", kind: .lut3D, size: 2,
                                                        table: [SIMD3<Float>](repeating: SIMD3(0, 0, 1), count: 8))
        let (dev, q, comp) = try #require(setup())
        let resolver = LayerColorResolver(lutProvider: luts) { _ in nil }
        comp.colorResolver = resolver
        func layer(_ e: ColorEffect) -> RenderNode {
            .layer(RenderLayer(content: .frame(pb, colorHint: info(w, h)),
                               effects: ClipEffects(segments: [EffectSegment(scope: [all], grade: e), EffectSegment()], masks: [])))
        }
        let red = effect("/luts/red.cube"), blue = effect("/luts/blue.cube")
        #expect(Compositor.maskedGradeOwner(red) != Compositor.maskedGradeOwner(blue))
        resolver.warm([(Compositor.maskedGradeColor(red), Compositor.maskedGradeMedia),
                       (Compositor.maskedGradeColor(blue), Compositor.maskedGradeMedia)])
        await resolver.waitUntilIdle()
        let a = try renderNodes(comp, dev, q, [layer(red)], w, h)
        let b = try renderNodes(comp, dev, q, [layer(blue)], w, h)
        let again = try renderNodes(comp, dev, q, [layer(red)], w, h)
        let i = (h / 2) * w + 10
        #expect(a[i][0] > 0.3 && a[i][2] < 0.02)
        #expect(b[i][2] > 0.1 && b[i][0] < 0.02)
        #expect(again == a)
    }

    @Test func maskedColourEffectThroughTheClipModel() throws {
        // A second Color effect with a Magic mask input: graded where the matte is 1, untouched where it is 0.
        let w = 64, h = 32
        let pb = makeBGRA(w, h) { _, _ in (90, 110, 130, 255) }
        var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(5, 1)), start: .zero)
        var first = ColorEffect(id: 1); first.basic.exposure = 0
        var second = ColorEffect(id: 2); second.basic.saturation = 0
        c.effects = [ClipEffect.colorGrade(first), ClipEffect.colorGrade(second)]
        var m = ClipMask.make(.rectangle, name: "M")
        m.usedByOpacity = false
        m.path.value = MaskPath.rectangle(Vec2(0.5, 0), Vec2(1, 1))
        m.feather.value = 0
        c.masks = [m]
        c.setMask(m.id, input: true, ofEffect: c.effects[1].id)
        let fx = c.effects(at: .zero)
        #expect(fx.segments.contains { $0.grade != nil })
        let plain = try render(pb, w, h, segs: [])
        let got = try render(pb, w, h, segs: fx.segments)
        let row = h / 2
        let r = got[row * w + 56]
        #expect(abs(r.x - r.y) < 0.01 && abs(r.y - r.z) < 0.01)                    // gray inside the mask
        #expect(abs(got[row * w + 8][0] - plain[row * w + 8][0]) < tolerance)      // untouched outside
    }

    @Test func rectangleHardEdgeMatchesCPU() throws {
        let m = shape(.rectangle(Vec2(0.2, 0.25), Vec2(0.7, 0.8)))
        let e = try worstError(64, 36, masks: [m])
        #expect(e <= tolerance, "worst \(e)")
    }

    @Test func featheredExpandedEllipseMatchesCPU() throws {
        let m = shape(.ellipse(center: Vec2(0.5, 0.5), radius: Vec2(0.3, 0.35)), feather: 8, expansion: 2)
        let e = try worstError(64, 48, masks: [m])
        #expect(e <= tolerance, "worst \(e)")
    }

    @Test func invertedWithOpacityMatchesCPU() throws {
        let m = shape(.ellipse(center: Vec2(0.4, 0.5), radius: Vec2(0.25, 0.3)), feather: 4, opacity: 0.6, inverted: true)
        let e = try worstError(48, 48, masks: [m])
        #expect(e <= tolerance, "worst \(e)")
    }

    @Test func modesCombineAsOnCPU() throws {
        let a = shape(.rectangle(Vec2(0.1, 0.1), Vec2(0.6, 0.7)), feather: 3)
        for mode in [MaskMode.subtract, .intersect, .difference] {
            let b = shape(.ellipse(center: Vec2(0.6, 0.55), radius: Vec2(0.3, 0.3)), feather: 6, mode: mode)
            let e = try worstError(64, 40, masks: [a, b])
            #expect(e <= tolerance, "\(mode) worst \(e)")
        }
        // A first subtracting mask starts from the full picture.
        let s = shape(.rectangle(Vec2(0.3, 0.3), Vec2(0.7, 0.7)), mode: .subtract)
        let e = try worstError(40, 40, masks: [s])
        #expect(e <= tolerance, "subtract-first worst \(e)")
        // A first Intersect starts from the full picture too (shows its area); a first Difference acts like Add.
        for mode in [MaskMode.intersect, .difference] {
            let f = shape(.ellipse(center: Vec2(0.5, 0.5), radius: Vec2(0.3, 0.3)), feather: 5, opacity: 0.8, mode: mode)
            let e1 = try worstError(40, 40, masks: [f])
            #expect(e1 <= tolerance, "\(mode)-first worst \(e1)")
        }
    }

    @Test func bezierPathMatchesCPU() throws {
        var p = MaskPath.ellipse(center: Vec2(0.5, 0.5), radius: Vec2(0.3, 0.3))
        p.moveVertex(0, to: Vec2(0.5, 0.05))
        let e = try worstError(64, 64, masks: [shape(p, feather: 2)])
        #expect(e <= tolerance, "worst \(e)")
    }

    @Test func maskCutsAfterTheBlur() throws {
        // Blur first, then the mask: the masked edge stays sharp (hard mask after the blur), the blur stays soft inside.
        let (dev, q, comp) = try #require(setup())
        let w = 48, h = 32
        let src: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8) = { x, _ in x < 24 ? (240, 240, 240, 255) : (10, 10, 10, 255) }
        let pb = makeBGRA(w, h, src)
        let m = shape(.rectangle(Vec2(0, 0), Vec2(1, 0.5)))
        var fx = ClipEffects(segments: [], masks: [m])
        fx.blur = 3
        let got = try renderNodes(comp, dev, q, [.layer(RenderLayer(content: .frame(pb, colorHint: info(w, h)), effects: fx))], w, h)
        var cpu = [SIMD4<Float>](repeating: .zero, count: w * h)
        for y in 0..<h { for x in 0..<w { let c = linear(src(x, y)); cpu[y * w + x] = SIMD4(c.x, c.y, c.z, 1) } }
        let blurred = GaussianBlur.blur(cpu, width: w, height: h, sigma: 3)
        var worst: Float = 0
        for y in 0..<h {
            for x in 0..<w {
                let cov = Float(MaskCoverage.coverage(at: Vec2(Double(x) + 0.5, Double(y) + 0.5), masks: [m],
                                                      frame: Vec2(Double(w), Double(h)), pixel: 1))
                for i in 0..<3 { worst = max(worst, abs(got[y * w + x][i] - blurred[y * w + x][i] * cov)) }
            }
        }
        #expect(worst < 0.01, "worst \(worst)")
        #expect(got[20 * w + 10].x == 0)                 // below the mask: cut
        #expect(got[10 * w + 24].x > 0.05 && got[10 * w + 24].x < 0.8)   // soft blur edge inside the mask
    }

    @Test func scaledLayerUsesTheFramesOwnPixels() throws {
        // A 32 x 18 layer drawn at scale 2 on a 64 x 36 canvas: the mask is in the clip's frame, its edge ramp one screen px.
        let (dev, q, comp) = try #require(setup())
        let w = 32, h = 18
        let color: (UInt8, UInt8, UInt8, UInt8) = (255, 255, 255, 255)
        let pb = makeBGRA(w, h) { _, _ in color }
        let m = shape(.ellipse(center: Vec2(0.5, 0.5), radius: Vec2(0.4, 0.4)))
        let t = ClipTransform(scale: Vec2(2, 2))
        let layer = RenderLayer(content: .frame(pb, colorHint: info(w, h)), transform: t, effects: ClipEffects(segments: [], masks: [m]))
        let got = try renderNodes(comp, dev, q, [.layer(layer)], 64, 36)
        var worst: Float = 0
        for y in 0..<36 {
            for x in 0..<64 {
                let p = Vec2((Double(x) + 0.5 - 32) / 2 + 16, (Double(y) + 0.5 - 18) / 2 + 9)
                let cov = Float(MaskCoverage.coverage(at: p, masks: [m], frame: Vec2(Double(w), Double(h)), pixel: 0.5))
                worst = max(worst, abs(got[y * 64 + x].x - cov))
            }
        }
        // Bilinear sampling of a flat white picture is exact; only the coverage differs.
        #expect(worst <= tolerance, "worst \(worst)")
    }

    @Test func nestedClipMaskAppliesToTheGroupImage() throws {
        let (dev, q, comp) = try #require(setup())
        let w = 40, h = 40
        let inner = makeBGRA(w, h) { _, _ in (255, 255, 255, 255) }
        let m = shape(.rectangle(Vec2(0.25, 0.25), Vec2(0.75, 0.75)), feather: 4)
        // Built from requests: a nested clip with masks must not be a plain group.
        let g = LayerGroup(clip: Clip.ID(), track: Track.ID(), sequence: Timeline.ID(), format: fmt(w, h),
                           effects: ClipEffects(segments: [], masks: [m]))
        let req = LayerRequest(clip: Clip.ID(), media: UUID(), track: Track.ID(), sourceTime: .zero, groups: [g])
        let nodes = RenderNode.tree(requests: [req], layers: [RenderLayer(content: .frame(inner, colorHint: info(w, h)))])
        guard case .styledGroup = nodes.first else { Issue.record("expected a styled group"); return }
        let got = try renderNodes(comp, dev, q, nodes, w, h)
        var worst: Float = 0
        for y in 0..<h {
            for x in 0..<w {
                let cov = Float(MaskCoverage.coverage(at: Vec2(Double(x) + 0.5, Double(y) + 0.5), masks: [m],
                                                      frame: Vec2(Double(w), Double(h)), pixel: 1))
                worst = max(worst, abs(got[y * w + x].x - cov))
            }
        }
        #expect(worst <= tolerance, "worst \(worst)")
    }

    @Test func noMasksStaysBitIdentical() throws {
        let (dev, q, comp) = try #require(setup())
        let pb = makeBGRA(16, 16) { x, y in (UInt8(x * 15), UInt8(y * 15), 90, 255) }
        let a = try renderNodes(comp, dev, q, [.layer(RenderLayer(content: .frame(pb, colorHint: info(16, 16))))], 16, 16)
        let b = try renderNodes(comp, dev, q, [.layer(RenderLayer(content: .frame(pb, colorHint: info(16, 16)),
                                                                  effects: ClipEffects(segments: [], masks: [])))], 16, 16)
        #expect(a == b)
    }
}
#endif
