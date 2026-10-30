#if canImport(Metal)
import CoreVideo
import Foundation
import Metal
import SQCore
import Testing
import simd
@testable import SQRender

// W3.1 look tests: each filter has analytic expectations on its CPU reference, and the GPU must match the reference image.

private typealias Px = (UInt8, UInt8, UInt8, UInt8)          // B, G, R, A

private func makeBGRA(_ w: Int, _ h: Int, _ f: (Int, Int) -> Px) -> CVPixelBuffer {
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

private func lin709(_ e: Float) -> Float { e < 0.081242858 ? e / 4.5 : powf((e + 0.09929682680944) / 1.09929682680944, 1 / 0.45) }

private func linear(_ c: Px) -> SIMD4<Float> {
    let a = Float(c.3) / 255
    return SIMD4(lin709(Float(c.2) / 255) * a, lin709(Float(c.1) / 255) * a, lin709(Float(c.0) / 255) * a, a)
}

/// Renders a `w x h` layer filling a `w x h` canvas with `filter` and returns the canvas (linear premultiplied).
private func renderGPU(_ w: Int, _ h: Int, _ src: (Int, Int) -> Px, _ filter: ImageFilter) throws -> [SIMD4<Float>]? {
    guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue(), let comp = try? Compositor(device: dev) else { return nil }
    let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
    td.usage = [.renderTarget, .shaderRead]; td.storageMode = .shared
    let t = dev.makeTexture(descriptor: td)!
    let hint = VideoTrackInfo(width: w, height: h, codec: "hvc1", bitDepth: 8, chroma: "4:2:0",
                              nominalFrameDuration: Time(1, 25), isVariableFrameRate: false)
    let fx = ClipEffects(segments: [EffectSegment(filter: filter), EffectSegment()])
    let layer = RenderLayer(content: .frame(makeBGRA(w, h, src), colorHint: hint), effects: fx)
    let cb = q.makeCommandBuffer()!
    try comp.render([layer], format: SequenceFormat(width: w, height: h, frameDuration: Time(1, 25)), into: t, commandBuffer: cb)
    cb.commit(); cb.waitUntilCompleted()
    #expect(cb.error == nil)
    var half = [Float16](repeating: 0, count: w * h * 4)
    t.getBytes(&half, bytesPerRow: w * 8, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    return (0..<(w * h)).map { (i: Int) -> SIMD4<Float> in
        let r = Float(half[i * 4]), g = Float(half[i * 4 + 1]), b = Float(half[i * 4 + 2]), a = Float(half[i * 4 + 3])
        return SIMD4(r, g, b, a)
    }
}

private func image(_ w: Int, _ h: Int, _ src: (Int, Int) -> Px) -> ImageFilters.Image {
    ImageFilters.Image(width: w, height: h) { x, y in linear(src(x, y)) }
}

/// The GPU result equals the reference image. The canvas is opaque black, so the reference is composited over black.
private func expectGPUMatches(_ w: Int, _ h: Int, _ src: @escaping (Int, Int) -> Px, _ filter: ImageFilter,
                              tol: Float = 0.01, reference: (ImageFilters.Image) -> ImageFilters.Image) throws {
    guard let got = try renderGPU(w, h, src, filter) else { return }
    let want = reference(image(w, h, src))
    var worst: Float = 0, at = 0
    for i in 0..<(w * h) {
        for c in 0..<3 where abs(got[i][c] - want.px[i][c]) > worst { worst = abs(got[i][c] - want.px[i][c]); at = i }
    }
    #expect(worst <= tol, "\(filter): worst \(worst) at (\(at % w), \(at / w)) got \(got[at]) want \(want.px[at])")
}

private let grey: Px = (128, 128, 128, 255)
private func lum(_ v: UInt8) -> Px { (v, v, v, 255) }

// MARK: Sharpen

@Suite struct SharpenLookTests {
    @Test func flatAreaIsUntouched() {
        let img = ImageFilters.Image(width: 8, height: 8) { _, _ in SIMD4(0.3, 0.3, 0.3, 1) }
        let out = ImageFilters.sharpen(img, amount: 2)
        #expect(abs(out[4, 4].x - 0.3) < 1e-6)
    }

    @Test func edgeOvershootsByTheLaplacian() {
        // 0.2 | 0.6 step: the last dark pixel's 3 x 3 mean is (6 * 0.2 + 3 * 0.6) / 9 = 1/3, so it goes to 0.2 - 2/15.
        let img = ImageFilters.Image(width: 8, height: 8) { x, _ in x < 4 ? SIMD4(0.2, 0.2, 0.2, 1) : SIMD4(0.6, 0.6, 0.6, 1) }
        let out = ImageFilters.sharpen(img, amount: 1)
        #expect(abs(out[3, 4].x - (0.2 - 2.0 / 15)) < 1e-5)
        #expect(abs(out[4, 4].x - (0.6 + 2.0 / 15)) < 1e-5)
        #expect(out[3, 4].w == 1)                               // opaque stays opaque
    }

    @Test func gpuMatchesReference() throws {
        let src: (Int, Int) -> Px = { x, y in (x / 4 + y / 4) % 2 == 0 ? lum(200) : lum(60) }
        try expectGPUMatches(32, 32, src, .sharpen(amount: 0.8)) { ImageFilters.sharpen($0, amount: 0.8) }
    }

    @Test func borderOfThePictureDoesNotBrighten() throws {
        // The neighborhood is clamped to the picture: transparent padding around it is not "darker" than the edge.
        let img = ImageFilters.Image(width: 8, height: 8) { _, _ in SIMD4(0.3, 0.3, 0.3, 1) }
        let out = ImageFilters.sharpen(img, amount: 2)
        #expect(abs(out[0, 0].x - 0.3) < 1e-6 && abs(out[7, 3].x - 0.3) < 1e-6 && out[0, 0].w == 1)
        // A picture smaller than the image: its edge stays, the padding stays empty.
        let inner = ImageFilters.Frame(center: SIMD2(8, 8), size: SIMD2(8, 8))
        let padded = ImageFilters.Image(width: 16, height: 16) { x, y in (4..<12).contains(x) && (4..<12).contains(y) ? SIMD4(0.3, 0.3, 0.3, 1) : .zero }
        let po = ImageFilters.sharpen(padded, amount: 2, frame: inner)
        #expect(abs(po[4, 4].x - 0.3) < 1e-6 && po[3, 4] == .zero)
        // On the GPU an opaque picture filling the canvas sits in a padded texture: its border must not brighten.
        guard let got = try renderGPU(40, 40, { _, _ in grey }, .sharpen(amount: 3)) else { return }
        let want = linear(grey).x
        for i in [0, 39, 40 * 39, 40 * 40 - 1, 40 * 20] { #expect(abs(got[i].x - want) < 0.003, "pixel \(i): \(got[i].x) want \(want)") }
    }
}

// MARK: Directional Blur

@Suite struct DirectionalBlurLookTests {
    private let column = ImageFilters.Image(width: 21, height: 21) { x, _ in x == 10 ? SIMD4(1, 1, 1, 1) : .zero }

    @Test func verticalSmearKeepsAVerticalLineSharp() {
        let out = ImageFilters.directionalBlur(column, d: SIMD2(0, 8))
        #expect(abs(out[10, 10].x - 1) < 1e-5 && out[9, 10].x < 1e-6 && out[11, 10].x < 1e-6)
    }

    @Test func horizontalSmearSpreadsTheLineOverItsLengthAndKeepsEnergy() {
        let out = ImageFilters.directionalBlur(column, d: SIMD2(8, 0))
        let row = (0..<21).map { out[$0, 10].x }
        #expect(abs(row.reduce(0, +) - 1) < 0.02)
        #expect(row[10] > 0 && row[13] > 0 && row[7] > 0)        // reaches 4 px either side
        #expect(row[15] == 0 && row[5] == 0)                    // and no further
    }

    @Test func gpuMatchesReference() throws {
        let src: (Int, Int) -> Px = { x, y in (x >= 12 && x < 20 && y >= 12 && y < 20) ? (40, 200, 240, 255) : lum(30) }
        let a = 30.0 * Double.pi / 180, len = 10.0
        try expectGPUMatches(32, 32, src, .directionalBlur(dx: len * sin(a), dy: -len * cos(a))) {
            ImageFilters.directionalBlur($0, d: SIMD2(Float(len * sin(a)), Float(-len * cos(a))))
        }
    }

    /// A long smear runs as two comb passes on the GPU (about 2 sqrt(n) taps instead of n): same picture as the one-pass
    /// reference, edges included (the intermediate is padded so taps beyond the edge still see the picture).
    @Test(arguments: [(90.0, 30.0), (140.0, 0.0), (70.0, 90.0), (120.0, 200.0)])
    func longSmearMatchesReference(len: Double, degrees: Double) throws {
        #expect(ImageFilters.smearPasses(ImageFilters.smearTaps(SIMD2(Float(len), 0))) != nil)
        let src: (Int, Int) -> Px = { x, y in
            (x >= 40 && x < 70 && y >= 30 && y < 50) ? (40, 200, 240, 255) : (x + y) % 23 == 0 ? lum(220) : lum(30)
        }
        let a = degrees * Double.pi / 180
        try expectGPUMatches(112, 80, src, .directionalBlur(dx: len * sin(a), dy: -len * cos(a))) {
            ImageFilters.directionalBlur($0, d: SIMD2(Float(len * sin(a)), Float(-len * cos(a))))
        }
    }

    @Test func shortSmearStaysOnePass() {
        #expect(ImageFilters.smearPasses(ImageFilters.smearTaps(SIMD2(10, 0))) == nil)
    }
}

// MARK: Mirror

@Suite struct MirrorLookTests {
    private let ramp: (Int, Int) -> Px = { x, y in (UInt8(x * 7), UInt8(y * 7), UInt8(255 - x * 7), 255) }

    @Test func zeroDegreesReflectsLeftOntoRight() {
        let img = image(32, 32, ramp)
        let out = ImageFilters.mirror(img, center: SIMD2(16, 16), degrees: 0)
        for x in 16..<32 { #expect(out[x, 5] == img[31 - x, 5]) }
        for x in 0..<16 { #expect(out[x, 5] == img[x, 5]) }
    }

    @Test func ninetyDegreesReflectsTopOntoBottom() {
        let img = image(32, 32, ramp)
        let out = ImageFilters.mirror(img, center: SIMD2(16, 16), degrees: 90)
        for y in 16..<32 { #expect(out[3, y] == img[3, 31 - y]) }
    }

    @Test func gpuMatchesReferenceWithAnOffCentreLine() throws {
        // Reflection Center 4 px right of the frame center (x = 20 in texture px of a 32 px frame).
        try expectGPUMatches(32, 32, ramp, .mirror(center: Vec2(4, 0), angle: 0)) {
            ImageFilters.mirror($0, center: SIMD2(20, 16), degrees: 0)
        }
        try expectGPUMatches(32, 32, ramp, .mirror(center: .zero, angle: 45)) {
            ImageFilters.mirror($0, center: SIMD2(16, 16), degrees: 45)
        }
    }
}

// MARK: Noise

@Suite struct NoiseLookTests {
    private let flat = ImageFilters.Image(width: 64, height: 64) { _, _ in SIMD4(0.4, 0.4, 0.4, 1) }

    @Test func meanStaysAndGrainHasTheRequestedStrength() {
        let out = ImageFilters.noise(flat, amount: 0.5, color: true, clip: true, seed: 7)
        let v = out.px.map(\.x)
        let mean = v.reduce(0, +) / Float(v.count)
        let sd = (v.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(v.count)).squareRoot()
        #expect(abs(mean - 0.4) < 0.01)
        #expect(abs(sd - 0.5 / Float(12).squareRoot()) < 0.01)      // uniform on +-0.25: sd = 0.5 / sqrt 12
    }

    @Test func monoNoiseMovesAllChannelsTogetherAndColourDoesNot() {
        let mono = ImageFilters.noise(flat, amount: 0.5, color: false, clip: true, seed: 3)
        #expect(mono.px.allSatisfy { $0.x == $0.y && $0.y == $0.z })
        let col = ImageFilters.noise(flat, amount: 0.5, color: true, clip: true, seed: 3)
        #expect(col.px.contains { $0.x != $0.y })
    }

    @Test func clipKeepsValuesInsideThePicture() {
        let bright = ImageFilters.Image(width: 32, height: 32) { _, _ in SIMD4(0.95, 0.95, 0.95, 1) }
        #expect(ImageFilters.noise(bright, amount: 1, color: true, clip: true, seed: 1).px.allSatisfy { $0.x <= 1 && $0.x >= 0 })
        #expect(ImageFilters.noise(bright, amount: 1, color: true, clip: false, seed: 1).px.contains { $0.x > 1 })
    }

    @Test func clipDoesNotCapHDRHighlights() {
        // A highlight at 3.0: Clip Result keeps 0...max(1, input), so values stay up to 3 and are not cut to 1.
        let hdr = ImageFilters.Image(width: 32, height: 32) { _, _ in SIMD4(3, 3, 3, 1) }
        let out = ImageFilters.noise(hdr, amount: 1, color: true, clip: true, seed: 5).px.map(\.x)
        #expect(out.allSatisfy { $0 <= 3 && $0 >= 2.5 })
        #expect(out.contains { $0 < 2.9 })
    }

    @Test func seedChangesThePattern() {
        let a = ImageFilters.noise(flat, amount: 0.5, color: true, clip: true, seed: 1)
        let b = ImageFilters.noise(flat, amount: 0.5, color: true, clip: true, seed: 2)
        #expect(a != b)
    }

    @Test func gpuMatchesReference() throws {
        // 64 px wide: the working texture has no margin, so its pixel grid (the hash input) is the frame's.
        try expectGPUMatches(64, 64, { _, _ in grey }, .noise(amount: 0.6, color: true, clip: true, seed: 12345)) {
            ImageFilters.noise($0, amount: 0.6, color: true, clip: true, seed: 12345)
        }
    }
}

// MARK: Glow

@Suite struct GlowLookTests {
    private let spot: (Int, Int) -> Px = { x, y in (x >= 14 && x < 18 && y >= 14 && y < 18) ? lum(255) : lum(40) }

    @Test func darkAreasFarFromLightAreUntouchedAndLightSpills() {
        let img = image(32, 32, spot)
        let out = ImageFilters.glow(img, threshold: 0.6, sigma: 2, intensity: 1, tint: nil)
        #expect(out[2, 2] == img[2, 2])                        // below threshold, nothing bright nearby
        #expect(out[13, 16].x > img[13, 16].x + 0.05)          // halo right next to the spot
        #expect(out[16, 16].x > 1)                             // the spot itself brightens (HDR)
    }

    @Test func tintColoursTheHalo() {
        let img = image(32, 32, spot)
        let out = ImageFilters.glow(img, threshold: 0.6, sigma: 2, intensity: 1, tint: SIMD3(1, 0, 0))
        #expect(out[12, 16].x > img[12, 16].x + 0.02)
        #expect(abs(out[12, 16].y - img[12, 16].y) < 1e-6)     // red glow adds nothing to green
    }

    @Test func gpuMatchesReference() throws {
        try expectGPUMatches(32, 32, spot, .glow(threshold: 0.5, sigma: 3, intensity: 1.5, color: nil)) {
            ImageFilters.glow($0, threshold: 0.5, sigma: 3, intensity: 1.5, tint: nil)
        }
        try expectGPUMatches(32, 32, spot, .glow(threshold: 0.5, sigma: 2, intensity: 1, color: SIMD3(0, 0.5, 1))) {
            ImageFilters.glow($0, threshold: 0.5, sigma: 2, intensity: 1,
                              tint: SIMD3(Compositor.lin(0), Compositor.lin(0.5), Compositor.lin(1)))
        }
    }

    @Test func thinHighlightGlowsSteadilyAtLargeRadius() throws {
        // A 1 px line at radius 40 (bright pass at 1/4 size): its glow must not vanish or jump as it moves by a pixel.
        var halo: [Float] = []
        for lineX in 60..<64 {
            guard let got = try renderGPU(128, 64, { x, _ in x == lineX ? lum(255) : lum(0) },
                                          .glow(threshold: 0.5, sigma: 20, intensity: 4, color: nil)) else { return }
            halo.append(got[32 * 128 + lineX - 15].x)
        }
        guard let lo = halo.min(), let hi = halo.max() else { return }
        #expect(lo > 0.005, "halo \(halo)")
        #expect(hi / lo < 1.2, "halo \(halo)")
    }

    @Test func largeRadiusRunsReducedAndStillGlows() throws {
        guard let got = try renderGPU(64, 64, { x, y in (x >= 28 && x < 36 && y >= 28 && y < 36) ? lum(255) : lum(0) },
                                      .glow(threshold: 0.5, sigma: 20, intensity: 2, color: nil)) else { return }
        #expect(got[32 * 64 + 10].x > 0.001)                    // 18 px away from the spot: some glow
        #expect(got[32 * 64 + 20].x > got[32 * 64 + 10].x)     // brighter nearer
    }
}

// MARK: Mosaic

@Suite struct MosaicLookTests {
    private let frame = ImageFilters.Frame(center: SIMD2(16, 16), size: SIMD2(32, 32))

    @Test func blocksAreAverages() {
        // Horizontal ramp 0...31 over 4 columns of 8: each block's value is the mean of its 8 columns.
        let img = ImageFilters.Image(width: 32, height: 32) { x, _ in SIMD4(Float(x) / 31, 0, 0, 1) }
        let out = ImageFilters.mosaic(img, frame: frame, columns: 4, rows: 2, sharp: false)
        #expect(abs(out[0, 0].x - 3.5 / 31) < 1e-5)
        #expect(out[7, 31] == out[0, 0])
        #expect(abs(out[8, 0].x - 11.5 / 31) < 1e-5)
    }

    @Test func bigBlocksAreTrueAverages() throws {
        // One block over 128 x 128 with a single bright column: the average is exactly 1/128 of it, not a sampled guess.
        let src: (Int, Int) -> Px = { x, _ in x == 1 ? lum(255) : lum(0) }
        let big = ImageFilters.Frame(center: SIMD2(64, 64), size: SIMD2(128, 128))
        let out = ImageFilters.mosaic(image(128, 128, src), frame: big, columns: 1, rows: 1, sharp: false)
        #expect(abs(out[50, 50].x - 1.0 / 128) < 1e-6)
        guard let got = try renderGPU(128, 128, src, .mosaic(columns: 1, rows: 1, sharp: false)) else { return }
        #expect(abs(got[50 * 128 + 50].x - 1.0 / 128) < 0.0005, "got \(got[50 * 128 + 50].x)")
    }

    @Test func sharpColoursTakeTheCentrePixel() {
        let img = ImageFilters.Image(width: 32, height: 32) { x, _ in SIMD4(Float(x) / 31, 0, 0, 1) }
        let out = ImageFilters.mosaic(img, frame: frame, columns: 4, rows: 1, sharp: true)
        #expect(out[0, 10].x == 4.0 / 31)                       // block 0...8: center pixel x = 4
    }

    @Test func blocksMatchingTheContentAreIdentity() {
        let src: (Int, Int) -> Px = { x, y in x < 16 ? (y < 16 ? lum(10) : lum(200)) : (y < 16 ? (0, 0, 255, 255) : (255, 0, 0, 255)) }
        let img = image(32, 32, src)
        let out = ImageFilters.mosaic(img, frame: frame, columns: 2, rows: 2, sharp: false)
        #expect(zip(out.px, img.px).allSatisfy { simd_reduce_max(simd_abs($0 - $1)) < 1e-6 })
    }

    @Test func gpuMatchesReference() throws {
        let src: (Int, Int) -> Px = { x, y in (UInt8(x * 8), UInt8((x * y) & 255), UInt8(y * 8), 255) }
        try expectGPUMatches(32, 32, src, .mosaic(columns: 4, rows: 8, sharp: false)) {
            ImageFilters.mosaic($0, frame: frame, columns: 4, rows: 8, sharp: false)
        }
        try expectGPUMatches(32, 32, src, .mosaic(columns: 4, rows: 4, sharp: true)) {
            ImageFilters.mosaic($0, frame: frame, columns: 4, rows: 4, sharp: true)
        }
    }
}

// MARK: Through the clip model

@Suite struct ImageFilterPipelineTests {
    @Test func clipEffectReachesTheRenderer() throws {
        // A Mirror applied to a clip (catalog defaults) makes the right half the left half reversed on screen.
        var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(5, 1)), start: .zero)
        c.effects = [ClipEffect.make(kind: ClipEffect.mirrorKind)!]
        guard case .mirror(let center, let angle)? = c.effects(at: Time(1, 1)).segments.first?.filter else {
            Issue.record("no mirror"); return
        }
        let src: (Int, Int) -> Px = { x, _ in (0, 0, UInt8(x * 8), 255) }
        guard let got = try renderGPU(32, 32, src, .mirror(center: center, angle: angle)) else { return }
        for x in 16..<32 { #expect(abs(got[5 * 32 + x].x - linear(src(31 - x, 0)).x) < 0.005) }
    }
}

// MARK: Unsharp Mask

@Suite struct UnsharpMaskLookTests {
    private let edge = ImageFilters.Image(width: 24, height: 24) { x, _ in x < 12 ? SIMD4(0.2, 0.2, 0.2, 1) : SIMD4(0.6, 0.6, 0.6, 1) }

    @Test func amountZeroIsIdentity() {
        #expect(ImageFilters.unsharpMask(edge, sigma: 1.5, amount: 0, threshold: 0) == edge)
    }

    @Test func overshootsAtAnEdgeAndLeavesFlatAreasAlone() {
        let out = ImageFilters.unsharpMask(edge, sigma: 1.5, amount: 1, threshold: 0)
        #expect(out[11, 5].x < 0.2 - 0.01 && out[12, 5].x > 0.6 + 0.01)
        #expect(abs(out[2, 5].x - 0.2) < 1e-4 && abs(out[21, 5].x - 0.6) < 1e-4)
        #expect(out[0, 0].w == 1)
    }

    @Test func thresholdKeepsSmallDifferences() {
        // The edge step is 0.4; a threshold above the largest local difference leaves the picture untouched.
        #expect(ImageFilters.unsharpMask(edge, sigma: 1.5, amount: 1, threshold: 0.4) == edge)
        let some = ImageFilters.unsharpMask(edge, sigma: 1.5, amount: 1, threshold: 0.1)
        #expect(some[11, 5].x < 0.2 - 0.01)
    }

    @Test func gpuMatchesReference() throws {
        let src: (Int, Int) -> Px = { x, y in (x / 4 + y / 4) % 2 == 0 ? lum(200) : lum(60) }
        try expectGPUMatches(32, 32, src, .unsharpMask(sigma: 1.5, amount: 0.8, threshold: 0.02)) {
            ImageFilters.unsharpMask($0, sigma: 1.5, amount: 0.8, threshold: 0.02)
        }
    }

    @Test func borderOfThePictureDoesNotBrighten() throws {
        guard let got = try renderGPU(40, 40, { _, _ in grey }, .unsharpMask(sigma: 2, amount: 3, threshold: 0)) else { return }
        let want = linear(grey).x
        for i in [0, 39, 40 * 39, 40 * 40 - 1, 40 * 20] { #expect(abs(got[i].x - want) < 0.003, "pixel \(i): \(got[i].x)") }
    }

    @Test func costAt1080pStaysUnderBudget() throws {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue(), let comp = try? Compositor(device: dev) else { return }
        let W = 1920, H = 1080
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: W, height: H, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]; td.storageMode = .private
        let t = dev.makeTexture(descriptor: td)!
        let hint = VideoTrackInfo(width: W, height: H, codec: "hvc1", bitDepth: 8, chroma: "4:2:0",
                                  nominalFrameDuration: Time(1, 25), isVariableFrameRate: false)
        let frame = makeBGRA(W, H) { x, y in (UInt8(x & 255), UInt8(y & 255), 90, 255) }
        let fx = ClipEffects(segments: [EffectSegment(filter: .unsharpMask(sigma: 3, amount: 1, threshold: 0.02)), EffectSegment()])
        var ms: [Double] = []
        for k in 0..<25 {
            let start = DispatchTime.now().uptimeNanoseconds
            let cb = q.makeCommandBuffer()!
            try comp.render([RenderLayer(content: .frame(frame, colorHint: hint), effects: fx)],
                            format: SequenceFormat(width: W, height: H, frameDuration: Time(1, 25)), into: t, commandBuffer: cb)
            cb.commit(); cb.waitUntilCompleted()
            if k >= 5 { ms.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6) }
        }
        ms.sort()
        let p95 = ms[Int(Double(ms.count - 1) * 0.95)]
        print("unsharp mask 1080p p95 \(String(format: "%.2f", p95)) ms, median \(String(format: "%.2f", ms[ms.count / 2])) ms")
        // Same 16 ms ceiling as the adjustment tick test (shared machine); the printed median is the measurement.
        #expect(p95 < 16, "p95 \(p95) ms")
    }
}
#endif
