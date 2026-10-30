#if canImport(Metal)
import CoreVideo
import Foundation
import Metal
import SQCore
import Testing
@testable import SQRender

private func lin709(_ e: Float) -> Float {
    e < 0.081242858 ? e / 4.5 : powf((e + 0.09929682680944) / 1.09929682680944, 1 / 0.45)
}

private func makeBuffer(_ w: Int, _ h: Int, _ f: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
    precondition(CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess)
    let b = pb!
    CVPixelBufferLockBaseAddress(b, [])
    defer { CVPixelBufferUnlockBaseAddress(b, []) }
    let base = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
    let bpr = CVPixelBufferGetBytesPerRow(b)
    for y in 0..<h { for x in 0..<w {
        let c = f(x, y), o = y * bpr + x * 4
        base[o] = c.2; base[o + 1] = c.1; base[o + 2] = c.0; base[o + 3] = 255
    } }
    return b
}

private let strip: [(UInt8, UInt8, UInt8)] = [
    (20, 200, 30), (200, 40, 40), (120, 120, 120), (60, 160, 90), (200, 220, 40), (30, 50, 230), (10, 40, 10),
    (150, 200, 150), (255, 255, 255), (0, 0, 0), (90, 170, 120), (230, 255, 230), (5, 60, 15), (40, 80, 60),
]

@Suite struct KeyingFamilyRenderTests {
    private var green: ChromaKey { ChromaKey(hue: 120, halfWidth: 36, soft: 13, spill: 0.5) }

    // MARK: CPU reference

    @Test func lumaKeyRemovesDarksOrBrights() {
        let darks = ChromaKey.luma(threshold: 0.3, softness: 0.1)
        #expect(UltraKey.apply(rgb: SIMD3(0.01, 0.01, 0.01), alpha: 1, keys: [darks]).alpha < 0.01)
        #expect(UltraKey.apply(rgb: SIMD3(0.8, 0.8, 0.8), alpha: 1, keys: [darks]).alpha > 0.99)
        let mid = UltraKey.apply(rgb: SIMD3(repeating: 0.12), alpha: 1, keys: [darks]).alpha     // encoded luma ~0.35: on the ramp
        #expect(mid > 0.05 && mid < 0.95)
        let brights = ChromaKey.luma(threshold: 0.7, softness: 0.1, brights: true)
        #expect(UltraKey.apply(rgb: SIMD3(0.99, 0.99, 0.99), alpha: 1, keys: [brights]).alpha < 0.01)
        #expect(UltraKey.apply(rgb: SIMD3(0.05, 0.05, 0.05), alpha: 1, keys: [brights]).alpha > 0.99)
    }

    @Test func sourceOutputIsUntouchedAndAlphaShowsKeptShare() {
        var src = green; src.output = .source
        let c = SIMD3<Float>(0.05, 0.6, 0.05)
        let s = UltraKey.apply(rgb: c, alpha: 1, keys: [src])
        #expect(s.rgb == c && s.alpha == 1)
        var al = green; al.output = .alpha
        #expect(UltraKey.apply(rgb: c, alpha: 1, keys: [al]).rgb.x < 0.01)
    }

    @Test func growKeepsMoreThanPlainShrinkLess() {
        let edge = SIMD3<Float>(0.1, 0.5, 0.367)                   // on the soft edge
        let plain = UltraKey.apply(rgb: edge, alpha: 1, keys: [green]).alpha
        var grow = green; grow.choke = -0.5
        var shrink = green; shrink.choke = 0.5
        #expect(UltraKey.apply(rgb: edge, alpha: 1, keys: [grow]).alpha > plain)
        #expect(UltraKey.apply(rgb: edge, alpha: 1, keys: [shrink]).alpha < plain)
    }

    @Test func matteContrastSteepensTheEdge() {
        let edge = SIMD3<Float>(0.1, 0.5, 0.367)
        let plain = UltraKey.apply(rgb: edge, alpha: 1, keys: [green]).alpha
        var hard = green; hard.contrast = 1; hard.midpoint = plain > 0.5 ? 0.5 : 0.5
        let a = UltraKey.apply(rgb: edge, alpha: 1, keys: [hard]).alpha
        #expect(abs(a - 0.5) >= abs(plain - 0.5))                  // pushed away from the pivot
    }

    @Test func keepHighlightsAndShadowsHoldBackTheKey() {
        let bright = SIMD3<Float>(0.7, 1.0, 0.7)                   // light green: inside the key hue
        let dark = SIMD3<Float>(0.0, 0.012, 0.0)
        #expect(UltraKey.apply(rgb: bright, alpha: 1, keys: [green]).alpha < 0.05)
        var kh = green; kh.keepHighlights = 1
        #expect(UltraKey.apply(rgb: bright, alpha: 1, keys: [kh]).alpha > 0.95)
        let darkPlain = UltraKey.apply(rgb: dark, alpha: 1, keys: [green]).alpha
        var ks = green; ks.keepShadows = 1
        #expect(UltraKey.apply(rgb: dark, alpha: 1, keys: [ks]).alpha >= darkPlain)
        // Mid-tone green is not affected by either.
        let mid = SIMD3<Float>(0.04, 0.4, 0.04)
        var both = green; both.keepHighlights = 1; both.keepShadows = 1
        #expect(UltraKey.apply(rgb: mid, alpha: 1, keys: [both]).alpha == UltraKey.apply(rgb: mid, alpha: 1, keys: [green]).alpha)
    }

    @Test func colourCorrectionActsOnTheKeptPictureOnly() {
        var k = green; k.saturation = 0
        let red = UltraKey.apply(rgb: SIMD3(0.7, 0.1, 0.1), alpha: 1, keys: [k])
        #expect(abs(red.rgb.x - red.rgb.y) < 1e-5 && abs(red.rgb.y - red.rgb.z) < 1e-5)   // fully desaturated
        var dim = green; dim.luma = 0.5
        let d = UltraKey.apply(rgb: SIMD3(0.7, 0.1, 0.1), alpha: 1, keys: [dim])
        #expect(abs(d.rgb.x - 0.35) < 1e-5)
        var rot = green; rot.hueShift = 120
        let r = UltraKey.apply(rgb: SIMD3(0.7, 0.1, 0.1), alpha: 1, keys: [rot]).rgb
        #expect(r.y > r.x && r.y > r.z)                            // red turned towards green
    }

    @Test func spillRangeWidensTheZone() {
        let c = SIMD3<Float>(0.5, 0.45, 0.1)                       // hue ~ 51, outside tolerance
        var narrow = ChromaKey(hue: 120, halfWidth: 20, soft: 10, spill: 1); narrow.spillRange = 0
        var wide = narrow; wide.spillRange = 1
        let sn = UltraKey.hsv(UltraKey.apply(rgb: c, alpha: 1, keys: [narrow]).rgb).s
        let sw = UltraKey.hsv(UltraKey.apply(rgb: c, alpha: 1, keys: [wide]).rgb).s
        #expect(sw < sn)
    }

    // MARK: GPU

    private func render(_ keys: [ChromaKey], strip colors: [(UInt8, UInt8, UInt8)]) throws -> [Float16]? {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue(), let comp = try? Compositor(device: dev) else { return nil }
        let w = colors.count
        let pb = makeBuffer(w, 1) { x, _ in colors[x] }
        var fx = ClipEffects(); fx.keys = keys
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
        return px
    }

    private func expectParity(_ keys: [ChromaKey], _ name: String) throws {
        guard let px = try render(keys, strip: strip) else { return }
        for (i, c) in strip.enumerated() {
            let lin = SIMD3(lin709(Float(c.0) / 255), lin709(Float(c.1) / 255), lin709(Float(c.2) / 255))
            let r = UltraKey.apply(rgb: lin, alpha: 1, keys: keys)
            let want = r.rgb * r.alpha
            for ch in 0..<3 { #expect(abs(Float(px[i * 4 + ch]) - want[ch]) < 0.012, "\(name) color \(i) ch\(ch): \(px[i * 4 + ch]) vs \(want[ch])") }
        }
    }

    @Test func gpuMatchesCPUForTheFullUltraKey() throws {
        var k = green
        k.choke = 0.25; k.pedestal = 0.1; k.contrast = 0.4; k.midpoint = 0.45
        k.keepHighlights = 0.5; k.keepShadows = 0.3; k.spillRange = 0.8
        k.saturation = 1.3; k.hueShift = 25; k.luma = 0.9
        try expectParity([k], "ultra")
        var grow = green; grow.choke = -0.6
        try expectParity([grow], "grow")
    }

    @Test func gpuMatchesCPUForLumaSourceAndAlphaViews() throws {
        try expectParity([ChromaKey.luma(threshold: 0.35, softness: 0.15)], "luma darks")
        var br = ChromaKey.luma(threshold: 0.7, softness: 0.2, brights: true); br.choke = 0.3
        try expectParity([br], "luma brights")
        var src = green; src.output = .source
        try expectParity([src], "source")
        var al = green; al.output = .alpha
        try expectParity([al], "alpha")
        // A luma and a chroma key in one pass.
        try expectParity([ChromaKey.luma(threshold: 0.1, softness: 0.05), green], "two keys")
    }

    /// Perf (printed): GPU time of a 4K layer into a 4K canvas: no key, plain chroma key, and the full Ultra Key (every
    /// new control on). The new controls are per-pixel arithmetic only: the full key must stay within 2x of the plain key.
    @Test func fourKCostOfTheFullKey() throws {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return }
        let pb = makeBuffer(3840, 2160) { x, y in (UInt8((x / 15) & 255), UInt8(((x + y) / 9) & 255), UInt8((y / 8) & 255)) }
        let f = SequenceFormat(width: 3840, height: 2160, frameDuration: Time(1, 30))
        let info = VideoTrackInfo(width: 3840, height: 2160, codec: "x", bitDepth: 8, chroma: "4:4:4",
                                  nominalFrameDuration: Time(1, 30), isVariableFrameRate: false)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: f.width, height: f.height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
        let target = dev.makeTexture(descriptor: d)!
        let comp = try Compositor(device: dev)
        func gpu(_ keys: [ChromaKey]) throws -> Double {
            var fx = ClipEffects(); fx.keys = keys
            let layer = RenderLayer(content: .frame(pb, colorHint: info), effects: fx)
            var best = Double.infinity
            for _ in 0..<8 {
                let cb = q.makeCommandBuffer()!
                try comp.render([layer], format: f, into: target, commandBuffer: cb)
                cb.commit(); cb.waitUntilCompleted()
                best = min(best, cb.gpuEndTime - cb.gpuStartTime)
            }
            return best * 1000
        }
        var full = green
        full.choke = 0.25; full.pedestal = 0.1; full.contrast = 0.4; full.keepHighlights = 0.5; full.keepShadows = 0.3
        full.saturation = 1.3; full.hueShift = 25; full.luma = 0.9
        let none = try gpu([]), plain = try gpu([green]), fullMs = try gpu([full]), luma = try gpu([ChromaKey.luma(threshold: 0.3, softness: 0.1)])
        print(String(format: "KEYING 4K GPU ms: none %.2f, chroma %.2f, full ultra %.2f, luma %.2f", none, plain, fullMs, luma))
        #expect(fullMs < max(plain * 2, plain + 1.5), "full key \(fullMs) ms vs plain \(plain) ms")
    }
}
#endif
