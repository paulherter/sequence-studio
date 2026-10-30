import Foundation
import Testing
@testable import SQCore

// Masks and drawn graphics on a non-square sequence: points are placed in display space (1440x1080 at 4:3 is 1920x1080),
// and mapping them to the frame and back returns the same point.
struct PixelShapeMappingTests {
    private var format: SequenceFormat {
        var f = SequenceFormat(width: 1440, height: 1080, frameDuration: Time(1, 30))
        f.pixelAspect = PixelAspect(4, 3)!
        return f
    }

    @Test func maskVertexRoundTripsThroughDisplayFramePixels() {
        let frame = Vec2(Double(format.displayWidth), Double(format.height))
        let path = MaskPath.rectangle(Vec2(0.25, 0.25), Vec2(0.75, 0.75))
        for (i, v) in path.vertices.enumerated() {
            let px = Vec2(v.point.x * frame.x, v.point.y * frame.y)            // display px
            #expect(path.vertexIndex(near: px, frame: frame, radius: 1) == i)
            let back = Vec2(px.x / frame.x, px.y / frame.y)
            #expect(abs(back.x - v.point.x) < 1e-12 && abs(back.y - v.point.y) < 1e-12)
        }
        #expect(path.vertexIndex(near: Vec2(960, 540), frame: frame, radius: 5) == nil)
    }

    @Test func drawnPathReproducesItsDisplayPoints() throws {
        // Points reach past half the stored width (720) but stay inside the display half width (960).
        let pts = [Vec2(-900, -400), Vec2(850, -300), Vec2(900, 450), Vec2(-800, 380)]
        let layer = GraphicsLayer.path(canvasPoints: pts, closed: true, color: .white, strokeWidth: 1)
        guard case .path(let unit, _) = layer.content else { Issue.record("not a path"); return }
        let e = try #require(layer.shapeEffect)
        let w = try #require(e.parameters[ClipEffect.shapeWidthKey]).value, h = try #require(e.parameters[ClipEffect.shapeHeightKey]).value
        let c = layer.animation.position.value
        for (p, u) in zip(pts, unit) {
            #expect(abs(c.x + (u.x - 0.5) * w - p.x) < 1e-9 && abs(c.y + (u.y - 0.5) * h - p.y) < 1e-9)
        }
        #expect(Double(format.displayWidth) / 2 > pts.map(\.x).map(abs).max()!)
    }
}
