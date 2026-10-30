#if canImport(CoreText)
import Testing
import CoreGraphics
import Foundation
import SQCore
@testable import SQText

/// N4: one text clip, two styles. The first paragraph keeps the clip style, every later paragraph uses `secondLine`.
@Suite struct TwoStyleTextTests {
    let red = RGBAColor(red: 1, green: 0, blue: 0)
    var small: TextStyle { TextStyle(fontName: "Helvetica-Bold", size: 40, color: .white, alignment: .center) }
    var twoStyle: TextStyle {
        var s = small
        s.secondLine = TextLineStyle(fontName: "Helvetica-Bold", size: 120, weight: .bold, color: red, italic: false)
        return s
    }

    // MARK: Model and file format

    @Test func oldStylesDecodeWithoutSecondLineAndEncodeWithoutTheKey() throws {
        let json = #"{"fontName":"Helvetica","size":48,"weight":400,"color":{"red":1,"green":1,"blue":1,"alpha":1},"alignment":"center","lineSpacing":0}"#
        let s = try JSONDecoder().decode(TextStyle.self, from: Data(json.utf8))
        #expect(s.secondLine == nil)
        let out = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
        #expect(!out.contains("secondLine"))
    }

    @Test func secondLineRoundTripsThroughTheGeneratorPayload() throws {
        let t = TextTemplate(name: "t", text: "PIXEL\n9 PRO", style: twoStyle)
        let (back, _) = try TextGenerator.decode(try TextGenerator.makeRef(template: t, animations: nil))
        #expect(back.style.secondLine == twoStyle.secondLine)
        #expect(back == t)
    }

    @Test func templateV4CarriesTheSecondLineAndV3StillReads() throws {
        let t = TextTemplate(name: "Title", text: "PIXEL\n9 PRO", style: twoStyle)
        let data = try t.encoded()
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["formatVersion"] as? Int == 4)
        #expect(try TextTemplate.decode(from: data) == t)
        let v3 = #"{"formatVersion":3,"name":"Old","text":"Hi","style":{"fontName":"Helvetica","size":48,"weight":400,"color":{"red":1,"green":1,"blue":1,"alpha":1},"alignment":"center","lineSpacing":0}}"#
        let old = try TextTemplate.decode(from: Data(v3.utf8))
        #expect(old.style.secondLine == nil && old.text == "Hi" && old.style.size == 48)
    }

    @Test func lineStyleAppliesTheOverrideAndKeepsTheBlockWideValues() {
        var s = twoStyle
        s.stroke = TextStroke(color: .black, width: 3)
        s.tracking = 2
        let first = s.lineStyle(0), second = s.lineStyle(1)
        #expect(first.size == 40 && first.color == .white)
        #expect(second.size == 120 && second.color == red && second.weight == .bold)
        #expect(second.stroke == s.stroke && second.tracking == 2 && second.alignment == .center)
        #expect(second.secondLine == nil && first.secondLine == nil)
        #expect(small.lineStyle(1) == small)                 // no override: every line is the clip style
    }

    @Test func secondLineFromStyleCopiesTheLookItStartsFrom() {
        let l = TextLineStyle(from: small)
        #expect(l.fontName == small.fontName && l.size == small.size && l.weight == small.weight)
        #expect(l.color == small.color && l.italic == small.italic)
    }

    // MARK: Layout

    @Test func firstParagraphKeepsTheClipStyleLaterParagraphsUseTheSecond() {
        let r = TextLayout.layout(text: "PIXEL\n9 PRO\nX", style: twoStyle, maxWidth: nil)
        #expect(r.lines.map(\.styleIndex) == [0, 1, 1])
        let plainSmall = TextLayout.layout(text: "PIXEL", style: small, maxWidth: nil)
        let plainBig = TextLayout.layout(text: "9 PRO", style: twoStyle.lineStyle(1), maxWidth: nil)
        #expect(abs(r.lines[0].height - plainSmall.lines[0].height) < 0.001)
        #expect(abs(r.lines[0].width - plainSmall.lines[0].width) < 0.001)
        #expect(abs(r.lines[1].height - plainBig.lines[0].height) < 0.001)
        #expect(abs(r.lines[1].width - plainBig.lines[0].width) < 0.001)
        #expect(r.lines[1].height > r.lines[0].height * 2)
        // The big line starts below the small one (its own leading follows the small line).
        #expect(r.lines[1].y >= r.lines[0].rect.maxY)
        // Centered over each other in one block.
        let cx0 = r.lines[0].x + r.lines[0].width / 2, cx1 = r.lines[1].x + r.lines[1].width / 2
        #expect(abs(cx0 - cx1) < 0.001)
    }

    @Test func wrappedLinesOfTheFirstParagraphStayInTheClipStyle() {
        let r = TextLayout.layout(text: "one two three four five six\nBIG", style: twoStyle, maxWidth: 120)
        let firstParagraph = r.lines.filter { $0.location < 28 }
        #expect(firstParagraph.count > 1)
        #expect(firstParagraph.allSatisfy { $0.styleIndex == 0 })
        #expect(r.lines.last?.styleIndex == 1)
    }

    @Test func withoutSecondLineEveryLineIsStyleZeroAndTheLayoutIsUnchanged() {
        let r = TextLayout.layout(text: "a\nb", style: small, maxWidth: nil)
        #expect(r.lines.allSatisfy { $0.styleIndex == 0 })
        var s = small
        s.secondLine = TextLineStyle(from: small)            // same look as the clip style: same layout
        let same = TextLayout.layout(text: "a\nb", style: s, maxWidth: nil)
        #expect(same.lines.map(\.rect) == r.lines.map(\.rect))
        #expect(same.bounds == r.bounds)
    }

    // MARK: Rendering

    func fill(at line: TextLine, in raster: TextRaster) -> (r: Int, g: Int, b: Int, a: Int) {
        // Middle of the line's ink, scanned horizontally for the first fully covered pixel.
        let p = RasterProbe(raster.image)
        let y = Int(line.y + line.baseline * 0.6 - raster.originY)
        for x in Int(line.x - raster.originX)..<Int(line.x + line.width - raster.originX) {
            let v = p.px(x, y)
            if v.a == 255 { return v }
        }
        return (0, 0, 0, 0)
    }

    @Test func eachLineIsFilledInItsOwnColour() throws {
        let r = try #require(try TextRenderer.render(text: "I\nI", style: twoStyle, maxWidth: nil))
        let top = fill(at: r.layout.lines[0], in: r), bottom = fill(at: r.layout.lines[1], in: r)
        #expect(top.r == 255 && top.g == 255 && top.b == 255)
        #expect(bottom.r == 255 && bottom.g == 0 && bottom.b == 0)
    }

    @Test func karaokeKeepsEachLinesBaseColour() throws {
        let r = try #require(try TextRenderer.render(text: "I\nI I", style: twoStyle, maxWidth: nil,
                                                      highlight: TextHighlight(words: 2..<3, color: RGBAColor(red: 0, green: 0, blue: 1))))
        let top = fill(at: r.layout.lines[0], in: r), bottom = fill(at: r.layout.lines[1], in: r)
        #expect(top.r == 255 && top.g == 255 && top.b == 255)
        #expect(bottom.r == 255 && bottom.g == 0 && bottom.b == 0)   // word 1 (first on line 2) is not lit
    }

    @Test func animatedRenderAtRestDrawsTheSameTwoStyles() throws {
        let layout = TextLayout.layout(text: "I\nI", style: twoStyle, maxWidth: nil)
        let n = TextUnits.segment(layout).characters.count
        let states = [TextCharacterState](repeating: TextCharacterState(in: .rest, out: .rest), count: n)
        let r = try #require(try TextRenderer.render(text: "I\nI", style: twoStyle, maxWidth: nil, characterStates: states))
        let top = fill(at: r.layout.lines[0], in: r), bottom = fill(at: r.layout.lines[1], in: r)
        #expect(top.r == 255 && top.g == 255 && top.b == 255)
        #expect(bottom.r == 255 && bottom.g == 0 && bottom.b == 0)
        // The animated geometry measures the big line with its own font.
        let still = try #require(try TextRenderer.render(text: "I\nI", style: twoStyle, maxWidth: nil))
        #expect(r.pixelWidth == still.pixelWidth && r.pixelHeight == still.pixelHeight)
    }

    @Test func captionsIgnoreTheSecondLineStyle() {
        let t = CaptionLayout.template(text: "a\nb", style: twoStyle, canvasWidth: 1080, canvasHeight: 1920)
        #expect(t.style.secondLine == nil)
    }
}
#endif
