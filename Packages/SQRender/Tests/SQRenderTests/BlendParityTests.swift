#if canImport(Metal)
import CoreVideo
import Foundation
import Metal
import SQCore
import Testing
@testable import SQRender

// The full blend set (27 modes): CPU reference maths, CPU vs GPU on a dense grid for every mode, Dissolve's pattern, and the
// 4K cost of each mode against Normal.

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

private func hint(_ w: Int, _ h: Int) -> VideoTrackInfo {
    VideoTrackInfo(width: w, height: h, codec: "hvc1", bitDepth: 8, chroma: "4:2:0",
                   nominalFrameDuration: Time(1, 25), isVariableFrameRate: false)
}

private func fmt(_ w: Int, _ h: Int) -> SequenceFormat { SequenceFormat(width: w, height: h, frameDuration: Time(1, 25)) }

private func target(_ d: MTLDevice, _ w: Int, _ h: Int) -> MTLTexture {
    let t = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
    t.usage = [.renderTarget, .shaderRead]; t.storageMode = .shared
    return d.makeTexture(descriptor: t)!
}

private func setup() -> (MTLDevice, MTLCommandQueue, Compositor)? {
    guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue(), let c = try? Compositor(device: d),
          c.blendPipeline != nil else { return nil }
    return (d, q, c)
}

@discardableResult
private func render(_ comp: Compositor, _ q: MTLCommandQueue, _ layers: [RenderLayer], _ w: Int, _ h: Int, into t: MTLTexture) throws -> MTLCommandBuffer {
    let cb = q.makeCommandBuffer()!
    try comp.render(layers, format: fmt(w, h), into: t, commandBuffer: cb)
    cb.commit(); cb.waitUntilCompleted()
    #expect(cb.error == nil)
    return cb
}

private func readAll(_ t: MTLTexture) -> [SIMD4<Float>] {
    var px = [Float16](repeating: 0, count: t.width * t.height * 4)
    t.getBytes(&px, bytesPerRow: t.width * 8, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
    var out: [SIMD4<Float>] = []
    out.reserveCapacity(t.width * t.height)
    for i in 0..<(t.width * t.height) {
        let r = Float(px[i * 4]), g = Float(px[i * 4 + 1]), b = Float(px[i * 4 + 2]), a = Float(px[i * 4 + 3])
        out.append(SIMD4<Float>(r, g, b, a))
    }
    return out
}

private func lin709(_ e: Float) -> Float {
    e < 0.081242858 ? e / 4.5 : powf((e + 0.09929682680944) / 1.09929682680944, 1 / 0.45)
}

/// Linear premultiplied value of an 8-bit BGRA pixel (what the compositor makes of it). BGRA buffers are premultiplied.
private func linear(_ c: (UInt8, UInt8, UInt8, UInt8)) -> SIMD4<Float> {
    let a = Float(c.3) / 255
    guard a > 0 else { return .zero }
    let st = SIMD3(Float(c.2), Float(c.1), Float(c.0)) / 255 / a
    return SIMD4(lin709(st.x) * a, lin709(st.y) * a, lin709(st.z) * a, a)
}

private func layer(_ pb: CVPixelBuffer, _ w: Int, _ h: Int, blend: BlendMode = .normal) -> RenderLayer {
    RenderLayer(content: .frame(pb, colorHint: hint(w, h)), blendMode: blend)
}

private func near(_ a: SIMD4<Float>, _ e: SIMD4<Float>, _ tol: Float, _ note: String = "") {
    for i in 0..<4 { #expect(abs(a[i] - e[i]) <= tol, "\(note) ch\(i): got \(a[i]) want \(e[i])") }
}

private func near3(_ a: SIMD3<Float>, _ e: SIMD3<Float>, _ tol: Float, _ note: String = "") {
    for i in 0..<3 { #expect(abs(a[i] - e[i]) <= tol, "\(note) ch\(i): got \(a[i]) want \(e[i])") }
}

@Suite struct BlendParityMathTests {
    @Test func separableNewModes() {
        let d = SIMD3<Float>(0.25, 0.5, 0.8)
        // Linear Light: cd + 2cs - 1 (floored at 0); Subtract; Divide; Pin Light; Hard Mix; Vivid Light.
        near3(BlendModes.channel(.linearLight, backdrop: d, source: SIMD3(repeating: 0.75)), SIMD3(0.75, 1.0, 1.3), 1e-6)
        near3(BlendModes.channel(.linearLight, backdrop: d, source: SIMD3(repeating: 0.25)), SIMD3(0, 0, 0.3), 1e-6)
        near3(BlendModes.channel(.subtract, backdrop: d, source: SIMD3(repeating: 0.4)), SIMD3(0, 0.1, 0.4), 1e-6)
        near3(BlendModes.channel(.divide, backdrop: d, source: SIMD3(repeating: 1)), d, 1e-6)          // by white: unchanged
        near3(BlendModes.channel(.divide, backdrop: d, source: SIMD3(repeating: 0.5)), SIMD3(0.5, 1, 1), 1e-6)
        near3(BlendModes.channel(.pinLight, backdrop: d, source: SIMD3(repeating: 0.2)), SIMD3(0.25, 0.4, 0.4), 1e-6)
        near3(BlendModes.channel(.pinLight, backdrop: d, source: SIMD3(repeating: 0.9)), SIMD3(0.8, 0.8, 0.8), 1e-6)
        near3(BlendModes.channel(.hardMix, backdrop: d, source: SIMD3(repeating: 0.5)), SIMD3(0, 1, 1), 1e-6)
        near3(BlendModes.channel(.vividLight, backdrop: d, source: SIMD3(repeating: 0.5)), d, 1e-6)    // mid: identity
        near3(BlendModes.channel(.vividLight, backdrop: d, source: SIMD3(repeating: 0.75)), SIMD3(0.5, 1, 1), 1e-6)
    }

    @Test func componentModesSwapHueSaturationAndLuminance() {
        let red = SIMD3<Float>(1, 0, 0), grey = SIMD3<Float>(repeating: 0.4), d = SIMD3<Float>(0.2, 0.5, 0.3)
        let lum = BlendModes.lum
        // Luminosity keeps the backdrop's hue and takes the source's luminance (gray source -> backdrop at 0.4 luminance).
        #expect(abs(lum(BlendModes.channel(.luminosity, backdrop: d, source: grey)) - 0.4) < 1e-5)
        // Color takes the source's hue and saturation at the backdrop's luminance.
        let c = BlendModes.channel(.color, backdrop: d, source: red)
        #expect(abs(lum(c) - lum(d)) < 1e-5 && c.x > c.y && abs(c.y - c.z) < 1e-6)
        // A gray source has no hue and no saturation: Saturation and Color leave a gray at the backdrop's luminance.
        near3(BlendModes.channel(.saturation, backdrop: d, source: grey), SIMD3(repeating: lum(d)), 1e-5)
        near3(BlendModes.channel(.color, backdrop: d, source: grey), SIMD3(repeating: lum(d)), 1e-5)
        // Hue onto gray: no saturation to carry, so gray stays gray.
        near3(BlendModes.channel(.hue, backdrop: grey, source: red), grey, 1e-5)
        // Results stay in gamut (ClipColor): nothing below 0, nothing above 1 when luminance < 1.
        for m in [BlendMode.hue, .saturation, .color, .luminosity] {
            let o = BlendModes.channel(m, backdrop: SIMD3(0.9, 0.95, 0.1), source: SIMD3(0.05, 0.1, 1))
            #expect(o.min() >= -1e-6 && o.max() <= 1 + 1e-5, "\(m) \(o)")
        }
        // Darker / Lighter Color pick the whole color with the lower / higher luminance.
        near3(BlendModes.channel(.darkerColor, backdrop: d, source: red), red, 1e-6)          // lum(red) 0.2126 < 0.4
        near3(BlendModes.channel(.lighterColor, backdrop: d, source: red), d, 1e-6)
    }

    @Test func dissolvePatternIsFixedAndCoversByAlpha() {
        var on = 0
        for y in 0..<64 { for x in 0..<64 where BlendModes.dissolveThreshold(x: x, y: y) < 0.3 { on += 1 } }
        #expect(abs(Double(on) / 4096 - 0.3) < 0.03)
        #expect(BlendModes.dissolveThreshold(x: 7, y: 9) == BlendModes.dissolveThreshold(x: 7, y: 9))
        // Opaque source: Dissolve is Normal.
        let s = SIMD4<Float>(0.2, 0.3, 0.4, 1), d = SIMD4<Float>(0.5, 0.5, 0.5, 1)
        near(BlendModes.blend(.dissolve, source: s, destination: d, x: 3, y: 4), s, 1e-6)
    }

    @Test func overATransparentBackdropTheSourceIsUntouched() {
        let s = SIMD4<Float>(0.25, 0.1, 0.05, 0.5)
        for m in BlendMode.allCases where m != .dissolve { near(BlendModes.blend(m, source: s, destination: .zero), s, 1e-6, "\(m)") }
    }
}

@Suite struct BlendParityGPUTests {
    /// 64 x 64 grid: the backdrop sweeps one set of colors, the source another (both sides of linear 0.5, saturated hues,
    /// grays, black and white), so every branch of every mode is hit. GPU vs CPU per pixel.
    @Test func gpuMatchesCPUOnADenseGridForEveryMode() throws {
        guard let (dev, q, comp) = setup() else { return }
        let n = 64
        func bg(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
            (UInt8((x * 4) & 255), UInt8((y * 4 + 37) & 255), UInt8((x * y + 11) & 255), 255)
        }
        func fg(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
            (UInt8((y * 4 + 200) & 255), UInt8((x * 7 + y * 3) & 255), UInt8((255 - x * 4) & 255), 255)
        }
        let bgp = makeBGRA(n, n, bg), fgp = makeBGRA(n, n, fg)
        let t = target(dev, n, n)
        // Threshold modes switch at a hard edge (a value that rounds across it flips one pixel) and the divide-based ones are
        // steep near 0 or 1 (GPU pow/divide rounding is amplified). Allow up to 1 % of pixels there.
        let edgy: Set<BlendMode> = [.hardMix, .darkerColor, .lighterColor, .pinLight, .vividLight, .colorDodge, .colorBurn,
                                    .divide, .hardLight, .overlay, .softLight]
        for mode in BlendMode.allCases {
            try render(comp, q, [layer(bgp, n, n), layer(fgp, n, n, blend: mode)], n, n, into: t)
            let got = readAll(t)
            var bad = 0, worst: Float = 0
            for y in 0..<n {
                for x in 0..<n {
                    let want = BlendModes.blend(mode, source: linear(fg(x, y)), destination: linear(bg(x, y)), x: x, y: y)
                    let g = got[y * n + x]
                    var e: Float = 0
                    for c in 0..<4 { e = max(e, abs(g[c] - want[c]) / max(1, abs(want[c]))) }
                    worst = max(worst, e)
                    if e > 0.006 { bad += 1 }
                }
            }
            let allowed = edgy.contains(mode) ? n * n / 100 : 0
            if bad > 0 { print("PERF blend parity \(mode.rawValue): \(bad) px off, worst \(worst)") }
            #expect(bad <= allowed, "\(mode): \(bad) px off (worst \(worst))")
        }
    }

    /// Dissolve at 50 % opacity (straight-alpha still): the GPU picks exactly the CPU's pixels.
    @Test func dissolveMatchesCPUPerPixel() throws {
        guard let (dev, q, comp) = setup() else { return }
        let n = 64
        let bgp = makeBGRA(n, n) { _, _ in (40, 40, 40, 255) }
        let src: (UInt8, UInt8, UInt8, UInt8) = (50, 75, 100, 128)   // premultiplied
        let fgp = makeBGRA(n, n) { _, _ in src }
        let t = target(dev, n, n)
        try render(comp, q, [layer(bgp, n, n), layer(fgp, n, n, blend: .dissolve)], n, n, into: t)
        let got = readAll(t)
        var mismatch = 0, on = 0
        let base = linear((40, 40, 40, 255))
        for y in 0..<n {
            for x in 0..<n {
                let want = BlendModes.blend(.dissolve, source: linear(src), destination: base, x: x, y: y)
                let g = got[y * n + x]
                if abs(g.x - want.x) > 0.006 || abs(g.z - want.z) > 0.006 { mismatch += 1 }
                if abs(g.x - base.x) > 0.01 { on += 1 }
            }
        }
        #expect(mismatch <= 2, "\(mismatch) px differ")
        #expect(abs(Double(on) / Double(n * n) - 0.5) < 0.05, "\(on) px show the source")
    }
}

@Suite(.serialized) struct BlendCostTests {
    /// GPU ms at 4K of a two-layer frame (plain backdrop + full-frame layer) per blend mode, against Normal. Printed as
    /// SQBLENDCOST; the bound is generous (a regression guard, not a benchmark).
    @Test func measure4KCostPerMode() throws {
        guard let (dev, q, comp) = setup() else { return }
        let w = 3840, h = 2160
        let bgp = makeBGRA(w, h) { x, y in (UInt8(x & 255), UInt8(y & 255), 128, 255) }
        let fgp = makeBGRA(w, h) { x, y in (UInt8((x ^ y) & 255), 90, UInt8((x + y) & 255), 255) }
        let t = target(dev, w, h)
        func gpuMs(_ m: BlendMode) throws -> Double {
            var times: [Double] = []
            for i in 0..<12 {
                let cb = try render(comp, q, [layer(bgp, w, h), layer(fgp, w, h, blend: m)], w, h, into: t)
                if i >= 2 { times.append((cb.gpuEndTime - cb.gpuStartTime) * 1000) }
            }
            return times.sorted()[times.count / 2]
        }
        for _ in 0..<30 { try render(comp, q, [layer(bgp, w, h), layer(fgp, w, h, blend: .multiply)], w, h, into: t) }   // GPU clocks up
        let normal = try gpuMs(.normal)
        var line = "4K two layers: Normal \(String(format: "%.2f", normal)) ms"
        var worst = 0.0
        for (i, m) in BlendMode.allCases.enumerated() where m != .normal {
            let ms = try gpuMs(m)
            worst = max(worst, ms - normal)
            line += ", \(m.rawValue) \(String(format: "%.2f", ms))"
            if i % 6 == 0 { print("PERF blend 4K \(line)"); line = "" }
        }
        line += "; worst over Normal \(String(format: "%.2f", worst)) ms"
        NSLog("SQBLENDCOST %@", line)
        print("PERF blend 4K \(line)")
        #expect(worst < 8, "\(line)")
    }
}
#endif
