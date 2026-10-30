#if canImport(Metal)
import CoreVideo
import Foundation
import Metal
import SQCore
import Testing
@testable import SQRender

// C4 Trails on the GPU (`TemporalPass`): earlier source frames laid over the shown one, each weaker than the one before.

private func attrs() -> CFDictionary {
    [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as [CFString: Any] as CFDictionary
}

private func makeBGRA(_ w: Int, _ h: Int, alpha: UInt8 = 255, _ f: (Int, Int) -> UInt8) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    precondition(CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs(), &pb) == kCVReturnSuccess)
    let b = pb!
    CVPixelBufferLockBaseAddress(b, [])
    defer { CVPixelBufferUnlockBaseAddress(b, []) }
    let base = CVPixelBufferGetBaseAddress(b)!, stride = CVPixelBufferGetBytesPerRow(b)
    for y in 0..<h { for x in 0..<w {
        let px = (base + y * stride + x * 4).assumingMemoryBound(to: UInt8.self)
        let v = f(x, y)
        px[0] = v; px[1] = v; px[2] = v; px[3] = alpha
    } }
    return b
}

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

private func frameLayer(_ pb: CVPixelBuffer, _ w: Int, _ h: Int, _ temporal: TemporalFrames? = nil) -> RenderNode {
    var l = RenderLayer(content: .frame(pb, colorHint: hint(w, h)))
    l.temporal = temporal
    return .layer(l)
}

/// Renders `center` with `filter` and `before` as its earlier frames (nearest first).
private func renderTrails(_ center: CVPixelBuffer, before: [CVPixelBuffer], _ filter: TemporalFilter?, _ w: Int, _ h: Int) throws -> [Float]? {
    guard let (dev, q, comp) = setup() else { return nil }
    let t = target(dev, w, h)
    try render(comp, q, [frameLayer(center, w, h, filter.map { TemporalFrames(filter: $0, before: before) })], w, h, into: t)
    return lumas(t)
}

/// The plain (unfiltered) result of a flat frame of encoded value `v`.
private func flat(_ v: Int, _ w: Int, _ h: Int) throws -> Float? {
    try renderTrails(makeBGRA(w, h) { _, _ in UInt8(max(0, min(255, v))) }, before: [], nil, w, h)?[0]
}

/// Four earlier frames with a bright bar at x 8k...8k+7 in frame k (k = 1 nearest); the center is dark everywhere.
private let (bw, bh) = (48, 8)
private let dark = 20, bright = 200
private func bars() -> (CVPixelBuffer, [CVPixelBuffer]) {
    let center = makeBGRA(bw, bh) { _, _ in UInt8(dark) }
    let before = (1...4).map { k in makeBGRA(bw, bh) { x, _ in UInt8(x >= 8 * k && x < 8 * k + 8 ? bright : dark) } }
    return (center, before)
}
private func at(_ v: [Float], bar k: Int) -> Float { v[4 * bw + 8 * k + 4] }

@Suite struct TrailsRenderTests {
    @Test func addLaysEachEchoOverWithItsDecayedWeight() throws {
        let (c, b) = bars()
        let f = TemporalFilter(trails: .init(count: 2, spacing: 1, decay: 0.5, blend: .add))
        guard let out = try renderTrails(c, before: b, f, bw, bh),
              let e1 = try flat(Int((Double(dark) + 0.5 * Double(bright) + 0.25 * Double(dark)).rounded()), bw, bh),
              let e2 = try flat(Int((Double(dark) + 0.5 * Double(dark) + 0.25 * Double(bright)).rounded()), bw, bh),
              let bg = try flat(dark + Int((0.75 * Double(dark)).rounded()), bw, bh) else { return }
        // Echo 1 (weight 0.5) and echo 2 (0.25) at their bars; both echoes carry the dark background too.
        #expect(abs(at(out, bar: 1) - e1) < 0.006, "\(at(out, bar: 1)) vs \(e1)")
        #expect(abs(at(out, bar: 2) - e2) < 0.006, "\(at(out, bar: 2)) vs \(e2)")
        #expect(abs(at(out, bar: 3) - bg) < 0.006)
        // Trails decay: the older echo is the weaker one.
        #expect(at(out, bar: 1) > at(out, bar: 2) && at(out, bar: 2) > at(out, bar: 3))
    }

    @Test func spacingSkipsFramesBetweenEchoes() throws {
        let (c, b) = bars()
        let f = TemporalFilter(trails: .init(count: 2, spacing: 2, decay: 0, blend: .lighten))
        guard let out = try renderTrails(c, before: b, f, bw, bh), let hi = try flat(bright, bw, bh),
              let lo = try flat(dark, bw, bh) else { return }
        // Frames 2 and 4 are the echoes; 1 and 3 are skipped.
        #expect(abs(at(out, bar: 2) - hi) < 0.006 && abs(at(out, bar: 4) - hi) < 0.006)
        #expect(abs(at(out, bar: 1) - lo) < 0.006 && abs(at(out, bar: 3) - lo) < 0.006)
    }

    /// A backward trail (reversed clip) reads its echoes from the frames after the shown one; the before side is ignored.
    @Test func backwardTrailsReadTheFramesAhead() throws {
        let (c, b) = bars()
        var tr = TemporalFilter.Trails(count: 2, spacing: 1, decay: 0, blend: .lighten)
        tr.backward = true
        guard let (dev, q, comp) = setup(), let hi = try flat(bright, bw, bh), let lo = try flat(dark, bw, bh) else { return }
        let t = target(dev, bw, bh)
        let flipped = [makeBGRA(bw, bh) { _, _ in UInt8(bright) }]   // a bright "before" frame that must not show
        try render(comp, q, [frameLayer(c, bw, bh, TemporalFrames(filter: TemporalFilter(trails: tr), before: flipped, after: b))],
                   bw, bh, into: t)
        let out = lumas(t)
        #expect(abs(at(out, bar: 1) - hi) < 0.006 && abs(at(out, bar: 2) - hi) < 0.006)
        #expect(abs(at(out, bar: 3) - lo) < 0.006)
    }

    @Test func screenAndLightenStayBelowWhite() throws {
        let (c, b) = bars()
        for blend in [TemporalFilter.Trails.Blend.screen, .lighten] {
            let f = TemporalFilter(trails: .init(count: 4, spacing: 1, decay: 0, blend: blend))
            guard let out = try renderTrails(c, before: b, f, bw, bh), let hi = try flat(bright, bw, bh) else { return }
            if blend == .lighten {
                #expect(abs(at(out, bar: 3) - hi) < 0.006)
            } else {
                // 1 - (1 - 20/255) * (1 - 200/255) * (1 - 20/255)^3 in encoded values.
                let d = Double(dark) / 255, br = Double(bright) / 255
                let want = 1 - (1 - d) * (1 - br) * pow(1 - d, 3)
                guard let ref = try flat(Int((want * 255).rounded()), bw, bh) else { return }
                #expect(abs(at(out, bar: 3) - ref) < 0.008, "\(at(out, bar: 3)) vs \(ref)")
            }
            #expect(out.allSatisfy { $0 <= 1.0001 })
        }
    }

    @Test func withoutEarlierFramesTheFilterIsThePlainFrame() throws {
        let (c, _) = bars()
        let f = TemporalFilter(trails: .init(count: 4, spacing: 2, decay: 0.3, blend: .screen))
        guard let plain = try renderTrails(c, before: [], nil, bw, bh), let out = try renderTrails(c, before: [], f, bw, bh) else { return }
        #expect(plain == out)
    }

    /// A reduced-size center never blends a full-size echo: the first frame of another size ends the list.
    @Test func echoOfAnotherSizeEndsTheList() throws {
        let (c, b) = bars()
        let big = makeBGRA(bw * 2, bh * 2) { _, _ in 255 }
        let f = TemporalFilter(trails: .init(count: 3, spacing: 1, decay: 0, blend: .lighten))
        guard let out = try renderTrails(c, before: [b[0], big, b[2]], f, bw, bh), let hi = try flat(bright, bw, bh),
              let lo = try flat(dark, bw, bh) else { return }
        #expect(abs(at(out, bar: 1) - hi) < 0.006)
        #expect(abs(at(out, bar: 3) - lo) < 0.006)
    }

    /// A transparent center (a cutout) shows its echoes, with their faded alpha.
    @Test func echoesShowThroughATransparentCentre() throws {
        let (w, h) = (16, 4)
        let center = makeBGRA(w, h, alpha: 0) { _, _ in 0 }
        let echo = makeBGRA(w, h) { _, _ in 255 }
        guard let (dev, q, comp) = setup() else { return }
        let t = target(dev, w, h)
        let f = TemporalFilter(trails: .init(count: 2, spacing: 1, decay: 0.5, blend: .screen))
        try render(comp, q, [frameLayer(center, w, h, TemporalFrames(filter: f, before: [echo]))], w, h, into: t)
        var px = [Float16](repeating: 0, count: w * h * 4)
        t.getBytes(&px, bytesPerRow: w * 8, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        // Half of the white echo shows (alpha 0.5).
        #expect(Float(px[0]) > 0.3 && Float(px[0]) < 0.8, "\(px[0]) \(px[3])")
    }

    @Test func trailsFollowDenoise() throws {
        let (c, b) = bars()
        let f = TemporalFilter(denoise: .init(framesEachSide: 0, detailSize: 1, spatialLuma: 0.2, spatialColor: 0.2),
                               trails: .init(count: 2, spacing: 1, decay: 0, blend: .lighten))
        guard let out = try renderTrails(c, before: b, f, bw, bh), let hi = try flat(bright, bw, bh) else { return }
        #expect(abs(at(out, bar: 2) - hi) < 0.006)
    }
}

// MARK: Cost

@Suite struct TrailsCostTests {
    /// GPU ms per 1080p and 4K frame (420v source, whole command buffer) for Trails. NSLog, stdout and
    /// $TMPDIR/sqtrailscost.txt.
    @Test func measureCost() throws {
        guard let (dev, q, comp) = setup() else { return }
        var lines: [String] = []
        for (w, h, name) in [(1920, 1080, "1080p"), (3840, 2160, "4K")] {
            let frames = (0..<25).map { f in make420(w, h) { x, y in UInt8(((x &+ f &* 13) ^ y) & 127 + 60) } }
            let t = target(dev, w, h)
            func gpuMs(_ nodes: [RenderNode]) throws -> Double {
                var times: [Double] = []
                for i in 0..<12 {
                    let cb = try render(comp, q, nodes, w, h, into: t)
                    if i >= 2 { times.append((cb.gpuEndTime - cb.gpuStartTime) * 1000) }
                }
                return times.sorted()[times.count / 2]
            }
            let before = Array(frames[0..<24].reversed())
            lines.append("\(name) plain \(String(format: "%.2f", try gpuMs([frameLayer(frames[24], w, h)]))) ms")
            for (n, tr) in [("trails default (4 echoes)", TemporalFilter.Trails(count: 4, spacing: 2, decay: 0.4, blend: .screen)),
                            ("trails 8 echoes", .init(count: 8, spacing: 3, decay: 0.2, blend: .add))] {
                let tf = TemporalFrames(filter: TemporalFilter(trails: tr), before: before)
                lines.append("\(name) \(n) \(String(format: "%.2f", try gpuMs([frameLayer(frames[24], w, h, tf)]))) ms")
            }
        }
        let text = lines.joined(separator: "\n")
        NSLog("SQTRAILSCOST %@", text)
        print("SQTRAILSCOST\n\(text)")
        try? (text + "\n").write(toFile: NSTemporaryDirectory() + "sqtrailscost.txt", atomically: true, encoding: .utf8)
    }
}
#endif
