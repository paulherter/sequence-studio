#if canImport(Metal)
import CoreVideo
import Foundation
import Metal
import SQCore
import Testing
@testable import SQRender

// Graphics clip render path: shape and freeform-path layers through ShapeRenderer, RenderNode.tree and the Compositor.

private func target(_ d: MTLDevice, _ w: Int, _ h: Int) -> MTLTexture {
    let t = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
    t.usage = [.renderTarget, .shaderRead]; t.storageMode = .shared
    return d.makeTexture(descriptor: t)!
}

private func texel(_ t: MTLTexture, _ x: Int, _ y: Int) -> SIMD4<Float> {
    var px = [Float16](repeating: 0, count: 4)
    t.getBytes(&px, bytesPerRow: 8, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
    return SIMD4(Float(px[0]), Float(px[1]), Float(px[2]), Float(px[3]))
}

private func request(_ style: ShapeStyle, at pos: Vec2 = Vec2(0, 0)) -> LayerRequest {
    var r = LayerRequest(clip: UUID(), media: UUID(), track: UUID(), sourceTime: .zero,
                         transform: ClipTransform(position: pos), generator: GeneratorRef.shape(style.kind))
    r.shape = style
    return r
}

private func nodes(_ rs: [LayerRequest]) -> [RenderNode] {
    RenderNode.tree(requests: rs, layers: rs.map { ShapeRenderer.layer(for: $0).applying($0) })
}

@Suite struct GraphicsRenderTests {
    let red = EffectColor(red: 1, green: 0, blue: 0)
    let green = EffectColor(red: 0, green: 1, blue: 0)

    @Test func freeformPathAndRectangleRenderTheirColours() throws {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue(), let comp = try? Compositor(device: dev) else { return }
        let (w, h) = (200, 100)
        let f = SequenceFormat(width: w, height: h, frameDuration: Time(1, 25))
        // Closed triangle-ish square path 40 x 40 left of center, rectangle 40 x 40 right of center.
        var path = ShapeStyle(kind: .rectangle, width: 40, height: 40, fill: red)
        path.path = [Vec2(0, 0), Vec2(1, 0), Vec2(1, 1), Vec2(0, 1)]
        path.pathClosed = true
        let rect = ShapeStyle(kind: .rectangle, width: 40, height: 40, fill: green)
        let t = target(dev, w, h)
        let cb = q.makeCommandBuffer()!
        try comp.render(nodes: nodes([request(path, at: Vec2(-50, 0)), request(rect, at: Vec2(50, 0))]), format: f, into: t, commandBuffer: cb)
        cb.commit(); cb.waitUntilCompleted()
        #expect(cb.error == nil)
        let a = texel(t, 50, 50), b = texel(t, 150, 50), none = texel(t, 100, 50)
        #expect(a.x > 0.95 && a.y < 0.05 && a.w > 0.95, "path center is red")
        #expect(b.y > 0.95 && b.x < 0.05 && b.w > 0.95, "rectangle center is green")
        // The compositor target is opaque black where no layer covers: "transparent" shows the background.
        func black(_ p: SIMD4<Float>) -> Bool { p.x < 0.01 && p.y < 0.01 && p.z < 0.01 }
        #expect(black(none), "between the two layers stays background")
        #expect(black(texel(t, 50, 10)) && black(texel(t, 150, 90)), "outside the shapes stays background")
    }

    @Test func openPathIsOnlyStroked() throws {
        var s = ShapeStyle(kind: .rectangle, width: 60, height: 60, fill: red, stroke: green, strokeWidth: 6)
        s.path = [Vec2(0, 0.5), Vec2(1, 0.5)]
        s.pathClosed = false
        let b = try #require(ShapeRenderer.raster(s))
        #expect(CVPixelBufferGetWidth(b) >= 60)
        #expect(CVPixelBufferGetHeight(b) >= 60)
        #expect(ShapeRenderer.raster({ var p = s; p.path = [Vec2(0, 0)]; return p }()) == nil, "one point draws nothing")
    }

    /// 1080p tick of a graphics clip with 8 layers: layer build, tree and GPU composite. Best p95 of three rounds.
    @Test func eightLayerTickAt1080pStaysUnderBudget() throws {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue(), let comp = try? Compositor(device: dev) else { return }
        let f = SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 25))
        let t = target(dev, 1920, 1080)
        var reqs: [LayerRequest] = []
        for i in 0..<8 {
            var s = ShapeStyle(kind: .rectangle, width: 300, height: 200, cornerRadius: 20,
                               fill: EffectColor(red: Double(i) / 8, green: 0.5, blue: 1, alpha: 0.8), stroke: .white, strokeWidth: 4)
            if i % 2 == 1 { s.path = [Vec2(0, 0), Vec2(1, 0.2), Vec2(0.5, 1)]; s.pathClosed = true }
            reqs.append(request(s, at: Vec2(Double(i - 4) * 200, Double(i % 3) * 100 - 100)))
        }
        func tick(_ frame: Int) throws {
            var rs = reqs
            for i in rs.indices { rs[i].transform.position.x += Double(frame) }     // animation: a new transform per frame
            let cb = q.makeCommandBuffer()!
            try comp.render(nodes: nodes(rs), format: f, into: t, commandBuffer: cb)
            cb.commit(); cb.waitUntilCompleted()
        }
        try tick(0)                                                                // warm-up: raster cache, pipelines
        var best = Double.infinity
        for _ in 0..<3 {
            var ms: [Double] = []
            for frame in 1...45 {
                let t0 = DispatchTime.now().uptimeNanoseconds
                try tick(frame)
                ms.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
            }
            ms.sort()
            best = min(best, ms[Int(Double(ms.count) * 0.95) - 1])
        }
        #expect(best < 8, "p95 \(best) ms")
    }
}
#endif
