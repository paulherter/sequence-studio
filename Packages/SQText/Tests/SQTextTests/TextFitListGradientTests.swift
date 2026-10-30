#if canImport(CoreText)
import Testing
import CoreVideo
import Foundation
import CoreGraphics
import SQCore
@testable import SQText

/// Auto-fit (shrink to box), bullet and numbered lists, per-paragraph looks and the gradient fill.
@Suite struct TextFitListGradientTests {
    let base = TextStyle(fontName: "Helvetica", size: 60, alignment: .left)

    @Test func newFieldsLeaveOldStylesByteIdentical() throws {
        let data = try JSONEncoder().encode(base)
        let s = String(decoding: data, as: UTF8.self)
        for key in ["autoFit", "list", "gradient", "lineStyles"] { #expect(!s.contains(key)) }
        #expect(try JSONDecoder().decode(TextStyle.self, from: data) == base)
        var all = base
        all.autoFit = true; all.list = .numbered
        all.gradient = TextGradient(start: .white, end: .black, angle: 45)
        all.lineStyles = [TextLineStyle(from: base)]
        #expect(try JSONDecoder().decode(TextStyle.self, from: JSONEncoder().encode(all)) == all)
    }

    @Test func autoFitShrinksTextToTheBox() {
        var s = base
        let text = "Shrink this long title into a small box please"
        let plain = TextLayout.layout(text: text, style: s, maxWidth: 300, boxHeight: 120)
        #expect(plain.lines.map(\.height).reduce(0, +) > 120)
        s.autoFit = true
        let fitted = TextLayout.layout(text: text, style: s, maxWidth: 300, boxHeight: 120)
        let textHeight = (fitted.lines.last!.y + fitted.lines.last!.height) - fitted.lines[0].y
        #expect(textHeight <= 120 + 0.5)
        #expect(fitted.lines.allSatisfy { $0.width <= 300 + 0.5 })
        #expect(fitted.lines[0].height < plain.lines[0].height)
    }

    @Test func autoFitNeverGrowsAndIgnoresPointText() {
        var s = base
        s.autoFit = true
        let small = TextLayout.layout(text: "Hi", style: s, maxWidth: 600, boxHeight: 400)
        var off = base; off.autoFit = nil
        #expect(small.lines == TextLayout.layout(text: "Hi", style: off, maxWidth: 600, boxHeight: 400).lines)
        #expect(TextLayout.layout(text: "Hi there", style: s, maxWidth: nil).lines
                == TextLayout.layout(text: "Hi there", style: off, maxWidth: nil).lines)
    }

    @Test func bulletsAndNumbersPrefixNonEmptyParagraphs() {
        var s = base
        s.list = .bullet
        #expect(TextLayout.layout(text: "One\n\nTwo", style: s, maxWidth: nil).lines.map(\.text) == ["\u{2022} One", "", "\u{2022} Two"])
        s.list = .numbered
        let r = TextLayout.layout(text: "One\n\nTwo", style: s, maxWidth: nil)
        #expect(r.lines.map(\.text) == ["1. One", "", "2. Two"])
        #expect(r.lines.map(\.content) == ["One", "", "Two"])
        #expect(r.lines[0].location == 0 && r.lines[2].location == 5)
        #expect(r.displayText == "One\n\nTwo")
    }

    @Test func plainTextLayoutIsUnchangedByTheNewFields() {
        let a = TextLayout.layout(text: "A\nB longer", style: base, maxWidth: 400)
        #expect(a.lines.map(\.text) == ["A", "B longer"])
        #expect(a.lines.allSatisfy { $0.markerLength == 0 })
    }

    @Test func perParagraphLooksPickTheirOwnSize() {
        var s = base
        var big = TextLineStyle(from: base); big.size = 120
        s.lineStyles = [TextLineStyle(from: base), big]
        let r = TextLayout.layout(text: "a\nb\nc", style: s, maxWidth: nil)
        #expect(r.lines[1].height > r.lines[0].height * 1.5)
        // Paragraphs past the list use the clip style again.
        #expect(abs(r.lines[2].height - r.lines[0].height) < 0.01)
        #expect(s.lineStyleCount == 3)
    }

    @Test func gradientAxisSpansTheRect() {
        let g = TextGradient(start: .white, end: .black, angle: 0)
        let a = g.axis(in: TextRect(x: 10, y: 0, width: 100, height: 50))
        #expect(a.start.x == 10 && a.end.x == 110 && a.start.y == 25)
    }

    @Test func gradientFillStaysInsideTheGlyphs() throws {
        var s = base
        s.size = 80
        s.gradient = TextGradient(start: RGBAColor(red: 1, green: 0, blue: 0), end: RGBAColor(red: 0, green: 0, blue: 1))
        let raster = try #require(try TextRenderer.render(text: "Hello", style: s, maxWidth: nil))
        let pb = raster.linearBuffer
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let row = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: Float16.self)
        var covered = 0
        for y in 0..<raster.pixelHeight {
            let r = (CVPixelBufferGetBaseAddress(pb)! + y * CVPixelBufferGetBytesPerRow(pb)).assumingMemoryBound(to: Float16.self)
            for x in 0..<raster.pixelWidth where Float(r[x * 4 + 3]) > 0.5 { covered += 1 }
        }
        #expect(Float(row[3]) == 0, "the top-left corner is outside every glyph")
        #expect(covered < raster.pixelWidth * raster.pixelHeight / 2)
    }

    @Test func gradientFillChangesColorAcrossTheGlyphs() throws {
        var s = base
        s.fontName = "Helvetica-Bold"; s.size = 120
        s.gradient = TextGradient(start: RGBAColor(red: 1, green: 0, blue: 0), end: RGBAColor(red: 0, green: 0, blue: 1), angle: 0)
        let raster = try #require(try TextRenderer.render(text: "IIIIIIII", style: s, maxWidth: nil))
        let img = raster.image
        let data = try #require(img.dataProvider?.data as Data?)
        let w = img.width, h = img.height, bpr = img.bytesPerRow
        func firstInk(fromLeft: Bool) -> (r: Int, b: Int) {
            for xi in 0..<w {
                let x = fromLeft ? xi : w - 1 - xi
                for y in 0..<h {
                    let o = y * bpr + x * 4
                    if data[o + 3] > 250 { return (Int(data[o]), Int(data[o + 2])) }
                }
            }
            return (0, 0)
        }
        let left = firstInk(fromLeft: true), right = firstInk(fromLeft: false)
        #expect(left.r > 200 && left.b < 60)
        #expect(right.b > 200 && right.r < 60)
    }
}
#endif
