#if canImport(CoreText)
import Testing
import Foundation
import CoreGraphics
import SQCore
@testable import SQText

/// Underline, strikethrough and overline (#336): style flags, one bar per line and kind, drawn by the static renderer and
/// the per-character animator renderer alike.
@Suite struct TextDecorationsTests {
    let base = TextStyle(fontName: "Helvetica-Bold", size: 120, color: RGBAColor(red: 1, green: 0, blue: 0))

    @Test func olderFilesDecodeAsOff() throws {
        let data = try JSONEncoder().encode(base)
        var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        for k in ["underline", "strikethrough", "overline"] { obj.removeValue(forKey: k) }
        let s = try JSONDecoder().decode(TextStyle.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(!s.underline && !s.strikethrough && !s.overline)
        var on = base; on.underline = true; on.overline = true
        #expect(try JSONDecoder().decode(TextStyle.self, from: JSONEncoder().encode(on)) == on)
    }

    @Test func barsFollowTheFlagsAndStackOverTheBaseline() {
        var s = base
        let plain = TextLayout.layout(text: "Ho", style: s, maxWidth: nil)
        #expect(TextDecorations.bars(layout: plain, style: s).isEmpty)
        s.underline = true; s.strikethrough = true; s.overline = true
        let lay = TextLayout.layout(text: "Ho\nHo", style: s, maxWidth: nil)
        let bars = TextDecorations.bars(layout: lay, style: s)
        #expect(bars.count == 6)
        let first = bars.filter { $0.lineIndex == 0 }
        let y = Dictionary(uniqueKeysWithValues: first.map { ($0.kind, $0.rect.y) })
        let l = lay.lines[0]
        #expect(y[.overline]! < y[.strikethrough]! && y[.strikethrough]! < l.y + l.baseline && l.y + l.baseline < y[.underline]!)
        #expect(first.allSatisfy { $0.rect.x == l.x && $0.rect.width == l.width && $0.rect.height >= 1 })
    }

    /// Column between the two letters of "I I": empty without a line style, covered at the bar's row with one.
    private func gapPixel(_ r: TextRaster, bar: TextRect) -> (r: Int, g: Int, b: Int, a: Int) {
        let p = RasterProbe(r.image)
        let l = r.layout.lines[0]
        let x = Int(l.x + l.width / 2 - r.originX)
        let y = Int(bar.y + bar.height / 2 - r.originY)
        return p.px(x, y)
    }

    @Test(arguments: [TextDecorations.Kind.underline, .strikethrough, .overline])
    func staticRasterDrawsTheBar(kind: TextDecorations.Kind) throws {
        var s = base
        let off = try #require(try TextRenderer.render(text: "I I", style: s, maxWidth: nil))
        switch kind { case .underline: s.underline = true; case .strikethrough: s.strikethrough = true; case .overline: s.overline = true }
        let lay = TextLayout.layout(text: "I I", style: s, maxWidth: nil)
        let bar = try #require(TextDecorations.bars(layout: lay, style: s).first { $0.kind == kind }).rect
        let on = try #require(try TextRenderer.render(text: "I I", style: s, maxWidth: nil))
        #expect(gapPixel(off, bar: bar).a == 0)
        let c = gapPixel(on, bar: bar)
        #expect(c.a == 255 && c.r == 255 && c.g == 0 && c.b == 0)     // the glyph fill color
    }

    @Test func animatedRasterDrawsTheSameBarAtRest() throws {
        var s = base; s.underline = true
        let set = AnimationSet(in: KeyframeTemplate(textAnimator: TextAnimator(effect: .fade, unit: .character, duration: Time(1, 5),
                                                                               stagger: Time(1, 10))), out: nil)
        let lay = TextLayout.layout(text: "I I", style: s, maxWidth: nil)
        let states = try #require(set.characterStates(units: TextUnits.segment(lay), clipTime: Time(5, 1), clipDuration: Time(10, 1)))
        let a = try #require(try TextRenderer.render(text: "I I", style: s, maxWidth: nil, characterStates: states))
        let bar = try #require(TextDecorations.bars(layout: lay, style: s).first).rect
        #expect(gapPixel(a, bar: bar).a == 255)
    }
}
#endif
