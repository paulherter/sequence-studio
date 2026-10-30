#if canImport(Metal)
import CoreVideo
import Foundation
import Metal
import SQCore
import Testing
@testable import SQRender

// Footage fill of a text clip (`RenderLayer.stencil`): the layer is a matte of what is below it. Glyph pixels keep the
// picture under them, every other pixel of the canvas is cleared (not only the pixels of the layer's own rectangle).

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

private func read(_ t: MTLTexture) -> [SIMD4<Float>] {
    var px = [Float16](repeating: 0, count: t.width * t.height * 4)
    t.getBytes(&px, bytesPerRow: t.width * 8, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
    var out: [SIMD4<Float>] = []
    for i in 0..<(t.width * t.height) {
        let r = Float(px[i * 4]), g = Float(px[i * 4 + 1]), b = Float(px[i * 4 + 2]), a = Float(px[i * 4 + 3])
        out.append(SIMD4<Float>(r, g, b, a))
    }
    return out
}

@Suite struct StencilFillTests {
    private func run(_ layers: [RenderLayer], _ w: Int, _ h: Int) throws -> [SIMD4<Float>]? {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue(), let c = try? Compositor(device: d),
              c.blendPipeline != nil else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]; desc.storageMode = .shared
        let t = d.makeTexture(descriptor: desc)!
        let cb = q.makeCommandBuffer()!
        try c.render(layers, format: SequenceFormat(width: w, height: h, frameDuration: Time(1, 25)), into: t, commandBuffer: cb)
        cb.commit(); cb.waitUntilCompleted()
        #expect(cb.error == nil)
        return read(t)
    }

    /// Opaque picture below; a layer whose left half is covered and right half transparent above it.
    private func scene(stencil: Bool, opacity: Double = 1) -> [RenderLayer] {
        let w = 8, h = 8
        let below = RenderLayer(content: .frame(bgra(w, h) { _, _ in (0, 0, 255, 255) }, colorHint: hint(w, h)))
        let matte = bgra(w, h) { x, _ in x < 4 ? (255, 255, 255, 255) : (0, 0, 0, 0) }
        var top = RenderLayer(content: .frame(matte, colorHint: hint(w, h)))
        top.footageFill = stencil ? .stencil : nil
        top.transform.opacity = opacity
        return [below, top]
    }

    @Test func coveredPixelsKeepThePictureAndTheRestIsCleared() throws {
        guard let px = try run(scene(stencil: true), 8, 8) else { return }
        for y in 0..<8 {
            let kept = px[y * 8 + 1], gone = px[y * 8 + 6]
            #expect(kept.x > 0.9 && kept.y < 0.01 && kept.w > 0.99, "covered \(kept)")
            #expect(gone == .zero, "cleared \(gone)")
        }
    }

    @Test func withoutTheFlagTheLayerIsPlain() throws {
        guard let px = try run(scene(stencil: false), 8, 8) else { return }
        #expect(px[1].y > 0.9 && px[6].x > 0.9 && px[6].y < 0.01)     // white glyph over red; red stays right
    }

    @Test func invertedFillShowsTheNegativeUnderTheGlyph() throws {
        var layers = scene(stencil: false)
        layers[1].footageFill = .inverted
        layers[1] = layers[1].applying(LayerRequest(clip: UUID(), media: UUID(), track: UUID(), sourceTime: .zero))
        guard let px = try run(layers, 8, 8) else { return }
        #expect(px[1].x < 0.01 && px[1].y > 0.9 && px[1].z > 0.9, "inverted \(px[1])")   // red below -> cyan
        #expect(px[6].x > 0.9 && px[6].y < 0.01)                                         // outside the glyph: untouched
    }

    @Test func opacityMixesTheMatteWithThePicture() throws {
        guard let px = try run(scene(stencil: true, opacity: 0.5), 8, 8) else { return }
        // Outside the glyph the picture fades to half, inside it stays whole.
        #expect(abs(px[6].x - px[1].x * 0.5) < 0.02 && abs(px[6].w - 0.5) < 0.02, "\(px[6]) \(px[1])")
    }
}
#endif
