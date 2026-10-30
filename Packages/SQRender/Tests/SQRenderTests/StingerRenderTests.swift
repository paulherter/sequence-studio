#if canImport(Metal)
import CoreVideo
import Foundation
import Metal
import SQCore
import Testing
@testable import SQRender

// N6b Stinger: the third decoded layer of a cut transition. An alpha (ProRes 4444 -> 'y416') stinger composites over
// whichever picture is on screen (A before the edit, B from it); where it is transparent the cut shows through.

private let fd = Time(1, 30)
private func f(_ n: Int64) -> Time { fd * n }

private func bgra(_ w: Int, _ h: Int, _ c: (UInt8, UInt8, UInt8, UInt8)) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
    CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
    let b = pb!
    CVPixelBufferLockBaseAddress(b, [])
    let base = CVPixelBufferGetBaseAddress(b)!, stride = CVPixelBufferGetBytesPerRow(b)
    for y in 0..<h { for x in 0..<w {
        let p = (base + y * stride + x * 4).assumingMemoryBound(to: UInt8.self)
        p[0] = c.0; p[1] = c.1; p[2] = c.2; p[3] = c.3
    } }
    CVPixelBufferUnlockBaseAddress(b, [])
    return b
}

/// 'y416' stinger: left half opaque white (Y' 235), right half fully transparent (straight alpha).
private func stingerFrame(_ w: Int, _ h: Int) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
    precondition(CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_4444AYpCbCr16, attrs as CFDictionary, &pb) == kCVReturnSuccess)
    let b = pb!
    CVPixelBufferLockBaseAddress(b, [])
    let base = CVPixelBufferGetBaseAddress(b)!, stride = CVPixelBufferGetBytesPerRow(b)
    for y in 0..<h {
        let row = (base + y * stride).assumingMemoryBound(to: UInt16.self)
        for x in 0..<w {
            let opaque = x < w / 2
            row[x * 4] = opaque ? 65535 : 0
            row[x * 4 + 1] = UInt16(opaque ? 235 << 8 : 16 << 8); row[x * 4 + 2] = 128 << 8; row[x * 4 + 3] = 128 << 8
        }
    }
    CVPixelBufferUnlockBaseAddress(b, [])
    CVBufferSetAttachment(b, kCVImageBufferAlphaChannelModeKey, kCVImageBufferAlphaChannelMode_StraightAlpha, .shouldPropagate)
    return b
}

private func info(_ w: Int, _ h: Int, codec: String) -> VideoTrackInfo {
    VideoTrackInfo(width: w, height: h, codec: codec, bitDepth: codec == "ap4h" ? 12 : 8, chroma: codec == "ap4h" ? "4:4:4" : "4:2:0",
                   nominalFrameDuration: fd, isVariableFrameRate: false, matrix: nil)
}

/// A (red) | B (green), cut at frame 60, a 30 frame stinger with its cut in the middle.
private struct Scene {
    let a: Clip, b: Clip, stinger = UUID()
    var timeline: Timeline

    init(width: Int, height: Int) throws {
        a = Clip(name: "A", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: f(60)), start: .zero, mediaDuration: f(60))
        b = Clip(name: "B", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: f(60)), start: f(60), mediaDuration: f(60))
        var v = Track(kind: .video)
        try v.overwrite(a); try v.overwrite(b)
        timeline = Timeline(name: "S", format: SequenceFormat(width: width, height: height, frameDuration: fd), tracks: [v])
        let id = try timeline.addTransition(kind: .stinger, track: v.id, outgoing: a.id, incoming: b.id, duration: f(30))
        try timeline.setStinger(id, TransitionStinger(media: stinger, cutFraction: 0.5))
    }

    /// What the decoders would hand over, per media.
    func nodes(at t: Time, frames: [UUID: (CVPixelBuffer, VideoTrackInfo)]) -> [RenderNode] {
        let reqs = timeline.videoLayers(at: t)
        let layers = reqs.map { r -> RenderLayer in
            let (pb, i) = frames[r.media]!
            return RenderLayer(content: .frame(pb, colorHint: i), transform: r.transform).applying(r)
        }
        return RenderNode.tree(requests: reqs, layers: layers)
    }
}

private func render(_ nodes: [RenderNode], _ format: SequenceFormat, _ dev: MTLDevice, _ q: MTLCommandQueue, _ comp: Compositor) throws -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: format.width, height: format.height, mipmapped: false)
    d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
    let t = dev.makeTexture(descriptor: d)!
    let cb = q.makeCommandBuffer()!
    try comp.render(nodes: nodes, format: format, into: t, commandBuffer: cb)
    cb.commit(); cb.waitUntilCompleted()
    #expect(cb.error == nil)
    return t
}

private func pixel(_ t: MTLTexture, _ x: Int, _ y: Int) -> [Double] {
    var px = [Float16](repeating: 0, count: 4)
    t.getBytes(&px, bytesPerRow: 8, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
    return px.map { Double($0) }
}

private func near(_ a: [Double], _ e: [Double], _ note: String) {
    for i in 0..<3 { #expect(abs(a[i] - e[i]) <= 0.01, "\(note) ch\(i): got \(a[i]) want \(e[i])") }
}

@Test func alphaStingerCompositesOverTheCut() throws {
    guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue(), let comp = try? Compositor(device: dev) else { return }
    let W = 32, H = 8
    let s = try Scene(width: W, height: H)
    let frames: [UUID: (CVPixelBuffer, VideoTrackInfo)] = [
        s.a.media: (bgra(W, H, (0, 0, 255, 255)), info(W, H, codec: "avc1")),
        s.b.media: (bgra(W, H, (0, 255, 0, 255)), info(W, H, codec: "avc1")),
        s.stinger: (stingerFrame(W, H), info(W, H, codec: "ap4h")),
    ]
    let fmt = s.timeline.format
    // Before the edit: stinger (white, left half) over A (red); after: over B (green).
    let before = try render(s.nodes(at: f(50), frames: frames), fmt, dev, q, comp)
    near(pixel(before, 4, 4), [1, 1, 1], "before: stinger")
    near(pixel(before, 28, 4), [1, 0, 0], "before: A through the transparent half")
    let after = try render(s.nodes(at: f(65), frames: frames), fmt, dev, q, comp)
    near(pixel(after, 4, 4), [1, 1, 1], "after: stinger")
    near(pixel(after, 28, 4), [0, 1, 0], "after: B through the transparent half")
    // Outside the span: the plain clip, no stinger.
    let outside = try render(s.nodes(at: f(80), frames: frames), fmt, dev, q, comp)
    near(pixel(outside, 4, 4), [0, 1, 0], "outside: B only")
}

/// Measurement (printed) + budget: one 1080p stinger frame (opaque HD clip + 'y416' alpha stinger) on the GPU.
@Test func stingerFrameCostAt1080p() throws {
    guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue(), let comp = try? Compositor(device: dev) else { return }
    let W = 1920, H = 1080
    let s = try Scene(width: W, height: H)
    let frames: [UUID: (CVPixelBuffer, VideoTrackInfo)] = [
        s.a.media: (bgra(W, H, (0, 0, 255, 255)), info(W, H, codec: "avc1")),
        s.b.media: (bgra(W, H, (0, 255, 0, 255)), info(W, H, codec: "avc1")),
        s.stinger: (stingerFrame(W, H), info(W, H, codec: "ap4h")),
    ]
    let fmt = s.timeline.format
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: W, height: H, mipmapped: false)
    d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
    let target = dev.makeTexture(descriptor: d)!
    var ms: [Double] = []
    let clock = ContinuousClock()
    for i in 0..<70 {
        let t = f(45 + Int64(i % 30))
        let start = clock.now
        let nodes = s.nodes(at: t, frames: frames)
        let cb = q.makeCommandBuffer()!
        try comp.render(nodes: nodes, format: fmt, into: target, commandBuffer: cb)
        cb.commit(); cb.waitUntilCompleted()
        let e = clock.now - start
        if i >= 10 { ms.append(Double(e.components.attoseconds) / 1e15 + Double(e.components.seconds) * 1e3) }
    }
    ms.sort()
    let p95 = ms[Int(Double(ms.count - 1) * 0.95)]
    NSLog("stinger frame 1080p (evaluate + composite + GPU wait): median %.2f ms, p95 %.2f ms", ms[ms.count / 2], p95)
    #expect(p95 < 8)   // measured 1.75 ms on the M-series dev Mac (Oct 2026)
}
#endif
