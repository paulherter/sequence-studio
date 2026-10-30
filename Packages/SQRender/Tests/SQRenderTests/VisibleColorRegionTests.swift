#if canImport(Metal)
import CoreVideo
import Foundation
import Metal
import SQCore
import Testing
@testable import SQRender

// Playback perf: the color stage of a frame layer runs only over the part of the source the canvas shows.

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

private func hint(_ w: Int, _ h: Int, rotation: Int = 0) -> VideoTrackInfo {
    VideoTrackInfo(width: w, height: h, codec: "hvc1", bitDepth: 8, chroma: "4:2:0",
                   nominalFrameDuration: Time(1, 25), isVariableFrameRate: false, rotation: rotation)
}

private func readAll(_ t: MTLTexture) -> [Float16] {
    var px = [Float16](repeating: 0, count: t.width * t.height * 4)
    t.getBytes(&px, bytesPerRow: t.width * 8, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
    return px
}

@Suite struct VisibleColorRegionTests {
    typealias R = Compositor.SourceRegion

    func region(canvas: (Int, Int), position: Vec2 = Vec2(0, 0), anchor: Vec2 = Vec2(0, 0), scale: Double = 1,
                rotation: Double = 0, size: (Int, Int), texture: (Int, Int), quarter: UInt32 = 0, pad: Int = 0) -> R? {
        var t = ClipTransform.identity
        t.position = position; t.anchor = anchor; t.scale = Vec2(scale, scale); t.rotation = rotation
        return Compositor.visibleSourceRegion(canvas: SIMD2(Float(canvas.0), Float(canvas.1)), transform: t,
                                              size: SIMD2(Float(size.0), Float(size.1)),
                                              texture: (texture.0, texture.1), quarter: quarter, pad: pad)
    }

    @Test func wideSourceInTallCanvasKeepsOnlyTheMiddle() {
        // 3840x2160 at 100 % in a 1080x1920 canvas: the middle 1080 columns, all rows that fit (1920 of 2160).
        let r = region(canvas: (1080, 1920), size: (3840, 2160), texture: (3840, 2160))
        #expect(r == R(x: 1380, y: 120, width: 1080, height: 1920))
    }

    @Test func padIsClampedToTheTexture() {
        let r = region(canvas: (1080, 1920), size: (3840, 2160), texture: (3840, 2160), pad: 4)
        #expect(r == R(x: 1376, y: 116, width: 1088, height: 1928))
        let all = region(canvas: (1920, 1080), size: (1920, 1080), texture: (1920, 1080), pad: 4)
        #expect(all == R(x: 0, y: 0, width: 1920, height: 1080))
    }

    @Test func positionScaleAndRotationMoveTheRegion() {
        // Shifted right by 100 canvas px at 200 %: the canvas shows source columns 1920 - 270 - 50 ...
        let r = region(canvas: (1080, 1920), position: Vec2(100, 0), scale: 2, size: (3840, 2160), texture: (3840, 2160))
        #expect(r == R(x: 1920 - 270 - 50, y: 1080 - 480, width: 540, height: 960))
        // A 90 degree turn swaps what is visible: the canvas' 1920 rows now cover source columns.
        let turned = region(canvas: (1080, 1920), rotation: 90, size: (3840, 2160), texture: (3840, 2160))
        #expect(turned == R(x: 960, y: 540, width: 1920, height: 1080))
    }

    @Test func offCanvasLayerHasNoRegion() {
        #expect(region(canvas: (100, 100), position: Vec2(5000, 0), size: (200, 200), texture: (200, 200)) == nil)
        #expect(region(canvas: (100, 100), scale: 0, size: (200, 200), texture: (200, 200)) == nil)
    }

    @Test func quarterTurnedSourceMapsBackToTheStoredTexture() {
        // Stored 2160x3840 portrait texture shown upright as 3840x2160 (quarter 1): upright uv (u, v) reads texture (v, 1 - u).
        let r = region(canvas: (1080, 1920), size: (3840, 2160), texture: (2160, 3840), quarter: 1)
        // Upright visible: x 1380..2460 of 3840, y 120..2040 of 2160 -> texture x = y range, texture y = 3840 - x range.
        #expect(r == R(x: 120, y: 3840 - 2460, width: 1920, height: 1080))
    }

    /// GPU: the restricted color pass gives the very same picture as running it over the whole source, also with a
    /// vignette (its geometry is the whole picture, not the visible part) and a quarter turn.
    @Test(arguments: [0, 90])
    func restrictedColourMatchesFullColour(rotation: Int) throws {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return }
        let sw = 320, sh = 180
        let (tw, th) = rotation == 90 ? (sh, sw) : (sw, sh)
        let pb = bgra(tw, th) { x, y in (UInt8((x * 7) & 255), UInt8((y * 5) & 255), UInt8((x + y) & 255), 255) }
        var v = Vignette(); v.amount = -3; v.midpoint = 30; v.feather = 40
        var basic = BasicCorrection(); basic.exposure = 0.4; basic.saturation = 140
        let pipe = ColorPipeline(source: .rec709, ops: [.conversion(nil), .basic(basic), .vignette(v)])
        let f = SequenceFormat(width: 90, height: 160, frameDuration: Time(1, 25))
        var t = ClipTransform.identity
        t.position = Vec2(23, -11); t.scale = Vec2(1.3, 1.3); t.rotation = 7
        let layer = RenderLayer(content: .frame(pb, colorHint: hint(tw, th, rotation: rotation)), transform: t, colorPipeline: pipe)
        func render(restrict: Bool) throws -> [Float16] {
            let comp = try Compositor(device: dev)
            comp.limitsColorWork = restrict
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: f.width, height: f.height, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
            let target = dev.makeTexture(descriptor: d)!
            let cb = q.makeCommandBuffer()!
            try comp.render([layer], format: f, into: target, commandBuffer: cb)
            cb.commit(); cb.waitUntilCompleted()
            #expect(cb.error == nil)
            return readAll(target)
        }
        let full = try render(restrict: false), part = try render(restrict: true)
        #expect(full == part)
        #expect(full.contains { $0 > 0.01 }, "something was drawn")
    }

    /// Perf (printed): a 4K layer at 50 % in a vertical canvas; the restricted color stage must cost clearly less.
    @Test func restrictedColourIsCheaperFor4KInVerticalCanvas() throws {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return }
        let pb = bgra(3840, 2160) { x, y in (UInt8(x & 255), UInt8(y & 255), 128, 255) }
        var basic = BasicCorrection(); basic.exposure = 0.3
        let pipe = ColorPipeline(source: .rec709, ops: [.conversion(nil), .basic(basic)])
        let f = SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 30))
        let layer = RenderLayer(content: .frame(pb, colorHint: hint(3840, 2160)),
                                transform: ClipTransform(scale: Vec2(0.5, 0.5)), colorPipeline: pipe)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: f.width, height: f.height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
        let target = dev.makeTexture(descriptor: d)!
        func gpu(restrict: Bool) throws -> Double {
            let comp = try Compositor(device: dev)
            comp.limitsColorWork = restrict
            var best = Double.infinity
            for _ in 0..<6 {
                let cb = q.makeCommandBuffer()!
                try comp.render([layer], format: f, into: target, commandBuffer: cb)
                cb.commit(); cb.waitUntilCompleted()
                best = min(best, (cb.gpuEndTime - cb.gpuStartTime) * 1000)
            }
            return best
        }
        let full = try gpu(restrict: false), part = try gpu(restrict: true)
        print("PERF visible color region 4K@50% in 1080x1920: whole \(full) ms, visible \(part) ms")
        #expect(part < full * 0.8)
    }

    func work(scale: Double, texture: (Int, Int), texelsPerNative: Float = 1, quarter: UInt32 = 0, onePass: Bool = true,
              canvas: (Int, Int) = (1080, 1920), size: (Int, Int) = (3840, 2160)) -> Compositor.ColorWork {
        Compositor.colorWork(canvas: SIMD2(Float(canvas.0), Float(canvas.1)), transform: ClipTransform(scale: Vec2(scale, scale)),
                             size: SIMD2(Float(size.0), Float(size.1)), texture: texture, texelsPerNativePixel: texelsPerNative,
                             quarter: quarter, onePass: onePass)
    }

    @Test func halfResolutionOnlyWhenShownAtHalfSizeOrLess() {
        // 4K at 50 % in a vertical canvas: half-size intermediate, visible middle of it (2 canvas px + 2 texels of pad).
        let a = work(scale: 0.5, texture: (3840, 2160))
        #expect(a.width == 1920 && a.height == 1080)
        #expect(a.region == Compositor.SourceRegion(x: 960 - 540 - 4, y: 0, width: 1080 + 8, height: 1080))
        // 60 %: full resolution.
        let b = work(scale: 0.6, texture: (3840, 2160))
        #expect(b.width == 3840 && b.height == 2160)
        // A half-size proxy of a 4K clip at 50 %: one texel per canvas pixel already, no further halving.
        let c = work(scale: 0.5, texture: (1920, 1080), texelsPerNative: 0.5)
        #expect(c.width == 1920 && c.height == 1080)
        // A blur pass reads the whole picture: full region, still half resolution.
        let d = work(scale: 0.25, texture: (3840, 2160), onePass: false)
        #expect(d == Compositor.ColorWork(width: 1920, height: 1080, region: Compositor.SourceRegion(x: 0, y: 0, width: 1920, height: 1080)))
        // Vertical phone clip (stored 3840x2160, turned) at 50 %: the whole picture shows, at half resolution.
        let e = work(scale: 0.5, texture: (3840, 2160), quarter: 1, size: (2160, 3840))
        #expect(e == Compositor.ColorWork(width: 1920, height: 1080, region: Compositor.SourceRegion(x: 0, y: 0, width: 1920, height: 1080)))
    }

    /// GPU: half-resolution grading of a turned clip shown at 50 % is visually the same as grading every source texel.
    @Test func halfResolutionColourStaysClose() throws {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return }
        let pb = bgra(400, 224) { x, y in (UInt8(x * 255 / 399), UInt8(y * 255 / 223), UInt8(128 + (x - y) / 8), 255) }
        var v = Vignette(); v.amount = -2
        var basic = BasicCorrection(); basic.exposure = 0.5; basic.contrast = 40
        let pipe = ColorPipeline(source: .rec709, ops: [.conversion(nil), .basic(basic), .vignette(v)])
        let f = SequenceFormat(width: 112, height: 200, frameDuration: Time(1, 25))
        let layer = RenderLayer(content: .frame(pb, colorHint: hint(400, 224, rotation: 90)),
                                transform: ClipTransform(scale: Vec2(0.5, 0.5)), colorPipeline: pipe)
        func render(limit: Bool) throws -> [Float16] {
            let comp = try Compositor(device: dev)
            comp.limitsColorWork = limit
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: f.width, height: f.height, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
            let target = dev.makeTexture(descriptor: d)!
            let cb = q.makeCommandBuffer()!
            try comp.render([layer], format: f, into: target, commandBuffer: cb)
            cb.commit(); cb.waitUntilCompleted()
            return readAll(target)
        }
        let full = try render(limit: false), half = try render(limit: true)
        let worst = zip(full, half).map { Swift.abs(Float($0) - Float($1)) }.max() ?? 0
        #expect(worst < 0.01, "worst channel difference \(worst)")
        #expect(full != half, "the half-resolution path ran")
    }
}
#endif
