import Testing
@testable import SQDrawKit

@Suite("ImageQuad")
struct ImageQuadTests {
    @Test func imageQuadSamplesSlotAndTint() {
        var l = DrawList(width: 4, height: 2)
        l.image(DrawRect(x: 0, y: 0, w: 4, h: 2), slot: 2, tint: DrawColor(1, 0.5, 1, 1))
        #expect(l.quads[0].kind == DrawQuad.Kind.image.rawValue && l.quads[0].pad == 2)
        // 1x1 opaque white: every pixel is the tint.
        let img = RGBAImage(width: 1, height: 1, pixels: [255, 255, 255, 255])
        let out = SoftwareRenderer.render(l, width: 4, height: 2, clear: .black, atlas: nil, images: [2: img])
        #expect(Array(out.pixels[0..<3]) == [255, 128, 255])
    }

    @Test func transparentTexelsKeepBackgroundAndMissingSlotDrawsNothing() {
        var l = DrawList(width: 2, height: 1)
        l.image(DrawRect(x: 0, y: 0, w: 2, h: 1), slot: 0)
        let clear = RGBAImage(width: 1, height: 1, pixels: [255, 0, 0, 0])
        let a = SoftwareRenderer.render(l, width: 2, height: 1, clear: .black, atlas: nil, images: [0: clear])
        #expect(Array(a.pixels[0..<3]) == [0, 0, 0])
        let b = SoftwareRenderer.render(l, width: 2, height: 1, clear: .black, atlas: nil)
        #expect(Array(b.pixels[0..<3]) == [0, 0, 0])
        var bad = DrawList(width: 2, height: 1)
        bad.image(DrawRect(x: 0, y: 0, w: 2, h: 1), slot: 9)
        #expect(bad.quads.isEmpty)
    }
}
