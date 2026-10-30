import Foundation
import Testing
import SQDrawKit

@Suite("Canvas")
struct CanvasTests {
    private func red(_ img: RGBAImage, _ x: Int, _ y: Int) -> UInt8 { img.pixels[(y * img.width + x) * 4] }

    @Test func segmentDrawsAntialiasedRoundCappedLine() {
        var l = DrawList(width: 20, height: 20)
        l.segment(2, 10, 18, 10, width: 2, .white)
        let img = SoftwareRenderer.render(l, width: 20, height: 20, clear: .black, atlas: nil)
        #expect(red(img, 10, 10) == 255)     // on the line
        #expect(red(img, 10, 5) == 0)        // far off
        #expect(red(img, 1, 10) > 0)         // round cap past the end point
        var d = DrawList(width: 20, height: 20)
        d.segment(0, 0, 19, 19, width: 1, .white)
        let di = SoftwareRenderer.render(d, width: 20, height: 20, clear: .black, atlas: nil)
        #expect(red(di, 10, 10) > 200)
        #expect(red(di, 15, 5) == 0)
    }

    @Test func previewFaceBakesIntoTheSamePageAndMeasuresWithItsOwnMetrics() throws {
        let atlas = try #require(GlyphAtlas())
        var c = Canvas(width: 200, height: 40, atlas: atlas, scale: 1)
        let face = c.face(family: "Bebas Neue")
        #expect(face == 1 && atlas.faces.count == 2)
        #expect(c.face(family: "Bebas Neue") == face)            // the same file is not added twice
        #expect(c.face(family: "No Such Family") == 0 && c.face(family: "Inter") == 0)   // the UI face
        // A condensed display face sets the word narrower than the UI face.
        let ui = c.size(of: "Say it", fontSize: 20).width, own = c.size(of: "Say it", fontSize: 20, face: face).width
        #expect(own > 0 && own != ui)
        let before = c.list.quads.count
        c.draw("Say", at: CGPoint(x: 2, y: 2), fontSize: 20, .white, face: face)
        #expect(c.list.quads.count == before + 3)
        #expect(Canvas(width: 1, height: 1, atlas: nil, scale: 1).face(family: "Bebas Neue") == 0)
    }

    @Test func canvasScalesPointsAndTranslates() {
        var c = Canvas(width: 40, height: 40, atlas: nil, scale: 2)
        c.translateBy(x: 5, y: 5)
        c.fill(CGRect(x: 0, y: 0, width: 4, height: 4), .white)
        let img = SoftwareRenderer.render(c.list, width: 40, height: 40, clear: .black, atlas: nil)
        #expect(red(img, 10, 10) == 255)     // (5,5) pt at scale 2
        #expect(red(img, 17, 17) == 255)
        #expect(red(img, 18, 18) == 0)
        #expect(red(img, 9, 9) == 0)
    }

    @Test func restoreGStatePopsClipsAndTranslation() {
        var c = Canvas(width: 10, height: 2, atlas: nil, scale: 1)
        c.saveGState()
        c.translateBy(x: 1, y: 0)
        c.clip(to: CGRect(x: 0, y: 0, width: 2, height: 2))   // device 1..<3
        c.fill(CGRect(x: -1, y: 0, width: 10, height: 2), .white)
        c.restoreGState()
        c.fill(CGRect(x: 8, y: 0, width: 1, height: 2), .white)  // no translation, no clip
        let img = SoftwareRenderer.render(c.list, width: 10, height: 2, clear: .black, atlas: nil)
        #expect(red(img, 0, 0) == 0)
        #expect(red(img, 1, 0) == 255)
        #expect(red(img, 2, 0) == 255)
        #expect(red(img, 3, 0) == 0)
        #expect(red(img, 8, 0) == 255)
    }

    @Test func strokeIsCenteredOnTheEdge() {
        var c = Canvas(width: 20, height: 20, atlas: nil, scale: 1)
        c.stroke(roundedRect: CGRect(x: 4, y: 4, width: 12, height: 12), radius: 0, width: 2, .white)
        let img = SoftwareRenderer.render(c.list, width: 20, height: 20, clear: .black, atlas: nil)
        #expect(red(img, 3, 10) == 255)      // half outside
        #expect(red(img, 4, 10) == 255)      // half inside
        #expect(red(img, 5, 10) == 0)
        #expect(red(img, 10, 10) == 0)
    }

    @Test func wrapBreaksAtWords() throws {
        let atlas = try #require(GlyphAtlas())
        let c = Canvas(width: 10, height: 10, atlas: atlas, scale: 1)
        let one = c.size(of: "Restore", fontSize: 11).width
        let lines = c.wrap("Restore the autosave version", width: one + 2, fontSize: 11)
        #expect(lines.first == "Restore")
        #expect(lines.count >= 3)
        #expect(c.wrap("a\nb", width: 100, fontSize: 11) == ["a", "b"])
    }
}
