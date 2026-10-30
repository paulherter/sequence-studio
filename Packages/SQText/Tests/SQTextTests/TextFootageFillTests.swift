#if canImport(CoreText)
import Testing
import Foundation
import SQCore
@testable import SQText

/// Footage fill: the glyphs take their look from the picture below. Style flag, old files, and the plain white raster.
@Suite struct TextFootageFillTests {
    let red = TextStyle(fontName: "Helvetica-Bold", size: 120, color: RGBAColor(red: 1, green: 0, blue: 0),
                        stroke: TextStroke(color: RGBAColor(red: 0, green: 0, blue: 1), width: 6))

    @Test func absentByDefaultAndOlderFilesDecodeAsNil() throws {
        #expect(red.footageFill == nil && red.drawn == red)
        let data = try JSONEncoder().encode(red)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["footageFill"] == nil)        // an unchanged style writes the same bytes as before
        var on = red; on.footageFill = .inverted
        #expect(try JSONDecoder().decode(TextStyle.self, from: JSONEncoder().encode(on)) == on)
    }

    @Test func drawnStyleIsAPlainWhiteGlyph() {
        var s = red
        s.background = TextBackground(color: .white, padding: .zero)
        s.footageFill = .stencil
        let d = s.drawn
        #expect(d.color == red.color && d.stroke == nil && d.shadow == nil && d.background == nil)
        #expect(d.fontName == s.fontName && d.size == s.size)
        s.footageFill = .inverted
        #expect(s.drawn.color == .white)
        var faded = red; faded.color = RGBAColor(red: 1, green: 0, blue: 0, alpha: 0); faded.footageFill = .stencil
        #expect(faded.drawn.color.alpha == 1)       // an "off" fill still makes the stencil
    }

    @Test func refReportsTheFill() throws {
        var s = red; s.footageFill = .stencil
        let on = try TextGenerator.makeRef(template: TextTemplate(name: "T", text: "Hi", style: s), animations: nil)
        let off = try TextGenerator.makeRef(template: TextTemplate(name: "T", text: "Hi", style: red), animations: nil)
        #expect(TextGenerator.footageFill(ref: on) == .stencil)
        #expect(TextGenerator.footageFill(ref: off) == nil)
    }

    @Test func rasterOfAFootageFillIgnoresColorAndStroke() throws {
        var a = red; a.footageFill = .stencil
        var b = TextStyle(fontName: red.fontName, size: red.size, color: red.color); b.footageFill = .stencil
        let ra = try #require(try TextRenderer.render(text: "Hi", style: a, maxWidth: nil))
        let rb = try #require(try TextRenderer.render(text: "Hi", style: b, maxWidth: nil))
        #expect(ra.pixelWidth == rb.pixelWidth && ra.pixelHeight == rb.pixelHeight)
        #expect(RasterProbe(ra.image).data == RasterProbe(rb.image).data)
    }

    @Test func karaokeHighlightFollowsTheFill() {
        let h = TextHighlight(words: 0..<1, color: RGBAColor(red: 0, green: 1, blue: 0))
        var s = red
        #expect(s.drawn(highlight: h) == h)
        s.footageFill = .inverted
        #expect(s.drawn(highlight: h)?.color == .white)
        s.footageFill = .stencil
        #expect(s.drawn(highlight: h)?.color == h.color)
    }

    @Test func captionsNeverCarryAFootageFill() {
        var s = red; s.footageFill = .stencil
        let t = CaptionLayout.template(text: "Hi", style: s, canvasWidth: 1920, canvasHeight: 1080)
        #expect(t.style.footageFill == nil)
    }
}
#endif
