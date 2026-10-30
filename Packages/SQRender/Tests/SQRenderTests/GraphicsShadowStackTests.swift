#if canImport(Metal)
import CoreVideo
import Foundation
import Metal
import SQCore
import Testing
@testable import SQRender

/// A Drop Shadow on a graphic with several layers lies under all of them (Premiere: the effect acts on the graphic as a
/// whole). Split into one clip per layer, the upper layer's shadow darkened the lower layer: that is what imported
/// two-text graphics did before they became one Graphics clip (TCL C8L).
@Suite struct GraphicsShadowStackTests {
    let w = 200, h = 100

    func shadow() -> ClipEffect {
        var e = ClipEffect.make(kind: ClipEffect.dropShadowKind)!
        e.parameters[ClipEffect.shadowOpacityKey] = AnimatedProperty(100)
        e.parameters[ClipEffect.shadowDistanceKey] = AnimatedProperty(0)
        e.parameters[ClipEffect.shadowSoftnessKey] = AnimatedProperty(50)      // sigma 10 px
        return e
    }

    /// A white 40 x 40 square at `x` (offset from the canvas center).
    func square(_ x: Double) -> GraphicsLayer {
        var l = GraphicsLayer.shape(.rectangle, canvasWidth: w, canvasHeight: h)
        l.setShapeSize(width: 40, height: 40)
        l.effects[0].colors[ClipEffect.shapeFillColorKey] = AnimatedProperty(EffectColor(red: 1, green: 1, blue: 1))
        l.animation.position = AnimatedProperty(Vec2(x, 0))
        return l
    }

    func graphicsClip(_ layers: [GraphicsLayer], effects: [ClipEffect]) -> Clip {
        let id = UUID()
        var c = Clip(id: id, name: "Graphic", media: id, kind: .video, source: TimeRange(start: .zero, duration: Time(1, 1)),
                     start: .zero, generator: .graphicsClip, effects: effects)
        c.graphics = GraphicsDocument(layers: layers)
        return c
    }

    /// Red channel at canvas pixel (x, y).
    func render(_ tracks: [Track]) throws -> ((Int, Int) -> Float)? {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue(), let comp = try? Compositor(device: dev) else { return nil }
        let f = SequenceFormat(width: w, height: h, frameDuration: Time(1, 25))
        let tl = Timeline(name: "T", format: f, tracks: tracks)
        let reqs = tl.videoLayers(at: Time(1, 2))
        let nodes = RenderNode.tree(requests: reqs, layers: reqs.map { ShapeRenderer.layer(for: $0).applying($0) })
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
        let t = dev.makeTexture(descriptor: d)!
        let cb = q.makeCommandBuffer()!
        try comp.render(nodes: nodes, format: f, into: t, commandBuffer: cb)
        cb.commit(); cb.waitUntilCompleted()
        #expect(cb.error == nil)
        return { x, y in
            var px = [Float16](repeating: 0, count: 4)
            t.getBytes(&px, bytesPerRow: 8, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
            return Float(px[0])
        }
    }

    @Test func shadowOfTheGraphicLiesUnderEveryLayer() throws {
        // Squares at -22 and +22: 4 px apart. Probe the lower (left) square 6 px from the upper one's edge.
        let one = graphicsClip([square(-22), square(22)], effects: [shadow()])
        guard let px = try render([Track(kind: .video, clips: [one])]) else { return }
        #expect(px(96, 50) > 0.97, "lower layer stays white: \(px(96, 50))")
        #expect(px(102 + 3, 50) > 0.97, "upper layer stays white")

        // The old import: one clip per layer, each with the shadow, the upper one on its own track above.
        let lower = graphicsClip([square(-22)], effects: [shadow()]), upper = graphicsClip([square(22)], effects: [shadow()])
        guard let split = try render([Track(kind: .video, clips: [lower]), Track(kind: .video, clips: [upper])]) else { return }
        #expect(split(96, 50) < 0.9, "split: the upper shadow darkens the lower layer: \(split(96, 50))")
    }
}
#endif
