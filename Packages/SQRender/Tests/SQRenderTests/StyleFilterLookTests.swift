#if canImport(Metal)
import CoreVideo
import Foundation
import Metal
import SQCore
import Testing
import simd
@testable import SQRender

// FB-T2 style filters: analytic expectations on the CPU references, and the GPU (preview and export run the same
// compositor) must match the reference image for every filter.

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

private func linear(_ c: Px) -> SIMD4<Float> {
    let a = Float(c.3) / 255
    return SIMD4(StyleFilters.dec(Float(c.2) / 255) * a, StyleFilters.dec(Float(c.1) / 255) * a, StyleFilters.dec(Float(c.0) / 255) * a, a)
}

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
        SIMD4(Float(half[i * 4]), Float(half[i * 4 + 1]), Float(half[i * 4 + 2]), Float(half[i * 4 + 3]))
    }
}

private func image(_ w: Int, _ h: Int, _ src: (Int, Int) -> Px) -> ImageFilters.Image {
    ImageFilters.Image(width: w, height: h) { x, y in linear(src(x, y)) }
}

private func whole(_ img: ImageFilters.Image) -> ImageFilters.Frame {
    ImageFilters.Frame(center: SIMD2(Float(img.width), Float(img.height)) / 2, size: SIMD2(Float(img.width), Float(img.height)))
}

private func ref(_ f: ImageFilter, _ img: ImageFilters.Image) -> ImageFilters.Image {
    StyleFilters.reference(f, img, frame: whole(img))!
}

/// GPU result over the opaque black canvas equals the premultiplied reference (color channels).
private func expectGPUMatches(_ w: Int, _ h: Int, _ src: @escaping (Int, Int) -> Px, _ filter: ImageFilter, tol: Float = 0.01) throws {
    guard let got = try renderGPU(w, h, src, filter) else { return }
    let want = ref(filter, image(w, h, src))
    var worst: Float = 0, at = 0
    for i in 0..<(w * h) {
        for c in 0..<3 where abs(got[i][c] - want.px[i][c]) > worst { worst = abs(got[i][c] - want.px[i][c]); at = i }
    }
    #expect(worst <= tol, "\(filter): worst \(worst) at (\(at % w), \(at / w)) got \(got[at]) want \(want.px[at])")
}

private func lum(_ v: UInt8) -> Px { (v, v, v, 255) }
private func ramp(_ x: Int, _ y: Int) -> Px { (UInt8(x * 7 % 256), UInt8(y * 7 % 256), UInt8(255 - x * 7 % 256), 255) }
private func patches(_ x: Int, _ y: Int) -> Px {
    let all: [Px] = [(30, 90, 200, 255), (220, 40, 120, 255), (128, 128, 128, 255), (10, 240, 60, 255)]
    return all[(x / 8 + y / 8) % 4]
}

@Suite struct StyleFilterColourTests {
    @Test func invertBlackIsWhiteAndBlendKeepsTheOriginal() {
        let img = image(4, 4) { _, _ in lum(0) }
        #expect(abs(ref(.invert(channel: 0, blend: 0), img)[1, 1].x - 1) < 1e-5)
        #expect(abs(ref(.invert(channel: 0, blend: 1), img)[1, 1].x) < 1e-6)
        let red = ref(.invert(channel: 1, blend: 0), img)[1, 1]
        #expect(abs(red.x - 1) < 1e-5)
        #expect(red.y < 1e-6)
        let alpha = ref(.invert(channel: 4, blend: 0), img)[1, 1]
        #expect(alpha.w < 1e-6)
    }

    @Test func posterizeTwoLevelsLeavesOnlyBlackAndWhite() {
        let img = image(16, 16, ramp)
        let out = ref(.posterize(levels: 2), img)
        for p in out.px { for c in 0..<3 { #expect(abs(p[c]) < 1e-5 || abs(p[c] - 1) < 1e-5) } }
    }

    @Test func blackAndWhiteHasNoColourAndTintMapsLuma() {
        let img = image(16, 16, ramp)
        let bw = ref(.tint(black: .zero, white: SIMD3(1, 1, 1), amount: 1), img)
        #expect(bw.px.allSatisfy { abs($0.x - $0.y) < 1e-5 && abs($0.y - $0.z) < 1e-5 })
        let duo = ref(.tint(black: SIMD3(1, 0, 0), white: SIMD3(1, 0, 0), amount: 1), img)
        #expect(duo.px.allSatisfy { abs($0.x - 1) < 1e-5 && $0.y < 1e-6 })
    }

    @Test func contrastMinus100IsFlatGreyAndBrightnessLifts() {
        let img = image(16, 16, ramp)
        let flat = ref(.brightnessContrast(brightness: 0, contrast: -1), img)
        let g = StyleFilters.dec(0.5)
        #expect(flat.px.allSatisfy { abs($0.x - g) < 0.02 })
        let lifted = ref(.brightnessContrast(brightness: 0.5, contrast: 0), img)
        #expect(zip(lifted.px, img.px).allSatisfy { $0.y >= $1.y })
    }

    @Test func vignetteDarkensTheCornersNotTheCentre() {
        let img = image(64, 64) { _, _ in lum(180) }
        let dark = ref(.vignette(amount: -2, midpoint: 0.5, roundness: 0, feather: 0.5), img)
        #expect(abs(dark[32, 32].x - img[32, 32].x) < 1e-4)
        #expect(dark[0, 0].x < img[0, 0].x * 0.4)
        let light = ref(.vignette(amount: 2, midpoint: 0.5, roundness: 0, feather: 0.5), img)
        #expect(light[0, 0].x > img[0, 0].x + 0.1)
        #expect(abs(light[32, 32].x - img[32, 32].x) < 1e-4)
        // Roundness changes the shape: a circle on a wide frame reaches the side edges later than the ellipse.
        let wide = image(128, 32) { _, _ in lum(180) }
        let ellipse = ref(.vignette(amount: -2, midpoint: 0.5, roundness: 0, feather: 0.2), wide)
        let circle = ref(.vignette(amount: -2, midpoint: 0.5, roundness: 1, feather: 0.2), wide)
        #expect(circle[16, 16].x < ellipse[16, 16].x)
    }

    @Test func strobeCopiesItsColourOrHidesThePicture() {
        let img = image(8, 8, ramp)
        let flash = ref(.strobe(color: SIMD3(1, 1, 1), blend: 0, op: 0, transparent: false), img)
        #expect(flash.px.allSatisfy { abs($0.x - 1) < 1e-5 && abs($0.z - 1) < 1e-5 })
        let gone = ref(.strobe(color: SIMD3(1, 1, 1), blend: 0, op: 0, transparent: true), img)
        #expect(gone.px.allSatisfy { $0 == .zero })
    }

    @Test func alphaAdjust() {
        let img = image(8, 8) { _, _ in (0, 0, 255, 255) }
        #expect(ref(.alphaAdjust(opacity: 1, ignore: false, invert: true, maskOnly: false), img).px.allSatisfy { $0.w == 0 })
        let half = ref(.alphaAdjust(opacity: 0.5, ignore: false, invert: false, maskOnly: true), img)
        #expect(half.px.allSatisfy { abs($0.w - 0.5) < 1e-6 && abs($0.y - 0.5) < 1e-6 })
    }
}

@Suite struct StyleFilterGeometryTests {
    @Test func flipsMirrorThePicture() {
        let img = image(32, 16, ramp)
        let h = ref(.flip(horizontal: true, vertical: false), img)
        for x in 0..<32 { #expect(simd_reduce_max(simd_abs(h[x, 3] - img[31 - x, 3])) < 1e-5) }
        let v = ref(.flip(horizontal: false, vertical: true), img)
        for y in 0..<16 { #expect(simd_reduce_max(simd_abs(v[5, y] - img[5, 15 - y])) < 1e-5) }
    }

    @Test func rgbSplitMovesRedOneWayAndBlueTheOther() {
        let img = ImageFilters.Image(width: 32, height: 8) { x, _ in x == 16 ? SIMD4(1, 1, 1, 1) : SIMD4(0, 0, 0, 1) }
        let out = ref(.rgbSplit(dx: 4, dy: 0, radial: false, mix: 0), img)
        #expect(abs(out[20, 4].x - 1) < 1e-5 && out[20, 4].z < 1e-6)
        #expect(abs(out[12, 4].z - 1) < 1e-5 && out[12, 4].x < 1e-6)
        #expect(abs(out[16, 4].y - 1) < 1e-5 && out[16, 4].x < 1e-6)
    }

    @Test func radialBlurSpinKeepsTheCentreAndZoomKeepsRadialLines() {
        // A horizontal line through the center: Zoom smears along it (stays), Spin smears across it (spreads).
        let img = ImageFilters.Image(width: 33, height: 33) { _, y in y == 16 ? SIMD4(1, 1, 1, 1) : SIMD4(0, 0, 0, 1) }
        let zoom = ref(.radialBlur(center: .zero, amount: 30, zoom: true, high: true), img)
        #expect(zoom[28, 16].x > 0.9)
        let spin = ref(.radialBlur(center: .zero, amount: 30, zoom: false, high: true), img)
        #expect(spin[28, 16].x < 0.5)
        #expect(spin[28, 14].x > 0.01)
    }

    @Test func twirlAndSpherizeLeaveTheOutsideAlone() {
        let img = image(64, 64, ramp)
        // Twirl radius 0.25 of 64 = 16 px around the center.
        let tw = ref(.twirl(center: .zero, angle: 90, radius: 0.25), img)
        #expect(simd_reduce_max(simd_abs(tw[2, 2] - img[2, 2])) < 1e-6)
        #expect(simd_reduce_max(simd_abs(tw[40, 32] - img[40, 32])) > 1e-3)
        let sp = ref(.spherize(center: .zero, radius: 16, strength: 1), img)
        #expect(simd_reduce_max(simd_abs(sp[2, 2] - img[2, 2])) < 1e-6)
        #expect(simd_reduce_max(simd_abs(sp[40, 32] - img[40, 32])) > 1e-3)
    }

    @Test func waveWarpMovesAcrossItsDirectionAndPinsEdges() {
        // Direction 90 (waves travel right): a horizontal line moves up and down by up to Wave Height.
        let img = ImageFilters.Image(width: 64, height: 32) { _, y in y == 16 ? SIMD4(1, 1, 1, 1) : SIMD4(0, 0, 0, 1) }
        let out = ref(.waveWarp(type: 1, height: 4, width: 32, direction: 90, phase: 0, pinning: 0), img)
        // Square wave: first half cycle +1 (picture read 4 px "across" = up in y-down texture: shows at y 20), then -1.
        #expect(out[8, 20].x > 0.9 || out[8, 12].x > 0.9)
        #expect(out[8, 16].x < 0.1)
        let pinned = ref(.waveWarp(type: 1, height: 4, width: 32, direction: 90, phase: 0, pinning: 1), img)
        #expect(pinned[0, 16].x > 0.9)                          // left edge held
    }

    @Test func lensDistortionKeepsTheCentreAndFillsBulgedCorners() {
        let img = image(64, 64, ramp)
        let bulge = ref(.lensDistortion(curvature: -0.8, decenter: .zero, fillAlpha: true, fill: .zero), img)
        #expect(simd_reduce_max(simd_abs(bulge[32, 32] - img[32, 32])) < 0.05)
        #expect(bulge[0, 0].w == 0)                              // corner reads outside the picture: transparent
        let filled = ref(.lensDistortion(curvature: -0.8, decenter: .zero, fillAlpha: false, fill: SIMD3(1, 0, 0)), img)
        #expect(filled[0, 0] == SIMD4(1, 0, 0, 1))
        let pinch = ref(.lensDistortion(curvature: 0.8, decenter: .zero, fillAlpha: false, fill: SIMD3(1, 0, 0)), img)
        #expect(pinch[0, 0].w == 1)                              // pincushion only reads inside: no fill
        #expect(pinch[0, 0] != SIMD4(1, 0, 0, 1))
    }

    @Test func lightLeakBrightensNearItsCentreOnly() {
        let img = image(64, 64) { _, _ in lum(80) }
        let out = ref(.lightLeak(color1: SIMD3(1, 0.5, 0.1), color2: SIMD3(1, 0.5, 0.1), intensity: 1, center: Vec2(1, 0), size: 0.3, angle: 0), img)
        #expect(out[63, 32].x > img[63, 32].x + 0.1)            // right edge: under the leak
        #expect(out[63, 32].x > out[63, 32].z)                   // warm
        #expect(simd_reduce_max(simd_abs(out[0, 32] - img[0, 32])) < 0.01)
    }

    @Test func halftoneMakesDotsThatGrowWithShadows() {
        let dark = ref(.halftone(size: 8, angle: 0, softness: 0, color: false, blend: 1), image(64, 64) { _, _ in lum(40) })
        let bright = ref(.halftone(size: 8, angle: 0, softness: 0, color: false, blend: 1), image(64, 64) { _, _ in lum(220) })
        func mean(_ i: ImageFilters.Image) -> Float { i.px.reduce(0) { $0 + $1.x } / Float(i.px.count) }
        #expect(mean(dark) < mean(bright))
        let black = ref(.halftone(size: 8, angle: 0, softness: 0, color: false, blend: 1), image(64, 64) { _, _ in lum(0) })
        let white = ref(.halftone(size: 8, angle: 0, softness: 0, color: false, blend: 1), image(64, 64) { _, _ in lum(255) })
        #expect(mean(black) < 0.05 && mean(white) > 0.95)
        let img = image(32, 32) { _, _ in (200, 80, 40, 255) }
        #expect(ref(.halftone(size: 8, angle: 0, softness: 0.2, color: false, blend: 0), img)[3, 3] == img[3, 3])
        let col = ref(.halftone(size: 8, angle: 0, softness: 0.2, color: true, blend: 1), img)
        #expect(col.px.contains { $0.z > $0.x * 2 })
    }

    @Test func tileRepeatsThePictureAndMirrorsAlternateTiles() {
        let img = image(64, 64, ramp)
        let t = ref(.tile(columns: 2, rows: 1, offset: .zero, mirror: false), img)
        // Output column x reads source column 2x mod 64 (texel centers): x = 8 -> 16, x = 40 -> 16 as well.
        #expect(simd_reduce_max(simd_abs(t[8, 20] - img[16, 20])) < 0.05)
        #expect(simd_reduce_max(simd_abs(t[40, 20] - img[16, 20])) < 0.05)
        let m = ref(.tile(columns: 2, rows: 1, offset: .zero, mirror: true), img)
        #expect(simd_reduce_max(simd_abs(m[8, 20] - img[16, 20])) < 0.05)
        #expect(simd_reduce_max(simd_abs(m[55, 20] - img[16, 20])) < 0.1)       // second tile runs backwards
        #expect(simd_reduce_max(simd_abs(ref(.tile(columns: 1, rows: 1, offset: .zero, mirror: false), img)[10, 10] - img[10, 10])) < 0.02)
    }

    @Test func kaleidoscopeIsMirrorSymmetricAcrossItsSliceEdge() {
        let img = image(64, 64, ramp)
        let k = ref(.kaleidoscope(center: .zero, segments: 4, angle: 0, zoom: 1), img)
        // Four slices: edges on the axes, so the result is symmetric about both axes through the center.
        for (x, y) in [(10, 20), (45, 12), (5, 50)] {
            #expect(simd_reduce_max(simd_abs(k[x, y] - k[63 - x, y])) < 0.1)
            #expect(simd_reduce_max(simd_abs(k[x, y] - k[x, 63 - y])) < 0.1)
        }
    }

    @Test func edgeFeatherFadesTheAlphaTowardsTheFrameEdge() {
        let img = image(64, 64) { _, _ in lum(80) }
        let f = ref(.edgeFeather(amount: 16), img)
        // Distance of the texel center to the nearest edge d = min(x + 0.5, ...): coverage smoothstep(0, 16, d).
        for (x, y) in [(0, 32), (4, 32), (8, 32), (31, 0), (31, 6)] {
            let d = min(Float(min(x, 63 - x)), Float(min(y, 63 - y))) + 0.5
            let want = StyleFilters.smoothstep(0, 16, d)
            #expect(abs(f[x, y].w - want) < 1e-5, "(\(x), \(y))")
            #expect(abs(f[x, y].x - img[x, y].x * want) < 1e-5)          // premultiplied: color fades with the alpha
        }
        #expect(f[32, 32] == img[32, 32])                                  // beyond the feather: untouched
        #expect(ref(.edgeFeather(amount: 0), img)[0, 0] == img[0, 0])
    }

    @Test func glitchDisplaceShiftsWholeBandsAndSplitsColour() {
        let img = image(64, 64) { x, _ in lum(UInt8(x * 3)) }
        // Density 0, no split: nothing moves.
        let still = ref(.glitch(amount: 10, block: 8, split: 0, density: 0, seed: 3), img)
        #expect(simd_reduce_max(simd_abs(still[20, 20] - img[20, 20])) < 1e-6)
        // Density 1: every band moves, each row of one band by the same shift; the same seed repeats exactly.
        let a = ref(.glitch(amount: 10, block: 8, split: 0, density: 1, seed: 3), img)
        let b = ref(.glitch(amount: 10, block: 8, split: 0, density: 1, seed: 3), img)
        #expect(a[30, 12] == b[30, 12])
        #expect(a[30, 8] == a[30, 15])                                     // same band (rows 8..<16)
        var moved = 0
        for band in 0..<8 where simd_reduce_max(simd_abs(a[30, band * 8] - img[30, band * 8])) > 0.001 { moved += 1 }
        #expect(moved >= 6)
        let c = ref(.glitch(amount: 10, block: 8, split: 0, density: 1, seed: 4), img)
        #expect((0..<8).contains { simd_reduce_max(simd_abs(a[30, $0 * 8] - c[30, $0 * 8])) > 0.001 })
        // Split pulls red and blue apart horizontally only: on a horizontal ramp red reads left, blue right.
        let sp = ref(.glitch(amount: 0, block: 8, split: 4, density: 0, seed: 1), img)
        #expect(sp[30, 30].x < img[30, 30].x && sp[30, 30].z > img[30, 30].z)
    }

    @Test func gradientHasKnownPixelValues() {
        let img = image(64, 64) { _, _ in lum(80) }
        // Linear black -> white from the top edge to the bottom edge (frame center is texel 32; y down).
        let lin = ref(.gradient(color1: .zero, color2: SIMD3(1, 1, 1), start: Vec2(0, -32), end: Vec2(0, 32), radial: false, blend: 1), img)
        // Row r center is at r + 0.5: t = (r + 0.5) / 64; display-encoded gray t becomes linear dec(t).
        for r in [0, 16, 32, 63] {
            let t = (Float(r) + 0.5) / 64, want = StyleFilters.dec(t)
            #expect(abs(lin[10, r].x - want) < 0.002, "row \(r)")
            #expect(abs(lin[10, r].x - lin[50, r].x) < 1e-6)       // constant along the row
        }
        // Blend 0.5 mixes display-encoded values with the picture; alpha is kept.
        let half = ref(.gradient(color1: SIMD3(1, 0, 0), color2: SIMD3(1, 0, 0), start: Vec2(0, -32), end: Vec2(0, 32), radial: false, blend: 0.5), img)
        let e = StyleFilters.enc(img[5, 5].x)
        #expect(abs(half[5, 5].x - StyleFilters.dec(e + (1 - e) * 0.5)) < 0.002)
        #expect(abs(half[5, 5].y - StyleFilters.dec(e * 0.5)) < 0.002 && half[5, 5].w == 1)
        // Radial: center color at the start point, end color at and beyond the radius.
        let rad = ref(.gradient(color1: SIMD3(1, 1, 1), color2: .zero, start: .zero, end: Vec2(0, 16), radial: true, blend: 1), img)
        #expect(abs(rad[32, 32].x - StyleFilters.dec(1 - Float(0.5 * 2.0.squareRoot() / 16))) < 0.002)   // texel center (32.5, 32.5) is 0.707 px from the start
        #expect(rad[0, 0].x < 0.001 && rad[63, 63].x < 0.001)
        // Start == end: no division by zero, the start color everywhere.
        let flat = ref(.gradient(color1: SIMD3(1, 1, 1), color2: .zero, start: .zero, end: .zero, radial: false, blend: 1), img)
        #expect(flat[3, 3].x > 0.99)
    }
}

@Suite struct StyleFilterGPUTests {
    @Test func everyFilterMatchesItsReference() throws {
        let filters: [ImageFilter] = [
            .vignette(amount: -1.5, midpoint: 0.5, roundness: 0, feather: 0.5),
            .vignette(amount: 1.5, midpoint: 0.3, roundness: -0.6, feather: 0.3),
            .invert(channel: 0, blend: 0.25), .invert(channel: 2, blend: 0), .invert(channel: 4, blend: 0.5),
            .tint(black: SIMD3(0.1, 0, 0.4), white: SIMD3(1, 0.9, 0.3), amount: 0.8),
            .brightnessContrast(brightness: 0.2, contrast: 0.4),
            .strobe(color: SIMD3(1, 0.5, 0), blend: 0.3, op: 3, transparent: false),
            .strobe(color: SIMD3(1, 1, 1), blend: 0.4, op: 0, transparent: true),
            .alphaAdjust(opacity: 0.6, ignore: false, invert: false, maskOnly: false),
            .flip(horizontal: true, vertical: false), .flip(horizontal: true, vertical: true),
            .twirl(center: Vec2(3, -2), angle: 120, radius: 0.4),
            .waveWarp(type: 0, height: 3, width: 12, direction: 90, phase: 0.3, pinning: 0),
            .waveWarp(type: 2, height: 2, width: 9, direction: 30, phase: 0.1, pinning: 1),
            .spherize(center: .zero, radius: 12, strength: 0.8),
            .spherize(center: Vec2(-4, 4), radius: 14, strength: -0.6),
            .rgbSplit(dx: 3, dy: 1, radial: false, mix: 0.2), .rgbSplit(dx: 4, dy: 0, radial: true, mix: 0),
            .radialBlur(center: .zero, amount: 25, zoom: false, high: true),
            .radialBlur(center: Vec2(4, 2), amount: 30, zoom: true, high: false),
            .lensDistortion(curvature: -0.6, decenter: Vec2(0.1, -0.2), fillAlpha: true, fill: .zero),
            .lensDistortion(curvature: 0.5, decenter: .zero, fillAlpha: false, fill: SIMD3(0.2, 0.4, 1)),
            .lightLeak(color1: SIMD3(1, 0.6, 0.2), color2: SIMD3(1, 0.2, 0.5), intensity: 1.2, center: Vec2(0.8, -0.5), size: 0.5, angle: 1),
            .gradient(color1: SIMD3(0.1, 0.2, 0.9), color2: SIMD3(1, 0.8, 0), start: Vec2(-10, -12), end: Vec2(8, 14), radial: false, blend: 0.8),
            .gradient(color1: SIMD3(1, 1, 1), color2: SIMD3(0, 0.3, 0.6), start: Vec2(2, -3), end: Vec2(14, 9), radial: true, blend: 1),
            .halftone(size: 6, angle: 30, softness: 0.3, color: false, blend: 0.9),
            .halftone(size: 5, angle: 10, softness: 0.1, color: true, blend: 1),
            .tile(columns: 2.5, rows: 3, offset: Vec2(0.2, -0.3), mirror: false),
            .tile(columns: 3, rows: 2, offset: Vec2(0.1, 0), mirror: true),
            .kaleidoscope(center: Vec2(2, -3), segments: 6, angle: 20, zoom: 1.5),
            .kaleidoscope(center: .zero, segments: 5, angle: -40, zoom: 0.7),
            .edgeFeather(amount: 9), .edgeFeather(amount: 30),
            .glitch(amount: 6, block: 5, split: 3, density: 0.7, seed: 11), .glitch(amount: 4, block: 7, split: 0, density: 1, seed: 2),
        ]
        for f in filters { try expectGPUMatches(32, 32, ramp, f) }
        try expectGPUMatches(32, 32, patches, .posterize(levels: 4))
    }

    @Test func stageWarpMatchesTheReference() throws {
        var s = StageTransform.identity
        s.position = Vec2(3, -2); s.rotation = 20; s.scale = 1.3; s.scaleY = 0.9; s.anchor = Vec2(2, 1); s.opacity = 0.7
        let f = try #require(ImageFilter.stage(s))
        try expectGPUMatches(32, 32, ramp, f)
    }

    @Test func stageWarpMovesThePicture() throws {
        // A Transform moving the picture 4 px right: output x reads source x - 4; opacity 50 % halves it.
        var s = StageTransform.identity
        s.position = Vec2(4, 0); s.opacity = 0.5
        let f = try #require(ImageFilter.stage(s))
        let img = image(32, 8) { x, _ in (0, 0, UInt8(x * 8), 255) }
        let out = ref(f, img)
        #expect(abs(out[10, 3].x - img[6, 3].x * 0.5) < 1e-5)
        #expect(out[2, 3].w == 0)                                    // moved in from outside the picture: nothing
    }

    @Test func edgeFillMirrorsAndBlursWhatTheStageUncovers() throws {
        var st = StageTransform.identity
        st.position = Vec2(4, 0); st.rotation = 3; st.scale = 1.02
        let mirror = try #require(ImageFilter.stageFill(st, fill: .mirror))
        let blur = try #require(ImageFilter.stageFill(st, fill: .blur))
        try expectGPUMatches(32, 32, ramp, mirror)
        // Moved 4 px right, nothing is empty: the left edge shows the picture folded back over its edge.
        var shift = StageTransform.identity
        shift.position = Vec2(4, 0)
        let f = try #require(ImageFilter.stageFill(shift, fill: .mirror))
        let img = image(32, 8) { x, _ in (0, 0, UInt8(x * 8), 255) }
        let out = ref(f, img)
        #expect(out[2, 3].w == 1)
        for x in 0..<8 { #expect(out[x, 3].w == 1) }                  // alpha stays 1 along the fold line (no seam)
        #expect(abs(out[2, 3].x - img[1, 3].x) < 0.02)
        #expect(out[10, 3].x == img[6, 3].x)
        // Blur Edge: same interior as Mirror Edge, the filled band is opaque too.
        guard let sharp = try renderGPU(32, 32, ramp, mirror), let soft = try renderGPU(32, 32, ramp, blur) else { return }
        for y in 0..<32 { for x in 0..<32 {
            let a = sharp[y * 32 + x], b = soft[y * 32 + x]
            #expect(b.w > 0.99 || a.w < 0.99)
        } }
        #expect(abs(sharp[16 * 32 + 20].x - soft[16 * 32 + 20].x) < 0.02)    // inside the picture
        #expect(sharp[16 * 32 + 1] != soft[16 * 32 + 1])                     // in the band: blurred
    }

    @Test func horizontalFlipThroughTheClipModel() throws {
        var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(5, 1)), start: .zero)
        c.effects = [ClipEffect.make(kind: ClipEffect.horizontalFlipKind)!]
        guard let f = c.effects(at: Time(1, 1)).segments.first?.filter else { Issue.record("no flip"); return }
        let src: (Int, Int) -> Px = { x, _ in (0, 0, UInt8(x * 8), 255) }
        guard let got = try renderGPU(32, 32, src, f) else { return }
        for x in 0..<32 { #expect(abs(got[5 * 32 + x].x - linear(src(31 - x, 0)).x) < 0.005) }
    }
}

// MARK: Corner Warp

@Suite struct CornerWarpLookTests {
    private func pin(_ tl: Vec2 = .zero, _ tr: Vec2 = .zero, _ br: Vec2 = .zero, _ bl: Vec2 = .zero) -> ImageFilter {
        .cornerPin(topLeft: tl, topRight: tr, bottomRight: br, bottomLeft: bl)
    }

    @Test func cornersAtTheirPlaceKeepThePicture() {
        let img = image(32, 32, ramp)
        let out = ref(pin(), img)
        for (x, y) in [(0, 0), (31, 0), (5, 17), (16, 16), (31, 31)] { #expect(abs(out[x, y].x - img[x, y].x) < 1e-3, "\(x),\(y)") }
    }

    @Test func movingAllCornersInShrinksThePictureAroundTheCenter() {
        let img = image(32, 32) { x, _ in (0, 0, UInt8(x * 8), 255) }
        let out = ref(pin(Vec2(8, 8), Vec2(-8, 8), Vec2(-8, -8), Vec2(8, -8)), img)
        #expect(out[2, 2].w == 0 && out[16, 29].w == 0)                  // outside the new quadrilateral: transparent
        #expect(abs(out[16, 16].x - img[16, 16].x) < 0.02)               // center stays
        #expect(abs(out[12, 16].x - img[8, 16].x) < 0.03)                // half size: output 12 reads source 8
    }

    @Test func aCollapsedQuadrilateralIsEmpty() {
        let img = image(16, 16, ramp)
        let out = ref(pin(Vec2(16, 0), Vec2(0, 0), Vec2(-16, 0), Vec2(0, 0)), img)
        #expect(out.px.allSatisfy { $0.w == 0 })
    }

    @Test func gpuMatchesReference() throws {
        try expectGPUMatches(32, 32, ramp, pin(Vec2(4, 3), Vec2(-6, 2), Vec2(-2, -5), Vec2(5, -1)))
        try expectGPUMatches(32, 32, ramp, pin(Vec2(0, 0), Vec2(0, 6), Vec2(0, -6), Vec2(0, 0)))
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
        let fx = ClipEffects(segments: [EffectSegment(filter: pin(Vec2(80, 40), Vec2(-60, 20), Vec2(-30, -50), Vec2(40, -10))), EffectSegment()])
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
        print("corner warp 1080p p95 \(String(format: "%.2f", p95)) ms, median \(String(format: "%.2f", ms[ms.count / 2])) ms")
        #expect(p95 < 16, "p95 \(p95) ms")
    }
}
#endif
