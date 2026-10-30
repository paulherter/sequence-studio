#if canImport(Metal)
import CoreVideo
import Foundation
import Metal
import SQCore
import Testing
@testable import SQRender

// v87 Color range masks in the compositor: the mask reads the picture's own pixel (display-encoded), so no matte layer and
// no extra pass. Pixels against the CPU reference `MaskCoverage` (color closure), within two 8-bit steps.

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

private func lin709(_ e: Float) -> Float {
    e < 0.081242858 ? e / 4.5 : powf((e + 0.09929682680944) / 1.09929682680944, 1 / 0.45)
}

private func render(_ nodes: [RenderNode], _ w: Int, _ h: Int) throws -> [SIMD4<Float>]? {
    guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue(), let comp = try? Compositor(device: dev)
    else { return nil }
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
    d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
    let t = dev.makeTexture(descriptor: d)!
    let cb = q.makeCommandBuffer()!
    let f = SequenceFormat(width: w, height: h, frameDuration: Time(1, 25))
    try comp.render(nodes: nodes, format: f, into: t, commandBuffer: cb)
    cb.commit(); cb.waitUntilCompleted()
    #expect(cb.error == nil)
    var px = [Float16](repeating: 0, count: w * h * 4)
    t.getBytes(&px, bytesPerRow: w * 8, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    return (0..<(w * h)).map { i in
        SIMD4<Float>(Float(px[i * 4]), Float(px[i * 4 + 1]), Float(px[i * 4 + 2]), Float(px[i * 4 + 3]))
    }
}

private func info(_ w: Int, _ h: Int) -> VideoTrackInfo {
    VideoTrackInfo(width: w, height: h, codec: "hvc1", bitDepth: 8, chroma: "4:2:0",
                   nominalFrameDuration: Time(1, 25), isVariableFrameRate: false)
}

private func shape(_ key: ColorRangeKey, opacity: Double = 1, inverted: Bool = false) -> MaskShape {
    var m = MaskShape(polygon: [], opacity: opacity, inverted: inverted, source: .colorRange)
    m.colorRange = key
    return m
}

@Suite struct ColorRangeMaskRenderTests {
    let w = 64, h = 36
    let tol: Float = 2.0 / 255 + 0.002

    private func tree(_ layer: RenderLayer, masks: [MaskShape], segments: [EffectSegment] = []) -> [RenderNode] {
        let fx = ClipEffects(segments: segments, masks: masks)
        let r = LayerRequest(clip: UUID(), media: UUID(), track: UUID(), sourceTime: .zero, effects: fx)
        var l = layer
        l.effects = fx
        return RenderNode.tree(requests: [r], layers: [l])
    }

    private func worst(_ got: [SIMD4<Float>], _ px: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8), _ masks: [MaskShape]) -> Float {
        var e: Float = 0
        for y in 0..<h {
            for x in 0..<w {
                let c = px(x, y)
                let enc = (r: Double(c.2) / 255, g: Double(c.1) / 255, b: Double(c.0) / 255)
                let cov = Float(MaskCoverage.coverage(at: Vec2(Double(x) + 0.5, Double(y) + 0.5), masks: masks,
                                                      frame: Vec2(Double(w), Double(h)), pixel: 1, color: { _ in enc }))
                let want = SIMD3<Float>(lin709(Float(enc.r)), lin709(Float(enc.g)), lin709(Float(enc.b))) * cov
                let g = got[y * w + x]
                for i in 0..<3 { e = max(e, abs(g[i] - want[i])) }
            }
        }
        return e
    }

    @Test func hardKeyCutsTheNonMatchingHalf() throws {
        func px(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) { x < 32 ? (0, 255, 0, 255) : (0, 0, 255, 255) }
        let masks = [shape(ColorRangeKey(red: 0, green: 1, blue: 0, tolerance: 0.2, softness: 0))]
        let layer = RenderLayer(content: .frame(makeBGRA(w, h, px), colorHint: info(w, h)))
        guard let got = try render(tree(layer, masks: masks), w, h) else { return }
        #expect(worst(got, px, masks) <= tol)
        #expect(got[5 * w + 10][1] > 0.9)       // green half stays
        #expect(got[5 * w + 50][0] < 0.01)      // red half is cut
    }

    @Test func softGradientInvertedWithOpacityMatchesCPU() throws {
        func px(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
            (UInt8(y * 7), UInt8(255 - x * 3), UInt8(x * 4), 255)
        }
        let masks = [shape(ColorRangeKey(red: 0.5, green: 0.5, blue: 0.2, tolerance: 0.1, softness: 0.3), opacity: 0.7, inverted: true)]
        let layer = RenderLayer(content: .frame(makeBGRA(w, h, px), colorHint: info(w, h)))
        guard let got = try render(tree(layer, masks: masks), w, h) else { return }
        #expect(worst(got, px, masks) <= tol)
    }

    @Test func scopedEffectAppliesOnlyWhereTheColorMatches() throws {
        // Left half green stripes, right half red stripes (4 px wide, black between). A blur scoped to "green": the red
        // stripes stay exact, the green stripes soften.
        let cw = 128, ch = 72
        func px(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
            guard (x / 4) % 2 == 0 else { return (0, 0, 0, 255) }
            return x < cw / 2 ? (0, 255, 0, 255) : (0, 0, 255, 255)
        }
        let key = ColorRangeKey(red: 0, green: 1, blue: 0, tolerance: 0.2, softness: 0)
        let segs = [EffectSegment(blurAfter: 3, scope: [shape(key)]), EffectSegment()]
        let layer = RenderLayer(content: .frame(makeBGRA(cw, ch, px), colorHint: info(cw, ch)))
        guard let got = try render(tree(layer, masks: [], segments: segs), cw, ch) else { return }
        let row = ch / 2
        // Red stripe centered at x = 100 (stripe 24 = 96..<100 is even... use x = 98): untouched.
        #expect(abs(got[row * cw + 98][0] - 1) < 0.01)
        // Green stripe x = 18 (16..<20): its neighbors are black, the blur lowers it.
        #expect(got[row * cw + 18][1] < 0.95)
    }
}
#endif
