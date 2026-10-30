#if canImport(Metal)
import CoreVideo
import Foundation
import Metal
import SQCore
import Testing
@testable import SQRender

// Picture masks (and effect mask scopes) on a tilted layer: the matte is fixed to the screen, so a pixel's mask value
// is read at the pixel's own place. Masked == unmasked x matte coverage, pixel by pixel, on a tilted layer.
@Suite struct PerspectiveTiltMaskTests {
    let w = 64, h = 36
    let v1 = UUID(), v2 = UUID()

    private func render(_ nodes: [RenderNode]) throws -> [Float]? {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue(), let comp = try? Compositor(device: dev) else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
        let t = dev.makeTexture(descriptor: d)!
        let cb = q.makeCommandBuffer()!
        try comp.render(nodes: nodes, format: SequenceFormat(width: w, height: h, frameDuration: Time(1, 25)), into: t, commandBuffer: cb)
        cb.commit(); cb.waitUntilCompleted()
        var px = [Float16](repeating: 0, count: w * h * 4)
        t.getBytes(&px, bytesPerRow: w * 8, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        return px.map { Float($0) }
    }

    private func nodes(masked: Bool, _ t: ClipTransform) -> [RenderNode] {
        var mask = MaskShape(polygon: [], opacity: 1, inverted: false, mode: .add, source: .picture)
        mask.pictureTrack = v2
        let fx = ClipEffects(segments: [], masks: masked ? [mask] : [])
        var consumer = RenderLayer(content: .solid(red: 0.8, green: 0.5, blue: 0.3), transform: t)
        consumer.effects = fx
        let r1 = LayerRequest(clip: UUID(), media: UUID(), track: v1, sourceTime: .zero, groups: [], effects: fx)
        var out: [(LayerRequest, RenderLayer)] = [(r1, consumer)]
        if masked {
            var sq = ClipTransform.identity
            sq.scale = Vec2(0.5, 0.5)
            var r2 = LayerRequest(clip: UUID(), media: UUID(), track: v2, sourceTime: .zero, groups: [])
            r2.matteFor = v2
            r2.matteDepth = 0
            out.append((r2, RenderLayer(content: .solid(red: 1, green: 1, blue: 1), transform: sq)))
        }
        return RenderNode.tree(requests: out.map(\.0), layers: out.map(\.1))
    }

    @Test func pictureMaskOnATiltedLayerReadsTheMatteAtTheScreenPixel() throws {
        var t = ClipTransform.identity
        t.scale = Vec2(0.9, 0.9)
        t.position = Vec2(2, 1)
        t.rotation = 8
        t.tiltY = 50
        t.tiltX = 20
        guard let plain = try render(nodes(masked: false, t)), let masked = try render(nodes(masked: true, t)) else { return }
        var checked = 0, worst: Float = 0
        for y in 0..<h {
            for x in 0..<w {
                let inSquare = x >= 17 && x < 47 && y >= 10 && y < 26     // inside the matte's edge, away from its AA
                let outSquare = x < 15 || x >= 49 || y < 8 || y >= 28
                guard inSquare || outSquare else { continue }
                let i = (y * w + x) * 4
                for c in 0..<3 {
                    let want = plain[i + c] * (inSquare ? 1 : 0)
                    worst = max(worst, abs(masked[i + c] - want))
                }
                checked += 1
            }
        }
        #expect(checked > 1000)
        #expect(worst < 0.01, "worst \(worst)")
        // The tilted layer is not the whole canvas, the matte square is on screen: some of both exist.
        #expect(plain.indices.contains { $0 % 4 == 1 && plain[$0] > 0.1 })
    }

    /// Vertical stripes as a linear premultiplied layer (the stripes survive a short blur, a long one smears them).
    private func stripes(_ lw: Int, _ lh: Int) -> CVPixelBuffer {
        let attrs = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as [CFString: Any]
        var pb: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil, lw, lh, kCVPixelFormatType_64RGBAHalf, attrs as CFDictionary, &pb) == kCVReturnSuccess)
        let b = pb!
        CVPixelBufferLockBaseAddress(b, [])
        defer { CVPixelBufferUnlockBaseAddress(b, []) }
        let base = CVPixelBufferGetBaseAddress(b)!, stride = CVPixelBufferGetBytesPerRow(b)
        for y in 0..<lh {
            let row = (base + y * stride).assumingMemoryBound(to: Float16.self)
            for x in 0..<lw {
                let v: Float = (x / 3) % 2 == 0 ? 0.9 : 0.1
                row[x * 4] = Float16(v); row[x * 4 + 1] = Float16(v); row[x * 4 + 2] = Float16(v); row[x * 4 + 3] = 1
            }
        }
        return b
    }

    /// A tilted striped layer with a 40 px blur whose scope is a Picture mask (matte = the left quarter of the screen,
    /// or none). The blur pads the draw, so the final draw's camera distance differs from the unpadded one.
    private func scoped(matte: Bool) -> [RenderNode] {
        var t = ClipTransform.identity
        t.tiltY = 50
        t.tiltX = 10
        var mask = MaskShape(polygon: [], opacity: 1, inverted: false, mode: .add, source: .picture)
        mask.pictureTrack = v2
        var segs = EffectSegment()
        segs.blurAfter = 40
        segs.scope = [mask]
        let fx = ClipEffects(segments: [segs, EffectSegment()], masks: [])
        var consumer = RenderLayer(content: .linearPremultiplied(stripes(w, h), width: Double(w), height: Double(h)), transform: t)
        consumer.effects = fx
        var out: [(LayerRequest, RenderLayer)] = [
            (LayerRequest(clip: UUID(), media: UUID(), track: v1, sourceTime: .zero, groups: [], effects: fx), consumer)]
        if matte {
            var q = ClipTransform.identity
            q.scale = Vec2(0.5, 1)
            q.position = Vec2(-Double(w) / 4, 0)
            var r2 = LayerRequest(clip: UUID(), media: UUID(), track: v2, sourceTime: .zero, groups: [])
            r2.matteFor = v2
            r2.matteDepth = 0
            out.append((r2, RenderLayer(content: .solid(red: 1, green: 1, blue: 1), transform: q)))
        }
        return RenderNode.tree(requests: out.map(\.0), layers: out.map(\.1))
    }

    @Test func effectScopeOnAPaddedTiltedLayerUsesTheFinalDrawsCameraDistance() throws {
        // Matte = left quarter. Inside it the picture is the blurred one (as with a full matte), outside the sharp one
        // (as with no matte); the boundary is fixed to the screen at x = w / 4.
        var t = ClipTransform.identity
        t.tiltY = 50; t.tiltX = 10
        var full = MaskShape(polygon: [], opacity: 1, inverted: false, mode: .add, source: .picture)
        full.pictureTrack = v2
        guard let none = try render(scoped(matte: false)), let quarter = try render(scoped(matte: true)) else { return }
        // Reference "all blurred": the same chain, scope off (an empty scope), same padded geometry.
        var segs = EffectSegment(); segs.blurAfter = 40
        let fx = ClipEffects(segments: [segs, EffectSegment()], masks: [])
        var layer = RenderLayer(content: .linearPremultiplied(stripes(w, h), width: Double(w), height: Double(h)), transform: t)
        layer.effects = fx
        let r = LayerRequest(clip: UUID(), media: UUID(), track: v1, sourceTime: .zero, groups: [], effects: fx)
        guard let blurred = try render(RenderNode.tree(requests: [r], layers: [layer])) else { return }
        var worstIn: Float = 0, worstOut: Float = 0, n = 0
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                if y >= 4 && y < 27, x >= 13 && x < 24 { worstIn = max(worstIn, abs(quarter[i] - blurred[i])); n += 1 }
                if y >= 4 && y < 27, x >= 42 && x < 49 { worstOut = max(worstOut, abs(quarter[i] - none[i])) }
            }
        }
        #expect(n > 100)   // rows near the canvas edge are skipped: the pass-resolution mask fades there
        #expect(worstIn < 0.05, "inside \(worstIn)")
        #expect(worstOut < 0.05, "outside \(worstOut)")
    }
}
#endif
