#if canImport(CoreText)
import Testing
import Foundation
import CoreText
@testable import SQText

/// FILMCRAFT-ISSUES 15: CJK wrapping and fallback, Arabic/Hebrew shaping, writing direction in the layout.
@Suite struct InternationalTextTests {
    func style(_ direction: TextDirection? = nil, alignment: TextAlignment = .left) -> TextStyle {
        var s = TextStyle(fontName: "Helvetica", size: 32, alignment: alignment)
        s.direction = direction
        return s
    }

    // MARK: Direction

    @Test func autoDirectionFollowsFirstStrongCharacter() {
        #expect(TextDirection.isRightToLeft("שלום עולם", override: nil))
        #expect(TextDirection.isRightToLeft("مرحبا بالعالم", override: nil))
        #expect(TextDirection.isRightToLeft("123 שלום", override: nil))          // digits are not strong
        #expect(!TextDirection.isRightToLeft("Hello שלום", override: nil))
        #expect(!TextDirection.isRightToLeft("你好世界", override: nil))
        #expect(!TextDirection.isRightToLeft("", override: nil))
    }

    @Test func explicitDirectionWins() {
        #expect(TextDirection.isRightToLeft("Hello", override: .rightToLeft))
        #expect(!TextDirection.isRightToLeft("שלום", override: .leftToRight))
    }

    @Test func layoutMarksLinesPerParagraph() {
        let r = TextLayout.layout(text: "Hello\nשלום", style: style(), maxWidth: 800)
        #expect(r.lines.map(\.isRightToLeft) == [false, true])
    }

    @Test func wrappedRTLParagraphKeepsDirectionOnEveryLine() {
        // The second line starts with a Latin word: it must still be an RTL line (paragraph direction, not per line).
        let text = "שלום עולם שלום עולם שלום עולם שלום עולם Hello World"
        let r = TextLayout.layout(text: text, style: style(), maxWidth: 220)
        #expect(r.lines.count > 1)
        #expect(r.lines.map(\.isRightToLeft).allSatisfy { $0 })
        let words = r.lines.flatMap { $0.text.split(separator: " ") }.map(String.init)
        #expect(words == text.split(separator: " ").map(String.init))
    }

    @Test func overrideFlipsLatinParagraph() {
        let r = TextLayout.layout(text: "Hello", style: style(.rightToLeft), maxWidth: 400)
        #expect(r.lines[0].isRightToLeft)
    }

    @Test func directionCodableOmitsAutoAndKeepsExplicit() throws {
        let auto = try JSONEncoder().encode(style())
        #expect(!String(decoding: auto, as: UTF8.self).contains("direction"))
        let back = try JSONDecoder().decode(TextStyle.self, from: auto)
        #expect(back.direction == nil)
        let rtl = try JSONEncoder().encode(style(.rightToLeft))
        let backRTL = try JSONDecoder().decode(TextStyle.self, from: rtl)
        #expect(backRTL.direction == .rightToLeft)
    }

    // MARK: Arabic and Hebrew shaping

    private func glyphCount(_ text: String, rtl: Bool) -> (glyphs: Int, chars: Int) {
        let font = TextLayout.makeFont(style())
        let attr = NSAttributedString(string: text, attributes: TextLayout.attributes(font: font, tracking: 0, rightToLeft: rtl))
        let line = CTLineCreateWithAttributedString(attr)
        return (Int(CTLineGetGlyphCount(line)), (text as NSString).length)
    }

    @Test func arabicLamAlefShapesToOneGlyph() {
        let g = glyphCount("\u{644}\u{627}", rtl: true)        // lam + alef
        #expect(g.chars == 2)
        #expect(g.glyphs == 1)
    }

    @Test func arabicLineHasWidthAndFallbackFont() {
        let r = TextLayout.layout(text: "مرحبا بالعالم", style: style(), maxWidth: nil)
        #expect(r.lines.count == 1)
        #expect(r.lines[0].width > 20)
        #expect(r.lines[0].height >= CTFontGetAscent(TextLayout.makeFont(style())))
    }

    @Test func hebrewKeepsAllWordsWhenWrapping() {
        let text = "זהו משפט ארוך מאוד בעברית שצריך להישבר לכמה שורות"
        let r = TextLayout.layout(text: text, style: style(), maxWidth: 260)
        #expect(r.lines.count > 1)
        for l in r.lines { #expect(l.width <= 260.001) }
        #expect(r.lines.map(\.text).joined(separator: " ") == text)
    }

    // MARK: CJK

    @Test func chineseWithoutSpacesWraps() {
        let text = String(repeating: "今天天气很好我们去公园玩", count: 4)
        let r = TextLayout.layout(text: text, style: style(), maxWidth: 300)
        #expect(r.lines.count > 1)
        for l in r.lines { #expect(l.width <= 300.001) }
        #expect(r.lines.map(\.text).joined() == text)
    }

    @Test func japaneseLineNeverStartsWithClosingPunctuation() {
        let text = String(repeating: "これは日本語の文章です、改行の位置を確認します。", count: 3)
        let r = TextLayout.layout(text: text, style: style(), maxWidth: 260)
        #expect(r.lines.count > 1)
        let closing = Set("、。，．）」』】！？：；ー")
        for l in r.lines.dropFirst() { #expect(!closing.contains(l.text.first!)) }
        #expect(r.lines.map(\.text).joined() == text)
    }

    @Test func openingBracketStaysWithNextCharacter() {
        let text = String(repeating: "我们（今天）去「公园」玩", count: 5)
        let r = TextLayout.layout(text: text, style: style(), maxWidth: 200)
        let opening = Set("（「『【")
        for l in r.lines { #expect(!opening.contains(l.text.last!)) }
    }

    @Test func breakOpportunitiesBetweenIdeographsAndLatin() {
        #expect(TextLayout.breakOpportunities("今天好") == [1, 2])
        #expect(TextLayout.breakOpportunities("今。天") == [2])           // not before the closing mark
        #expect(TextLayout.breakOpportunities("ab cd") == [3])            // Latin unchanged
        #expect(TextLayout.breakOpportunities("ab你好") == [2, 3])
    }

    @Test func cjkFallbackFontIsUsedAndMeasured() {
        let font = TextLayout.makeFont(style())
        let attr = NSAttributedString(string: "漢字", attributes: TextLayout.attributes(font: font, tracking: 0))
        let line = CTLineCreateWithAttributedString(attr)
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        let name = { (r: CTRun) -> String in
            let f = (CTRunGetAttributes(r) as NSDictionary)[kCTFontAttributeName as String] as! CTFont
            return CTFontCopyPostScriptName(f) as String
        }
        #expect(runs.allSatisfy { name($0) != CTFontCopyPostScriptName(font) as String })
        let r = TextLayout.layout(text: "漢字", style: style(), maxWidth: nil)
        #expect(r.lines[0].width > 32)                                    // two full-width glyphs at 32 pt
    }
}
#endif
