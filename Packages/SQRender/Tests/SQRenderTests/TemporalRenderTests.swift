#if canImport(Metal)
import CoreVideo
import Foundation
import Metal
import SQCore
import Testing
@testable import SQRender

// Video Denoise / Deflicker on the GPU (`TemporalPass`), and the cost of the temporal effects at 4K.

private func attrs() -> CFDictionary {
    [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as [CFString: Any] as CFDictionary
}

private func makeBGRA(_ w: Int, _ h: Int, _ f: (Int, Int) -> UInt8) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    precondition(CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs(), &pb) == kCVReturnSuccess)
    let b = pb!
    CVPixelBufferLockBaseAddress(b, [])
    defer { CVPixelBufferUnlockBaseAddress(b, []) }
    let base = CVPixelBufferGetBaseAddress(b)!, stride = CVPixelBufferGetBytesPerRow(b)
    for y in 0..<h { for x in 0..<w {
        let px = (base + y * stride + x * 4).assumingMemoryBound(to: UInt8.self)
        let v = f(x, y)
        px[0] = v; px[1] = v; px[2] = v; px[3] = 255
    } }
    return b
}

/// 8-bit video-range 4:2:0 (what the decoder hands over): luma from `f`, neutral chroma.
private func make420(_ w: Int, _ h: Int, _ f: (Int, Int) -> UInt8) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    precondition(CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs(), &pb) == kCVReturnSuccess)
    let b = pb!
    CVPixelBufferLockBaseAddress(b, [])
    defer { CVPixelBufferUnlockBaseAddress(b, []) }
    let yp = CVPixelBufferGetBaseAddressOfPlane(b, 0)!.assumingMemoryBound(to: UInt8.self), ys = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
    for y in 0..<h { for x in 0..<w { yp[y * ys + x] = f(x, y) } }
    let cp = CVPixelBufferGetBaseAddressOfPlane(b, 1)!.assumingMemoryBound(to: UInt8.self), cs = CVPixelBufferGetBytesPerRowOfPlane(b, 1)
    for y in 0..<(h / 2) { for x in 0..<w { cp[y * cs + x] = 128 } }
    return b
}

/// Deterministic noise in -amp...amp per pixel and frame.
private func noise(_ x: Int, _ y: Int, _ frame: Int, _ amp: Int) -> Int {
    var v = UInt32(truncatingIfNeeded: x &* 73856093 ^ y &* 19349663 ^ frame &* 83492791)
    v ^= v >> 13; v = v &* 0x5bd1e995; v ^= v >> 15
    return Int(v % UInt32(2 * amp + 1)) - amp
}

private func clamp8(_ v: Int) -> UInt8 { UInt8(max(0, min(255, v))) }

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
    guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue(), let c = try? Compositor(device: d) else { return nil }
    return (d, q, c)
}

@discardableResult
private func render(_ comp: Compositor, _ q: MTLCommandQueue, _ nodes: [RenderNode], _ w: Int, _ h: Int,
                    into t: MTLTexture) throws -> MTLCommandBuffer {
    let cb = q.makeCommandBuffer()!
    try comp.render(nodes: nodes, format: fmt(w, h), into: t, commandBuffer: cb)
    cb.commit(); cb.waitUntilCompleted()
    #expect(cb.error == nil)
    return cb
}

private func lumas(_ t: MTLTexture) -> [Float] {
    var px = [Float16](repeating: 0, count: t.width * t.height * 4)
    t.getBytes(&px, bytesPerRow: t.width * 8, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
    return (0..<(t.width * t.height)).map { i in
        0.2126 * Float(px[i * 4]) + 0.7152 * Float(px[i * 4 + 1]) + 0.0722 * Float(px[i * 4 + 2])
    }
}

private func mean(_ v: [Float]) -> Float { v.reduce(0, +) / Float(v.count) }
private func variance(_ v: [Float]) -> Float { let m = mean(v); return v.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Float(v.count) }

private func frameLayer(_ pb: CVPixelBuffer, _ w: Int, _ h: Int, _ temporal: TemporalFrames? = nil) -> RenderNode {
    var l = RenderLayer(content: .frame(pb, colorHint: hint(w, h)))
    l.temporal = temporal
    return .layer(l)
}

/// Renders `frames[center]` with `filter` and the other frames as its neighbors (nearest first on each side).
private func renderTemporal(_ frames: [CVPixelBuffer], center: Int, _ filter: TemporalFilter?, _ w: Int, _ h: Int) throws -> [Float]? {
    guard let (dev, q, comp) = setup() else { return nil }
    let t = target(dev, w, h)
    let tf = filter.map {
        TemporalFrames(filter: $0, before: Array(frames[..<center].reversed()), after: Array(frames[(center + 1)...]))
    }
    try render(comp, q, [frameLayer(frames[center], w, h, tf)], w, h, into: t)
    return lumas(t)
}

@Suite struct TemporalRenderTests {
    @Test func temporalDenoiseLowersNoiseOfAStillPicture() throws {
        let (w, h) = (64, 64)
        let frames = (0..<5).map { f in makeBGRA(w, h) { x, y in clamp8(128 + noise(x, y, f, 12)) } }
        guard let plain = try renderTemporal(frames, center: 2, nil, w, h),
              let fast = try renderTemporal(frames, center: 2, TemporalFilter(denoise: .init(framesEachSide: 2, luma: 0.6, color: 0.6)), w, h),
              let best = try renderTemporal(frames, center: 2, TemporalFilter(denoise: .init(framesEachSide: 2, best: true, luma: 0.6, color: 0.6)), w, h)
        else { return }
        #expect(variance(fast) < variance(plain) * 0.5, "fast: \(variance(fast)) vs \(variance(plain))")
        #expect(variance(best) < variance(plain) * 0.5, "best: \(variance(best)) vs \(variance(plain))")
        #expect(abs(mean(fast) - mean(plain)) < 0.01)
    }

    @Test func movingDetailIsNotSmearedIntoTheCentreFrame() throws {
        let (w, h) = (64, 64)
        // A white square that is somewhere else in every neighbor.
        func frame(_ off: Int) -> CVPixelBuffer { makeBGRA(w, h) { x, y in (x >= 8 + off && x < 24 + off && y >= 24 && y < 40) ? 235 : 30 } }
        let frames = [frame(-16), frame(-8), frame(0), frame(8), frame(16)]
        guard let out = try renderTemporal(frames, center: 2, TemporalFilter(denoise: .init(framesEachSide: 2, luma: 1, color: 1)), w, h),
              let plain = try renderTemporal(frames, center: 2, nil, w, h) else { return }
        #expect(abs(out[32 * w + 16] - plain[32 * w + 16]) < 0.01, "square stays")
        #expect(abs(out[32 * w + 30] - plain[32 * w + 30]) < 0.01, "no ghost where a neighbor's square was")
    }

    @Test func deflickerPullsAFrameToTheBrightnessOfItsNeighbours() throws {
        let (w, h) = (32, 32)
        let frames = [100, 100, 140, 100, 100].map { v in makeBGRA(w, h) { _, _ in UInt8(v) } }
        let ref = makeBGRA(w, h) { _, _ in 108 }   // (140 + 4 x 100) / 5
        for local in [false, true] {
            guard let out = try renderTemporal(frames, center: 2, TemporalFilter(deflicker: .init(framesEachSide: 2, local: local)), w, h),
                  let want = try renderTemporal([ref], center: 0, nil, w, h) else { return }
            #expect(abs(mean(out) - mean(want)) < 0.006, "local \(local): \(mean(out)) vs \(mean(want))")
        }
        // Half strength lands half way (in encoded values: 124).
        let half = makeBGRA(w, h) { _, _ in 124 }
        guard let out = try renderTemporal(frames, center: 2, TemporalFilter(deflicker: .init(framesEachSide: 2, strength: 0.5)), w, h),
              let want = try renderTemporal([half], center: 0, nil, w, h) else { return }
        #expect(abs(mean(out) - mean(want)) < 0.006)
    }

    @Test func bestDeflickerLeavesARegionThatReallyChanges() throws {
        let (w, h) = (64, 36)
        // The whole frame flickers, but the left quarter of the center frame really got brighter (a lamp switched on).
        func f(_ base: Int, lamp: Bool) -> CVPixelBuffer { makeBGRA(w, h) { x, _ in UInt8(lamp && x < 16 ? 220 : base) } }
        let frames = [f(100, lamp: false), f(100, lamp: false), f(110, lamp: true), f(100, lamp: false), f(100, lamp: false)]
        guard let fast = try renderTemporal(frames, center: 2, TemporalFilter(deflicker: .init(framesEachSide: 2, local: false)), w, h),
              let best = try renderTemporal(frames, center: 2, TemporalFilter(deflicker: .init(framesEachSide: 2, local: true)), w, h),
              let plain = try renderTemporal(frames, center: 2, nil, w, h) else { return }
        // Best keeps the lamp (within the gain map's soft edge) and still corrects the rest; Fast darkens everything.
        #expect(abs(best[18 * w + 2] - plain[18 * w + 2]) < 0.02)
        #expect(best[18 * w + 50] < plain[18 * w + 50] - 0.005)
        #expect(fast[18 * w + 2] < plain[18 * w + 2] - 0.02)
    }

    @Test func spatialDenoiseSmoothsASingleFrame() throws {
        let (w, h) = (64, 64)
        let frame = makeBGRA(w, h) { x, y in clamp8(128 + noise(x, y, 0, 10)) }
        guard let plain = try renderTemporal([frame], center: 0, nil, w, h),
              let out = try renderTemporal([frame], center: 0,
                                           TemporalFilter(denoise: .init(framesEachSide: 0, detailSize: 2, spatialLuma: 0.8, spatialColor: 0.8)), w, h)
        else { return }
        #expect(variance(out) < variance(plain) * 0.5)
    }

    @Test func withoutNeighboursTheFilterIsThePlainFrame() throws {
        let (w, h) = (32, 32)
        let frame = makeBGRA(w, h) { x, y in UInt8((x * 7 + y * 3) & 255) }
        guard let plain = try renderTemporal([frame], center: 0, nil, w, h),
              let out = try renderTemporal([frame], center: 0, TemporalFilter(denoise: .init(framesEachSide: 3)), w, h) else { return }
        #expect(plain == out)
    }

    @Test func biPlanarSourcesAreFilteredToo() throws {
        let (w, h) = (64, 64)
        let frames = (0..<3).map { f in make420(w, h) { x, y in clamp8(120 + noise(x, y, f, 10)) } }
        guard let plain = try renderTemporal(frames, center: 1, nil, w, h),
              let out = try renderTemporal(frames, center: 1, TemporalFilter(denoise: .init(framesEachSide: 1, luma: 0.8),
                                                                                deflicker: .init(framesEachSide: 1)), w, h) else { return }
        #expect(variance(out) < variance(plain) * 0.75)
        #expect(abs(mean(out) - mean(plain)) < 0.01)
    }
}

// MARK: Cost

@Suite struct TemporalCostTests {
    /// GPU ms per 4K frame (420v source, the whole command buffer) for each temporal setting. Written to NSLog, stdout and
    /// $TMPDIR/sqtemporalcost.txt (scripts/test.sh prints errors only).
    @Test func measureCost() throws {
        guard let (dev, q, comp) = setup() else { return }
        let (w, h) = (3840, 2160)
        let frames = (0..<11).map { f in make420(w, h) { x, y in clamp8(((x ^ y) & 127) + 60 + noise(x, y, f, 6)) } }
        let t = target(dev, w, h)
        func gpuMs(_ nodes: [RenderNode]) throws -> Double {
            var times: [Double] = []
            for i in 0..<12 {
                let cb = try render(comp, q, nodes, w, h, into: t)
                if i >= 2 { times.append((cb.gpuEndTime - cb.gpuStartTime) * 1000) }
            }
            return times.sorted()[times.count / 2]
        }
        func temporal(_ f: TemporalFilter) throws -> Double {
            let tf = TemporalFrames(filter: f, before: Array(frames[0..<5].reversed()), after: Array(frames[6...]))
            return try gpuMs([frameLayer(frames[5], w, h, tf)])
        }
        func dn(_ r: Int, best: Bool = false, search: Int = 1, size: Int = 0, spatial: Double = 0) -> TemporalFilter {
            TemporalFilter(denoise: .init(framesEachSide: r, best: best, motionSearch: search, detailSize: size,
                                          spatialLuma: spatial, spatialColor: spatial > 0 ? 0.2 : 0))
        }
        var cases: [(String, TemporalFilter)] = []
        for r in 1...5 { cases.append(("denoise fast r\(r)", dn(r))) }
        for r in [1, 2, 5] { for s in 0...2 { cases.append(("denoise best r\(r) search\(s)", dn(r, best: true, search: s))) } }
        for size in 1...3 { cases.append(("spatial only size\(size)", dn(0, size: size, spatial: 0.3))) }
        cases.append(("denoise default (fast r2 + spatial small)", dn(2, size: 1, spatial: 0.0001)))
        cases.append(("deflicker fast r3", TemporalFilter(deflicker: .init(framesEachSide: 3))))
        cases.append(("deflicker best r3", TemporalFilter(deflicker: .init(framesEachSide: 3, local: true))))
        cases.append(("deflicker fast r10 (5 bound)", TemporalFilter(deflicker: .init(framesEachSide: 10))))
        cases.append(("playback degrade of best r5 + deflicker best", TemporalFilter(denoise: dn(5, best: true, search: 2).denoise,
                                                                                    deflicker: .init(framesEachSide: 5, local: true)).degraded(.fast)))
        var lines = ["4K plain \(String(format: "%.2f", try gpuMs([frameLayer(frames[5], w, h)]))) ms"]
        for (n, f) in cases { lines.append("4K \(n) \(String(format: "%.2f", try temporal(f))) ms") }
        // Motion Blur (the effect = shutter copies of the layer): sample counts of Amount 25/50/100 x Coarse/Medium/Fine.
        for n in [2, 4, 8, 16, 32] {
            let ts = (0..<n).map { ClipTransform(position: Vec2(Double($0) * 4, 0)) }
            var r = LayerRequest(clip: UUID(), media: UUID(), track: UUID(), sourceTime: .zero, transform: ts[n / 2])
            r.motionBlur = MotionBlurSamples(format: fmt(w, h), transforms: ts)
            let layer = RenderLayer(content: .frame(frames[5], colorHint: hint(w, h)), transform: r.transform)
            lines.append("4K motion blur \(n) samples \(String(format: "%.2f", try gpuMs(RenderNode.tree(requests: [r], layers: [layer])))) ms")
        }
        let text = lines.joined(separator: "\n")
        NSLog("SQTEMPORALCOST %@", text)
        print("SQTEMPORALCOST\n\(text)")
        try? (text + "\n").write(toFile: NSTemporaryDirectory() + "sqtemporalcost.txt", atomically: true, encoding: .utf8)
    }
}
#endif
