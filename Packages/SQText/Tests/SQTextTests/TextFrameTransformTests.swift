import Testing
import Foundation
import SQCore
@testable import SQText

@Suite struct TextFrameTransformTests {
    @Test func foldsPlacementAndAnimation() throws {
        let style = TextStyle(fontName: "Helvetica-Bold", size: 100, color: .white)
        let ref = try TextGenerator.makeRef(template: TextTemplate(name: "t", text: "Hi", style: style), animations: nil)
        let canvas = SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30))
        let f = try #require(try TextGenerator.frame(ref: ref, localTime: .zero, clipDuration: Time(5, 1), canvas: canvas, scale: 1))
        var base = ClipTransform.identity
        base.position = Vec2(10, 20); base.scale = Vec2(2, 2); base.opacity = 0.5
        let t = f.layerTransform(base: base, canvas: canvas)
        #expect(abs(t.position.x - (10 + f.x + f.width / 2 - 960 + f.offsetX)) < 1e-9)
        #expect(abs(t.position.y - (20 + f.y + f.height / 2 - 540 + f.offsetY)) < 1e-9)
        #expect(t.scale == Vec2(2 * f.scale, 2 * f.scale))
        #expect(abs(t.opacity - 0.5 * f.opacity) < 1e-12)
    }
}
