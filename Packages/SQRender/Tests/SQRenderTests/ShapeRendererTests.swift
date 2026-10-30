#if canImport(Metal)
import CoreVideo
import Foundation
import Metal
import SQCore
import Testing
@testable import SQRender

/// Linear premultiplied RGBA of one pixel of a `64RGBAHalf` buffer (y down, row 0 = top).
private func pixel(_ b: CVPixelBuffer, _ x: Int, _ y: Int) -> SIMD4<Float> {
    CVPixelBufferLockBaseAddress(b, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
    let row = CVPixelBufferGetBaseAddress(b)! + y * CVPixelBufferGetBytesPerRow(b)
    let p = row.assumingMemoryBound(to: Float16.self) + x * 4
    return SIMD4(Float(p[0]), Float(p[1]), Float(p[2]), Float(p[3]))
}

private func near(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ tol: Float = 0.01) -> Bool {
    let d = a - b
    return Swift.abs(d.x) < tol && Swift.abs(d.y) < tol && Swift.abs(d.z) < tol && Swift.abs(d.w) < tol
}

private let red = EffectColor(red: 1, green: 0, blue: 0)
private let blue = EffectColor(red: 0, green: 0, blue: 1)
private let white = EffectColor.white

@Suite struct ShapeRendererTests {
    @Test func rectangleFillAndStroke() throws {
        // 40 x 20 outline, 4 px stroke centered on it: 44 x 24 picture, 2 px of stroke outside, 2 px inside.
        let st = ShapeStyle(kind: .rectangle, width: 40, height: 20, fill: red, stroke: white, strokeWidth: 4)
        let b = try #require(ShapeRenderer.raster(st))
        #expect(CVPixelBufferGetPixelFormatType(b) == kCVPixelFormatType_64RGBAHalf)
        #expect(CVPixelBufferGetWidth(b) == 44 && CVPixelBufferGetHeight(b) == 24)
        #expect(near(pixel(b, 22, 12), SIMD4(1, 0, 0, 1)))       // center: fill
        #expect(near(pixel(b, 1, 12), SIMD4(1, 1, 1, 1)))        // left edge: stroke
        #expect(near(pixel(b, 22, 2), SIMD4(1, 1, 1, 1)))        // top edge, inner half of the stroke
        #expect(near(pixel(b, 6, 12), SIMD4(1, 0, 0, 1)))        // just inside the stroke: fill again
    }

    @Test func fillColourIsLinearisedLikeTheCompositorSolid() throws {
        // Display 0.5 gray -> BT.709 inverse OETF.
        let st = ShapeStyle(kind: .rectangle, width: 8, height: 8, fill: EffectColor(red: 0.5, green: 0.5, blue: 0.5))
        let b = try #require(ShapeRenderer.raster(st))
        let lin = Float(pow((0.5 + 0.09929682680944) / 1.09929682680944, 1 / 0.45))
        #expect(near(pixel(b, 4, 4), SIMD4(lin, lin, lin, 1), 0.003))
    }

    @Test func gradientFillRunsFromStartToEndColor() throws {
        let st = ShapeStyle(kind: .rectangle, width: 40, height: 20, fill: red, gradientEnd: blue, gradientAngle: 0)
        let b = try #require(ShapeRenderer.raster(st))
        #expect(pixel(b, 1, 10).x > 0.9 && pixel(b, 1, 10).z < 0.1)
        #expect(pixel(b, 38, 10).z > 0.9 && pixel(b, 38, 10).x < 0.1)
        // No end color: the solid path is untouched.
        let solid = try #require(ShapeRenderer.raster(ShapeStyle(kind: .rectangle, width: 40, height: 20, fill: red)))
        #expect(near(pixel(solid, 38, 10), SIMD4(1, 0, 0, 1)))
    }

    @Test func translucentFillIsPremultiplied() throws {
        let st = ShapeStyle(kind: .rectangle, width: 8, height: 8, fill: EffectColor(red: 1, green: 0, blue: 0, alpha: 0.5))
        let b = try #require(ShapeRenderer.raster(st))
        #expect(near(pixel(b, 4, 4), SIMD4(0.5, 0, 0, 0.5)))
    }

    @Test func cornerRadiusClearsTheCorners() throws {
        let st = ShapeStyle(kind: .rectangle, width: 40, height: 40, cornerRadius: 15, fill: red)
        let b = try #require(ShapeRenderer.raster(st))
        #expect(pixel(b, 1, 1).w < 0.01)                         // outside the rounded corner
        #expect(near(pixel(b, 20, 1), SIMD4(1, 0, 0, 1)))        // straight top edge
        #expect(near(pixel(b, 20, 20), SIMD4(1, 0, 0, 1)))
    }

    @Test func ellipseIsRound() throws {
        let st = ShapeStyle(kind: .ellipse, width: 40, height: 40, fill: blue)
        let b = try #require(ShapeRenderer.raster(st))
        #expect(CVPixelBufferGetWidth(b) == 40)
        #expect(pixel(b, 3, 3).w < 0.01)                         // corner of the box: outside the circle
        #expect(near(pixel(b, 20, 20), SIMD4(0, 0, 1, 1)))
        #expect(near(pixel(b, 1, 20), SIMD4(0, 0, 1, 1), 0.2))   // left extreme of the circle (antialiased edge)
        #expect(pixel(b, 6, 6).w > 0.9)                          // inside: 14 px from the center diagonal < 20
    }

    @Test func lineIsALengthByStrokeWidthBar() throws {
        let st = ShapeStyle(kind: .line, width: 30, height: 0, stroke: white, strokeWidth: 6)
        let b = try #require(ShapeRenderer.raster(st))
        #expect(CVPixelBufferGetWidth(b) == 30 && CVPixelBufferGetHeight(b) == 6)
        #expect(near(pixel(b, 0, 0), SIMD4(1, 1, 1, 1)))
        #expect(near(pixel(b, 29, 5), SIMD4(1, 1, 1, 1)))
    }

    @Test func emptyShapeHasNoRaster() {
        #expect(ShapeRenderer.raster(ShapeStyle(kind: .rectangle, width: 40, height: 40)) == nil)      // no fill, no stroke
        #expect(ShapeRenderer.raster(ShapeStyle(kind: .line, width: 30, height: 0)) == nil)            // a line needs a stroke
        #expect(ShapeRenderer.raster(ShapeStyle(kind: .ellipse, width: 0, height: 40, fill: red)) == nil)
    }

    @Test func sameStyleReusesTheRaster() throws {
        let st = ShapeStyle(kind: .ellipse, width: 33, height: 17, fill: red)
        let a = try #require(ShapeRenderer.raster(st)), b = try #require(ShapeRenderer.raster(st))
        #expect(a === b)
    }

    @Test func hugeShapeIsDrawnScaledDownKeepingItsAspect() throws {
        let st = ShapeStyle(kind: .rectangle, width: 10_000, height: 2_000, fill: red)
        let p = try #require(ShapeRenderer.picture(st))
        let bw = CVPixelBufferGetWidth(p.buffer), bh = CVPixelBufferGetHeight(p.buffer)
        #expect(bw == ShapeRenderer.maxSide && bh == 820)
        // The layer covers the shape at its real size, with the buffer's own aspect (no squash).
        #expect(abs(p.width - 10_000) < 0.01)
        #expect(abs(p.width / p.height - Double(bw) / Double(bh)) < 1e-9)
        #expect(near(pixel(p.buffer, bw / 2, bh / 2), SIMD4(1, 0, 0, 1)))
    }

    @Test func layerSizeIsTheBufferSizeNotTheFractionalShape() throws {
        let st = ShapeStyle(kind: .rectangle, width: 40.5, height: 20.25, fill: red)
        var r = LayerRequest(clip: UUID(), media: UUID(), track: UUID(), sourceTime: .zero, generator: .shape(.rectangle))
        r.shape = st
        guard case .linearPremultiplied(let b, let w, let h) = ShapeRenderer.layer(for: r).content else {
            Issue.record("not a raster"); return
        }
        #expect(b.width == 41 && b.height == 21)
        #expect(w == 41 && h == 21)
    }

    @Test func cacheEvictsByBytesLeastRecentlyUsedFirst() {
        func st(_ w: Double) -> ShapeStyle { ShapeStyle(kind: .rectangle, width: w, height: 10, fill: red) }
        var c = ShapeRasterCache<Int>(budget: 100)
        c.store(st(1), clip: nil, 1, bytes: 40)
        c.store(st(2), clip: nil, 2, bytes: 40)
        #expect(c.lookup(st(1), clip: nil) == 1)                 // touch 1: 2 is now the oldest
        c.store(st(3), clip: nil, 3, bytes: 40)
        #expect(c.bytes <= 100)
        #expect(c.lookup(st(2), clip: nil) == nil)
        #expect(c.lookup(st(1), clip: nil) == 1 && c.lookup(st(3), clip: nil) == 3)
        c.store(st(4), clip: nil, 4, bytes: 500)                 // larger than the budget: never kept
        #expect(c.lookup(st(4), clip: nil) == nil && c.bytes <= 100)
    }

    @Test func animatedShapeKeepsOneSlotPerClipInsteadOfFillingTheCache() {
        func st(_ w: Double) -> ShapeStyle { ShapeStyle(kind: .rectangle, width: w, height: 10, fill: red) }
        let clip = UUID()
        var c = ShapeRasterCache<Int>(budget: 1_000)
        c.store(st(1), clip: clip, 1, bytes: 10)                 // first frame: cached like a still shape
        for w in 2...50 { c.store(st(Double(w)), clip: clip, w, bytes: 10) }   // keyed: one slot, replaced every frame
        #expect(c.count == 1 && c.bytes == 10 + 10)
        #expect(c.lookup(st(50), clip: clip) == 50)              // playback stops here: promoted into the cache
        #expect(c.count == 2)
        #expect(c.lookup(st(49), clip: clip) == nil)
    }

    @Test func layerForAShapeRequest() throws {
        let st = ShapeStyle(kind: .rectangle, width: 40, height: 20, fill: red)
        var r = LayerRequest(clip: UUID(), media: UUID(), track: UUID(), sourceTime: .zero, generator: .shape(.rectangle))
        r.shape = st
        let l = ShapeRenderer.layer(for: r)
        guard case .linearPremultiplied(_, let w, let h) = l.content else { Issue.record("not a raster"); return }
        #expect(w == 40 && h == 20)
        r.shape = nil                                            // Shape effect switched off: invisible
        #expect(ShapeRenderer.layer(for: r).transform.opacity == 0)
    }

    /// Look test: a 20 x 10 red rectangle with a 2 px white stroke, 10 px right of center, on a 64 x 32 black canvas.
    @Test func compositesAtTheClipPosition() throws {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue(), let comp = try? Compositor(device: d) else { return }
        let st = ShapeStyle(kind: .rectangle, width: 20, height: 10, fill: red, stroke: white, strokeWidth: 2)
        var r = LayerRequest(clip: UUID(), media: UUID(), track: UUID(), sourceTime: .zero, generator: .shape(.rectangle))
        r.shape = st
        r.transform.position = Vec2(10, 0)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 64, height: 32, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]; desc.storageMode = .shared
        let t = d.makeTexture(descriptor: desc)!
        let cb = q.makeCommandBuffer()!
        try comp.render([ShapeRenderer.layer(for: r)], format: SequenceFormat(width: 64, height: 32, frameDuration: Time(1, 25)),
                        into: t, commandBuffer: cb)
        cb.commit(); cb.waitUntilCompleted()
        var px = [Float16](repeating: 0, count: 64 * 32 * 4)
        t.getBytes(&px, bytesPerRow: 64 * 8, from: MTLRegionMake2D(0, 0, 64, 32), mipmapLevel: 0)
        func at(_ x: Int, _ y: Int) -> SIMD4<Float> {
            let i = (y * 64 + x) * 4
            return SIMD4(Float(px[i]), Float(px[i + 1]), Float(px[i + 2]), Float(px[i + 3]))
        }
        // Picture 22 x 12 centered on (42, 16): x 31..52, y 10..21.
        #expect(near(at(42, 16), SIMD4(1, 0, 0, 1), 0.02))       // fill
        #expect(near(at(31, 16), SIMD4(1, 1, 1, 1), 0.02))       // left stroke
        #expect(near(at(42, 10), SIMD4(1, 1, 1, 1), 0.02))       // top stroke
        #expect(at(29, 16).x < 0.02 && at(32, 16).y > 0.9)       // nothing left of the stroke
        #expect(at(20, 16).x < 0.02)                             // canvas center: background
    }
}

@Suite struct ArrowRendererTests {
    @Test func arrowDrawsShaftAndHeadNotTheCorners() throws {
        // 100 x 50: shaft rows 15...35, head 45 px long (neck at x = 55).
        let st = ShapeStyle(kind: .arrow, width: 100, height: 50, fill: red)
        let b = try #require(ShapeRenderer.raster(st))
        #expect(CVPixelBufferGetWidth(b) == 100 && CVPixelBufferGetHeight(b) == 50)
        #expect(near(pixel(b, 20, 25), SIMD4(1, 0, 0, 1)))
        #expect(pixel(b, 20, 5).w < 0.01)
        #expect(near(pixel(b, 75, 25), SIMD4(1, 0, 0, 1)))
        #expect(near(pixel(b, 58, 3), SIMD4(1, 0, 0, 1)))
        #expect(pixel(b, 98, 2).w < 0.01 && pixel(b, 98, 47).w < 0.01)
    }
}
#endif
