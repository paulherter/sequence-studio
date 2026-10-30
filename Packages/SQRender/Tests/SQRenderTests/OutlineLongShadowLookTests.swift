#if canImport(Metal)
import CoreVideo
import Foundation
import Metal
import SQCore
import Testing
@testable import SQRender

// C5 look tests: Outline (jump-flood distance field on the alpha) and Long Shadow (doubling passes along the angle).

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

private func hint(_ w: Int, _ h: Int) -> VideoTrackInfo {
    VideoTrackInfo(width: w, height: h, codec: "hvc1", bitDepth: 8, chroma: "4:2:0",
                   nominalFrameDuration: Time(1, 25), isVariableFrameRate: false)
}

private func setup() -> (MTLDevice, MTLCommandQueue, Compositor)? {
    guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue(), let c = try? Compositor(device: d) else { return nil }
    return (d, q, c)
}

/// Renders a `w x h` layer filling the canvas with `filter` (nil = plain) and returns the canvas (linear premultiplied).
private func renderGPU(_ w: Int, _ h: Int, _ src: (Int, Int) -> Px, _ filter: ImageFilter?) throws -> [SIMD4<Float>]? {
    guard let (dev, q, comp) = setup() else { return nil }
    let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
    td.usage = [.renderTarget, .shaderRead]; td.storageMode = .shared
    let t = dev.makeTexture(descriptor: td)!
    let fx = filter.map { ClipEffects(segments: [EffectSegment(filter: $0), EffectSegment()]) } ?? .none
    let layer = RenderLayer(content: .frame(makeBGRA(w, h, src), colorHint: hint(w, h)), effects: fx)
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

/// An opaque dark-gray square x, y in 24..<40 on a transparent 64 x 64 picture (a cutout).
private let (W, H) = (64, 64)
private func square(_ x: Int, _ y: Int) -> Px { (24..<40).contains(x) && (24..<40).contains(y) ? (40, 40, 40, 255) : (0, 0, 0, 0) }
private let white = SIMD3<Double>(1, 1, 1)

/// Outline coverage along the middle row: the red channel of a white stroke over black (the square itself is dark).
private func row(_ px: [SIMD4<Float>], _ y: Int = 32) -> [Float] { (0..<W).map { px[y * W + $0].x } }

@Suite struct OutlineLookTests {
    /// The stroke reaches the requested width beyond the alpha edge, within half a pixel, for whole and fractional widths.
    @Test func outsideOutlineHasTheRequestedWidth() throws {
        for width in [1.0, 3.5, 6.0, 10.25] {
            guard let out = try renderGPU(W, H, square, .outline(width: width, color: white, softness: 0, position: .outside)) else { return }
            let r = row(out)
            let right = r[40...].reduce(0, +), left = r[..<24].reduce(0, +)
            #expect(abs(right - Float(width)) <= 0.5, "width \(width): right \(right)")
            #expect(abs(left - Float(width)) <= 0.5, "width \(width): left \(left)")
            // Vertically too, and the square itself is untouched.
            let col = (0..<H).map { out[$0 * W + 32].x }
            #expect(abs(col[40...].reduce(0, +) - Float(width)) <= 0.5)
            #expect(abs(out[32 * W + 32].x - r[30]) < 1e-6 && r[30] < 0.05)
        }
    }

    @Test func insideAndCentreSitWhereTheyShould() throws {
        guard let inside = try renderGPU(W, H, square, .outline(width: 4, color: white, softness: 0, position: .inside)),
              let centre = try renderGPU(W, H, square, .outline(width: 4, color: white, softness: 0, position: .centre)) else { return }
        let ri = row(inside), rc = row(centre)
        // Inside: 4 px inward from the edge (x 36..<40), nothing outside.
        #expect(abs(ri[24..<40].filter { $0 > 0.5 }.count - 8) <= 0)
        #expect(ri[40...].allSatisfy { $0 < 0.01 } && ri[30] < 0.05 && ri[37] > 0.95)
        // Center: 2 px each side of the edge.
        #expect(rc[38] > 0.95 && rc[39] > 0.95 && rc[40] > 0.95 && rc[41] > 0.95 && rc[42] < 0.05 && rc[36] < 0.05)
    }

    @Test func softnessRampsTheEdge() throws {
        guard let out = try renderGPU(W, H, square, .outline(width: 6, color: white, softness: 4, position: .outside)) else { return }
        let r = row(out)
        #expect(r[41] > 0.95)                                 // well inside the stroke
        #expect(r[46] > 0.2 && r[46] < 0.8)                   // on the soft edge (center at 6 px)
        #expect(r[50] < 0.01)
        #expect(abs(r[40...].reduce(0, +) - 6) <= 0.5)        // the ramp is centered on the width
    }

    @Test func zeroWidthIsThePlainPicture() throws {
        guard let plain = try renderGPU(W, H, square, nil),
              let out = try renderGPU(W, H, square, .outline(width: 0, color: white, softness: 0, position: .outside)) else { return }
        var worst: Float = 0
        for i in 0..<(W * H) { for c in 0..<4 { worst = max(worst, abs(plain[i][c] - out[i][c])) } }
        #expect(worst < 0.002, "worst \(worst)")
    }

    @Test func roundShapesGetAnEvenStroke() throws {
        // A disc of radius 12: the stroke's outer edge is a circle of radius 12 + 5 in every direction.
        let disc: (Int, Int) -> Px = { x, y in
            let dx = Double(x) + 0.5 - 32, dy = Double(y) + 0.5 - 32
            return dx * dx + dy * dy <= 144 ? (40, 40, 40, 255) : (0, 0, 0, 0)
        }
        guard let out = try renderGPU(W, H, disc, .outline(width: 5, color: white, softness: 0, position: .outside)) else { return }
        for (x, y) in [(32 + 15, 32), (32, 32 - 16), (32 + 11, 32 + 11), (32 - 11, 32 - 11)] {
            #expect(out[y * W + x].x > 0.85, "(\(x), \(y)) \(out[y * W + x].x)")   // the disc is a pixel staircase
        }
        for (x, y) in [(32 + 18, 32), (32, 32 - 19), (32 + 13, 32 + 13)] {
            #expect(out[y * W + x].x < 0.1, "(\(x), \(y)) \(out[y * W + x].x)")
        }
    }
}

@Suite struct LongShadowLookTests {
    @Test func shadowRunsAlongTheAngleForItsLength() throws {
        guard let out = try renderGPU(W, H, square, .longShadow(angle: 90, length: 20, color: white, fade: 0, opacity: 1)) else { return }
        let r = row(out)
        #expect(r[41] > 0.95 && r[58] > 0.95)                 // x 40..<60 shadowed
        #expect(r[61] < 0.05)                                 // ends after 20 px
        #expect(r[20] < 0.01)                                 // nothing on the lit side
        #expect(out[20 * W + 50].x < 0.01 && out[44 * W + 50].x < 0.01)   // only as tall as the square
        #expect(r[30] < 0.05)                                 // under the opaque square: the square
    }

    @Test func fadeLowersTheShadowLinearly() throws {
        guard let out = try renderGPU(W, H, square, .longShadow(angle: 90, length: 20, color: white, fade: 1, opacity: 1)) else { return }
        let r = row(out)
        // Pixel 50 is 10.5 px from the edge: 1 - 10.5 / 20.
        #expect(abs(r[50] - 0.475) < 0.06, "\(r[50])")
        #expect(r[41] > r[50] && r[50] > r[57])
    }

    @Test func stepsReachEveryPixelUpToTheLength() {
        #expect(OutlineFilters.shadowSteps(length: 20) == [1, 2, 4, 8, 5])
        #expect(OutlineFilters.shadowSteps(length: 15) == [1, 2, 4, 8])
        #expect(OutlineFilters.shadowSteps(length: 0.5) == [0.5])
        #expect(OutlineFilters.shadowSteps(length: 0).isEmpty)
        #expect(OutlineFilters.jumpSteps(reach: 14) == [8, 4, 2, 1, 1])
    }

    @Test func downwardShadowAndOpacity() throws {
        guard let out = try renderGPU(W, H, square, .longShadow(angle: 180, length: 10, color: white, fade: 0, opacity: 0.5)) else { return }
        #expect(abs(out[45 * W + 32].x - 0.5) < 0.02)         // below the square
        #expect(out[52 * W + 32].x < 0.02)
        #expect(out[32 * W + 45].x < 0.01)                    // not to the side
    }
}

/// A fully opaque 64 x 64 picture centered on a 128 x 128 canvas: the shadow leaves the picture, so it needs the margin.
private func renderOnCanvas(_ filter: ImageFilter) throws -> [SIMD4<Float>]? {
    guard let (dev, q, comp) = setup() else { return nil }
    let c = 128
    let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: c, height: c, mipmapped: false)
    td.usage = [.renderTarget, .shaderRead]; td.storageMode = .shared
    let t = dev.makeTexture(descriptor: td)!
    let fx = ClipEffects(segments: [EffectSegment(filter: filter), EffectSegment()])
    let layer = RenderLayer(content: .frame(makeBGRA(64, 64) { _, _ in (40, 40, 40, 255) }, colorHint: hint(64, 64)), effects: fx)
    let cb = q.makeCommandBuffer()!
    try comp.render([layer], format: SequenceFormat(width: c, height: c, frameDuration: Time(1, 25)), into: t, commandBuffer: cb)
    cb.commit(); cb.waitUntilCompleted()
    var half = [Float16](repeating: 0, count: c * c * 4)
    t.getBytes(&half, bytesPerRow: c * 8, from: MTLRegionMake2D(0, 0, c, c), mipmapLevel: 0)
    return (0..<(c * c)).map { (i: Int) -> SIMD4<Float> in SIMD4(Float(half[i * 4]), 0, 0, Float(half[i * 4 + 3])) }
}

/// Long Shadow pads the working canvas only along its direction, and never beyond a fixed pixel budget.
@Suite struct LongShadowMarginTests {
    @Test func sidewaysShadowLeavesThePictureForItsFullLength() throws {
        guard let out = try renderOnCanvas(.longShadow(angle: 90, length: 20, color: white, fade: 0, opacity: 1)) else { return }
        #expect(out[64 * 128 + 100].x > 0.95 && out[64 * 128 + 114].x > 0.95)   // picture ends at x 96
        #expect(out[64 * 128 + 118].x < 0.05)
    }

    @Test func diagonalShadowReachesTheCorner() throws {
        guard let out = try renderOnCanvas(.longShadow(angle: 135, length: 20, color: white, fade: 0, opacity: 1)) else { return }
        #expect(out[106 * 128 + 106].x > 0.95)                // 10 px right and down of the picture's corner (14 px along)
        #expect(out[20 * 128 + 64].x < 0.01)                  // nothing above the picture
    }

    @Test func planKeepsThePictureAndCutsOnlyTheMargin() {
        for angle in [90.0, 135, 180] {
            let f = ImageFilter.longShadow(angle: angle, length: 4_000, color: .zero, fade: 0, opacity: 1)
            let p = GaussianBlur.Plan(layerWidth: 3840, layerHeight: 2160, sigma: 0, extraMargin: f.axisMargin.x,
                                      extraMarginY: f.axisMargin.y, maxPixels: GaussianBlur.maxShapeCanvasPixels)
            #expect(p.factor == 1)                                  // the picture is never reduced
            #expect(p.textureWidth * p.textureHeight <= GaussianBlur.maxShapeCanvasPixels)
            #expect(p.textureWidth >= 3840 && p.textureHeight >= 2160)
        }
        // A 6K picture with the widest Outline keeps full size and its whole stroke margin.
        let o = ImageFilter.outline(width: 500, color: .zero, softness: 200, position: .outside)
        let p6 = GaussianBlur.Plan(layerWidth: 6144, layerHeight: 3456, sigma: 0, extraMargin: o.axisMargin.x,
                                   extraMarginY: o.axisMargin.y, maxPixels: GaussianBlur.maxShapeCanvasPixels)
        #expect(p6.factor == 1 && Double(p6.textureWidth) >= 6144 + 2 * o.axisMargin.x)
        // A sideways shadow adds no rows; a common one keeps full size.
        let side = ImageFilter.longShadow(angle: 90, length: 200, color: .zero, fade: 0, opacity: 1)
        let p = GaussianBlur.Plan(layerWidth: 3840, layerHeight: 2160, sigma: 0, extraMargin: side.axisMargin.x,
                                  extraMarginY: side.axisMargin.y, maxPixels: GaussianBlur.maxShapeCanvasPixels)
        #expect(p.factor == 1 && p.textureHeight == 2176)
        #expect(Compositor.pixelBudget(EffectSegment(filter: side)) == GaussianBlur.maxShapeCanvasPixels)
        #expect(Compositor.pixelBudget(EffectSegment(filter: .glow(threshold: 0.5, sigma: 2, intensity: 1, color: nil))) == .max)
    }

    /// The shadow's own plane is held to `maxShapePassPixels`; a small canvas keeps it at full size.
    @Test func shadowPlaneHoldsItsBudget() {
        #expect(OutlineFilters.shadowPlaneSize(width: 1920, height: 1080) == (1920, 1080))
        let big = OutlineFilters.shadowPlaneSize(width: 9536, height: 7872)
        #expect(big.0 * big.1 <= GaussianBlur.maxShapePassPixels && big.0 > 4000)
    }
}

/// Export and full-quality playback never reduce the clip's own picture for Outline or Long Shadow: a 6K picture with a
/// one-pixel checker renders the same as without the effect (the stroke and shadow fall outside the frame).
@Suite struct ShapePassKeepsThePictureTests {
    private func render6K(_ filter: ImageFilter?) throws -> [Float16]? {
        guard let (dev, q, comp) = setup() else { return nil }
        let (w, h) = (6144, 3456)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]; td.storageMode = .shared
        let t = dev.makeTexture(descriptor: td)!
        let fx = filter.map { ClipEffects(segments: [EffectSegment(filter: $0), EffectSegment()]) } ?? .none
        let src = makeBGRA(w, h) { x, y in (x + y) % 2 == 0 ? (30, 60, 200, 255) : (220, 180, 20, 255) }
        let layer = RenderLayer(content: .frame(src, colorHint: hint(w, h)), effects: fx)
        let cb = q.makeCommandBuffer()!
        try comp.render([layer], format: SequenceFormat(width: w, height: h, frameDuration: Time(1, 25)), into: t, commandBuffer: cb)
        cb.commit(); cb.waitUntilCompleted()
        #expect(cb.error == nil)
        var half = [Float16](repeating: 0, count: w * h * 4)
        t.getBytes(&half, bytesPerRow: w * 8, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        return half
    }

    @Test func sixKOutlineAndLongShadowKeepEveryPixel() throws {
        guard let plain = try render6K(nil) else { return }
        for f in [ImageFilter.outline(width: 40, color: white, softness: 2, position: .outside),
                  .longShadow(angle: 135, length: 3000, color: white, fade: 0, opacity: 1)] {
            guard let out = try render6K(f) else { return }
            var worst: Float = 0
            for i in stride(from: 0, to: plain.count, by: 1) { worst = max(worst, abs(Float(out[i]) - Float(plain[i]))) }
            #expect(worst <= 0.002, "\(f): max difference \(worst)")
        }
    }
}

/// A layer shown at 40 %: the half-size path draws the same stroke and shadow (widths in clip px) as full size.
@Suite struct OutlineReducedSizeTests {
    @Test(arguments: [0, 1])
    func halfWorkingSizeKeepsTheLook(kind: Int) throws {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return }
        let w = 400, h = 400
        let pb = makeBGRA(w, h) { x, y in (150..<250).contains(x) && (150..<250).contains(y) ? (40, 40, 40, 255) : (0, 0, 0, 0) }
        let f: ImageFilter = kind == 0 ? .outline(width: 30, color: white, softness: 0, position: .outside)
                                       : .longShadow(angle: 90, length: 100, color: white, fade: 0.5, opacity: 1)
        let fx = ClipEffects(segments: [EffectSegment(filter: f), EffectSegment()])
        let fmt = SequenceFormat(width: 200, height: 200, frameDuration: Time(1, 25))
        let layer = RenderLayer(content: .frame(pb, colorHint: hint(w, h)), transform: ClipTransform(scale: Vec2(0.4, 0.4)), effects: fx)
        func render(limit: Bool) throws -> [Float16] {
            let comp = try Compositor(device: dev)
            comp.limitsColorWork = limit
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 200, height: 200, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
            let target = dev.makeTexture(descriptor: d)!
            let cb = q.makeCommandBuffer()!
            try comp.render([layer], format: fmt, into: target, commandBuffer: cb)
            cb.commit(); cb.waitUntilCompleted()
            #expect(cb.error == nil)
            var px = [Float16](repeating: 0, count: 200 * 200 * 4)
            target.getBytes(&px, bytesPerRow: 200 * 8, from: MTLRegionMake2D(0, 0, 200, 200), mipmapLevel: 0)
            return px
        }
        let full = try render(limit: false), half = try render(limit: true)
        // Coverage of the middle row right of the square (x >= 120 canvas px): same stroke / shadow length within 1 px.
        func reach(_ px: [Float16]) -> Float { (120..<200).reduce(0) { $0 + Float(px[(100 * 200 + $1) * 4]) } }
        #expect(full != half, "the half-size path ran")
        #expect(abs(reach(full) - reach(half)) < 1, "full \(reach(full)) half \(reach(half))")
        #expect(reach(full) > (kind == 0 ? 11 : 15))
    }
}

// MARK: Cost

@Suite struct OutlineLongShadowCostTests {
    /// GPU ms per 1080p and 4K frame (an opaque frame with a transparent hole, so every pass has edges) for Outline and Long
    /// Shadow at typical and large settings. NSLog, stdout and $TMPDIR/sqoutlinecost.txt.
    @Test func measureCost() throws {
        guard let (dev, q, comp) = setup() else { return }
        var lines: [String] = []
        for (w, h, name) in [(1920, 1080, "1080p"), (3840, 2160, "4K")] {
            let pb = makeBGRA(w, h) { x, y in
                let dx = x - w / 2, dy = y - h / 2
                return dx * dx + dy * dy < (h / 3) * (h / 3) ? (90, 140, 200, 255) : (0, 0, 0, 0)
            }
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
            td.usage = [.renderTarget, .shaderRead]; td.storageMode = .private
            let t = dev.makeTexture(descriptor: td)!
            func gpuMs(_ f: ImageFilter?) throws -> Double {
                let fx = f.map { ClipEffects(segments: [EffectSegment(filter: $0), EffectSegment()]) } ?? .none
                let layer = RenderLayer(content: .frame(pb, colorHint: hint(w, h)), effects: fx)
                var times: [Double] = []
                for i in 0..<12 {
                    let cb = q.makeCommandBuffer()!
                    try comp.render([layer], format: SequenceFormat(width: w, height: h, frameDuration: Time(1, 25)), into: t, commandBuffer: cb)
                    cb.commit(); cb.waitUntilCompleted()
                    if i >= 2 { times.append((cb.gpuEndTime - cb.gpuStartTime) * 1000) }
                }
                return times.sorted()[times.count / 2]
            }
            lines.append("\(name) plain \(String(format: "%.2f", try gpuMs(nil))) ms")
            let cases: [(String, ImageFilter)] = [
                ("outline 12 px outside", .outline(width: 12, color: white, softness: 0, position: .outside)),
                ("outline 40 px soft 10", .outline(width: 40, color: white, softness: 10, position: .outside)),
                ("outline 12 px inside", .outline(width: 12, color: white, softness: 0, position: .inside)),
                ("long shadow 200 px", .longShadow(angle: 135, length: 200, color: .zero, fade: 0.5, opacity: 0.8)),
                ("long shadow 1000 px", .longShadow(angle: 135, length: 1000, color: .zero, fade: 0.5, opacity: 0.8)),
            ]
            for (n, f) in cases { lines.append("\(name) \(n) \(String(format: "%.2f", try gpuMs(f))) ms") }
        }
        let text = lines.joined(separator: "\n")
        NSLog("SQOUTLINECOST %@", text)
        print("SQOUTLINECOST\n\(text)")
        try? (text + "\n").write(toFile: NSTemporaryDirectory() + "sqoutlinecost.txt", atomically: true, encoding: .utf8)
    }
}
#endif
