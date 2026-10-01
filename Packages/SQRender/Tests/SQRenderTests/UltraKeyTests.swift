import CoreVideo
import Foundation
import Metal
import SQCore
import Testing
@testable import SQRender

private func lin709(_ e: Float) -> Float {
    e < 0.081242858 ? e / 4.5 : powf((e + 0.09929682680944) / 1.09929682680944, 1 / 0.45)
}

private func makeStrip(_ colors: [(UInt8, UInt8, UInt8)]) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
    precondition(CVPixelBufferCreate(nil, colors.count, 1, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess)
    let b = pb!
    CVPixelBufferLockBaseAddress(b, [])
    defer { CVPixelBufferUnlockBaseAddress(b, []) }
    let base = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
    for (i, c) in colors.enumerated() { base[i * 4] = c.2; base[i * 4 + 1] = c.1; base[i * 4 + 2] = c.0; base[i * 4 + 3] = 255 }
    return b
}

@Suite struct UltraKeyTests {
    private let green = ChromaKey(hue: 120, halfWidth: 36, soft: 13, spill: 0.5)

    @Test func greenIsKeyedOutAndOthersStay() {
        let g = UltraKey.apply(rgb: SIMD3(0.05, 0.6, 0.05), alpha: 1, keys: [green])
        #expect(g.alpha < 0.01)
        let red = UltraKey.apply(rgb: SIMD3(0.7, 0.1, 0.1), alpha: 1, keys: [green])
        #expect(red.alpha == 1 && red.rgb == SIMD3(0.7, 0.1, 0.1))
        let grey = UltraKey.apply(rgb: SIMD3(0.4, 0.4, 0.4), alpha: 1, keys: [green])
        #expect(grey.alpha == 1)                                  // no saturation: nothing to key
        let black = UltraKey.apply(rgb: SIMD3(0, 0, 0), alpha: 1, keys: [green])
        #expect(black.alpha == 1)
    }

    @Test func softEdgeFallsOffWithHueDistance() {
        // Hue 120 +- 36 is fully keyed, then 13 degrees of ramp.
        func alpha(forHue h: Float) -> Float {
            // Build a colour with that hue and saturation 0.8.
            let c = h / 60
            let x = 1 - abs(c.truncatingRemainder(dividingBy: 2) - 1)
            let (r, g, b): (Float, Float, Float) = c < 1 ? (1, x, 0) : c < 2 ? (x, 1, 0) : c < 3 ? (0, 1, x) : c < 4 ? (0, x, 1) : c < 5 ? (x, 0, 1) : (1, 0, x)
            let m: Float = 0.2
            return UltraKey.apply(rgb: SIMD3(r * 0.8 + m * 0.5, g * 0.8 + m * 0.5, b * 0.8 + m * 0.5) * 0.5, alpha: 1, keys: [green]).alpha
        }
        #expect(alpha(forHue: 120) < 0.01)
        #expect(alpha(forHue: 150) < 0.01)                         // inside the tolerance
        let edge = alpha(forHue: 162)
        #expect(edge > 0.05 && edge < 0.95)                        // on the soft edge
        #expect(alpha(forHue: 220) > 0.99)                         // blue stays
    }

    @Test func spillIsDesaturatedNearTheKeyHue() {
        // A yellowish green that is not keyed (outside tolerance + soft) but inside the spill zone loses saturation.
        let c = SIMD3<Float>(0.5, 0.45, 0.1)                       // hue ~ 51 degrees
        let k = ChromaKey(hue: 120, halfWidth: 20, soft: 10, spill: 1)
        let r = UltraKey.apply(rgb: c, alpha: 1, keys: [k])
        #expect(r.alpha == 1)
        let before = UltraKey.hsv(c).s, after = UltraKey.hsv(r.rgb).s
        #expect(after < before)
    }

    @Test func twoKeysComposeAndTheThirdIsIgnoredByTheEvaluation() {
        let blue = ChromaKey(hue: 220, halfWidth: 36, soft: 13, spill: 0)
        let both = UltraKey.apply(rgb: SIMD3(0.05, 0.05, 0.7), alpha: 1, keys: [green, blue])
        #expect(both.alpha < 0.01)
        var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero)
        for _ in 0..<3 { _ = c.addEffect(kind: ClipEffect.ultraKeyKind) }
        #expect(c.effects(at: Time(1, 1)).keys.count == ChromaKey.maxPerLayer)
    }

    @Test func gpuMatchesCPU() throws {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue(), let comp = try? Compositor(device: dev) else { return }
        let colors: [(UInt8, UInt8, UInt8)] = [(20, 200, 30), (200, 40, 40), (120, 120, 120), (60, 160, 90), (200, 220, 40),
                                                (30, 50, 230), (10, 40, 10), (150, 200, 150), (255, 255, 255), (0, 0, 0)]
        let pb = makeStrip(colors)
        var fx = ClipEffects()
        fx.keys = [green]
        let w = colors.count
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: 1, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
        let t = dev.makeTexture(descriptor: d)!
        let info = VideoTrackInfo(width: w, height: 1, codec: "x", bitDepth: 8, chroma: "4:4:4",
                                  nominalFrameDuration: Time(1, 25), isVariableFrameRate: false)
        let layer = RenderLayer(content: .frame(pb, colorHint: info), effects: fx)
        let cb = q.makeCommandBuffer()!
        try comp.render([layer], format: SequenceFormat(width: w, height: 1, frameDuration: Time(1, 25)), into: t, commandBuffer: cb)
        cb.commit(); cb.waitUntilCompleted()
        var px = [Float16](repeating: 0, count: w * 4)
        t.getBytes(&px, bytesPerRow: w * 8, from: MTLRegionMake2D(0, 0, w, 1), mipmapLevel: 0)
        for (i, c) in colors.enumerated() {
            let lin = SIMD3(lin709(Float(c.0) / 255), lin709(Float(c.1) / 255), lin709(Float(c.2) / 255))
            let r = UltraKey.apply(rgb: lin, alpha: 1, keys: [green])
            let want = r.rgb * r.alpha                              // over opaque black
            for ch in 0..<3 { #expect(abs(Float(px[i * 4 + ch]) - want[ch]) < 0.01, "colour \(i) ch\(ch): \(px[i * 4 + ch]) vs \(want[ch])") }
        }
    }
}
