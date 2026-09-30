import Testing
import Foundation
@testable import SSText

@Suite struct TextLayoutTests {
    let long = "The quick brown fox jumps over the lazy dog and keeps running across the field"
    func style(_ a: TextAlignment = .left, spacing: Double = 0) -> TextStyle {
        TextStyle(fontName: "Helvetica", size: 32, alignment: a, lineSpacing: spacing)
    }

    @Test func emptyTextHasNoLines() {
        let r = TextLayout.layout(text: "", style: style(), maxWidth: 400)
        #expect(r.lines.isEmpty)
        #expect(r.bounds == .zero)
        #expect(r.backgroundRect == nil)
    }

    @Test func shortTextIsOneLine() {
        let r = TextLayout.layout(text: "Hello", style: style(), maxWidth: 1000)
        #expect(r.lines.count == 1)
        #expect(r.lines[0].text == "Hello")
        #expect(r.lines[0].width > 0 && r.lines[0].width < 1000)
        #expect(r.bounds.height > 0)
    }

    @Test func wrapsToMaxWidthAndKeepsAllWords() {
        let maxW = 300.0
        let r = TextLayout.layout(text: long, style: style(), maxWidth: maxW)
        #expect(r.lines.count > 1)
        for l in r.lines { #expect(l.width <= maxW + 0.001) }
        let rejoined = r.lines.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        #expect(rejoined == long)
        #expect(r.bounds.width <= maxW + 0.001)
    }

    @Test func narrowerWidthGivesMoreLines() {
        let a = TextLayout.layout(text: long, style: style(), maxWidth: 500).lines.count
        let b = TextLayout.layout(text: long, style: style(), maxWidth: 200).lines.count
        #expect(b > a)
    }

    @Test func noMaxWidthMeansNoWrap() {
        let r = TextLayout.layout(text: long, style: style(), maxWidth: nil)
        #expect(r.lines.count == 1)
    }

    @Test func hardNewlinesSplitParagraphsAndKeepEmptyLines() {
        let r = TextLayout.layout(text: "a\n\nb", style: style(), maxWidth: 500)
        #expect(r.lines.count == 3)
        #expect(r.lines[1].width == 0)
        #expect(r.lines[1].text.isEmpty)
    }

    @Test func linePositionsAreMonotonicWithConstantPitch() {
        let r = TextLayout.layout(text: long, style: style(), maxWidth: 250)
        let ys = r.lines.map(\.y)
        #expect(zip(ys, ys.dropFirst()).allSatisfy { $0 < $1 })
        let pitches = zip(ys, ys.dropFirst()).map { $1 - $0 }
        #expect(pitches.allSatisfy { abs($0 - pitches[0]) < 0.0001 })
        #expect(r.lines[0].y == 0)
    }

    @Test func lineSpacingAddsExactlyToPitch() {
        func pitch(_ s: Double) -> Double {
            let r = TextLayout.layout(text: long, style: style(spacing: s), maxWidth: 250)
            return r.lines[1].y - r.lines[0].y
        }
        #expect(abs((pitch(10) - pitch(0)) - 10) < 0.0001)
    }

    @Test func alignmentOffsetsWithinMaxWidth() {
        let W = 600.0
        let l = TextLayout.layout(text: "Hello", style: style(.left), maxWidth: W).lines[0]
        let c = TextLayout.layout(text: "Hello", style: style(.center), maxWidth: W).lines[0]
        let r = TextLayout.layout(text: "Hello", style: style(.right), maxWidth: W).lines[0]
        #expect(l.x == 0)
        #expect(abs(c.x - (W - c.width) / 2) < 0.0001)
        #expect(abs(r.x - (W - r.width)) < 0.0001)
        #expect(l.width == c.width && c.width == r.width)
    }

    @Test func alignmentWithoutMaxWidthUsesWidestLine() {
        let r = TextLayout.layout(text: "Hello world\nHi", style: style(.right), maxWidth: nil)
        let wide = r.lines[0], short = r.lines[1]
        #expect(wide.x == 0)
        #expect(abs(short.x - (wide.width - short.width)) < 0.0001)
    }

    @Test func boundsAreUnionOfLines() {
        let r = TextLayout.layout(text: long, style: style(.center), maxWidth: 300)
        #expect(r.bounds.x == r.lines.map(\.x).min())
        #expect(abs(r.bounds.width - r.lines.map(\.width).max()!) < 0.0001)
        let last = r.lines.last!
        #expect(abs(r.bounds.maxY - (last.y + last.height)) < 0.0001)
    }

    @Test func backgroundRectAddsPadding() {
        var s = style(.left)
        s.background = TextBackground(color: .black, padding: BoxPadding(horizontal: 10, vertical: 6), cornerRadius: 4)
        let r = TextLayout.layout(text: "Hello", style: s, maxWidth: 500)
        let bg = try! #require(r.backgroundRect)
        #expect(abs(bg.x - (r.bounds.x - 10)) < 0.0001)
        #expect(abs(bg.y - (r.bounds.y - 6)) < 0.0001)
        #expect(abs(bg.width - (r.bounds.width + 20)) < 0.0001)
        #expect(abs(bg.height - (r.bounds.height + 12)) < 0.0001)
    }

    @Test func largerSizeIsWiderAndTaller() {
        var big = style(); big.size = 64
        let a = TextLayout.layout(text: "Hello", style: style(), maxWidth: nil).bounds
        let b = TextLayout.layout(text: "Hello", style: big, maxWidth: nil).bounds
        #expect(b.width > a.width && b.height > a.height)
    }

    @Test func deterministic() {
        let a = TextLayout.layout(text: long, style: style(.center), maxWidth: 280)
        let b = TextLayout.layout(text: long, style: style(.center), maxWidth: 280)
        #expect(a == b)
    }

    @Test func unknownFontFallsBack() {
        var s = style(); s.fontName = "NoSuchFont-XYZ"
        let r = TextLayout.layout(text: "Hello", style: s, maxWidth: nil)
        #expect(r.lines.count == 1 && r.lines[0].width > 0)
    }
}

@Suite struct InkBoundsTests {
    func plain() -> TextStyle { TextStyle(fontName: "Helvetica", size: 32, alignment: .left) }

    @Test func plainStyleInkEqualsBounds() {
        let r = TextLayout.layout(text: "Hello\nWorld", style: plain(), maxWidth: nil)
        #expect(r.inkBounds == r.bounds)
        #expect(r.lines.allSatisfy { $0.inkBounds == $0.rect })
    }

    @Test func strokeGrowsInkOnAllSides() {
        var s = plain(); s.stroke = TextStroke(color: .black, width: 6)
        let r = TextLayout.layout(text: "Hello", style: s, maxWidth: nil)
        #expect(abs(r.inkBounds.x - (r.bounds.x - 6)) < 1e-9)
        #expect(abs(r.inkBounds.y - (r.bounds.y - 6)) < 1e-9)
        #expect(abs(r.inkBounds.maxX - (r.bounds.maxX + 6)) < 1e-9)
        #expect(abs(r.inkBounds.maxY - (r.bounds.maxY + 6)) < 1e-9)
        #expect(r.lines[0].inkBounds == r.inkBounds)
    }

    @Test func shadowExtendsTowardsOffsetPlusBlur() {
        var s = plain(); s.shadow = TextShadow(color: .black, offsetX: 4, offsetY: 10, blur: 5)
        let r = TextLayout.layout(text: "Hello", style: s, maxWidth: nil)
        // Down/right: offset + blur; up/left: original edge still counts, shadow only adds (blur - offset) if positive.
        #expect(abs(r.inkBounds.maxY - (r.bounds.maxY + 15)) < 1e-9)
        #expect(abs(r.inkBounds.maxX - (r.bounds.maxX + 9)) < 1e-9)
        #expect(abs(r.inkBounds.y - r.bounds.y) < 1e-9)      // blur 5 < offsetY 10: nothing above
        #expect(abs(r.inkBounds.x - (r.bounds.x - 1)) < 1e-9) // blur 5 > offsetX 4
    }

    @Test func negativeOffsetShadowGoesUp() {
        var s = plain(); s.shadow = TextShadow(color: .black, offsetX: 0, offsetY: -8, blur: 2)
        let r = TextLayout.layout(text: "Hello", style: s, maxWidth: nil)
        #expect(abs(r.inkBounds.y - (r.bounds.y - 10)) < 1e-9)
    }

    @Test func strokeAndShadowCombineAndBackgroundIsIncluded() {
        var s = plain()
        s.stroke = TextStroke(color: .black, width: 2)
        s.shadow = TextShadow(color: .black, offsetX: 0, offsetY: 3, blur: 4)
        s.background = TextBackground(color: .black, padding: BoxPadding(horizontal: 10, vertical: 6))
        let r = TextLayout.layout(text: "Hello", style: s, maxWidth: nil)
        let bg = r.backgroundRect!
        #expect(abs(r.inkBounds.x - (bg.x - 2 - 4)) < 1e-9)   // stroke 2, then blur 4 (offsetX 0)
        #expect(abs(r.inkBounds.maxY - (bg.maxY + 2 + 3 + 4)) < 1e-9)
        #expect(r.inkBounds.width >= r.bounds.width && r.inkBounds.height >= r.bounds.height)
    }

    @Test func perLineInkBoundsAreInsideResultInk() {
        var s = plain(); s.stroke = TextStroke(color: .black, width: 3)
        s.shadow = TextShadow(color: .black, offsetX: 2, offsetY: 2, blur: 3)
        let r = TextLayout.layout(text: "a\nbb\nccc", style: s, maxWidth: nil)
        for l in r.lines {
            #expect(l.inkBounds.x >= r.inkBounds.x - 1e-9 && l.inkBounds.maxX <= r.inkBounds.maxX + 1e-9)
            #expect(l.inkBounds.y >= r.inkBounds.y - 1e-9 && l.inkBounds.maxY <= r.inkBounds.maxY + 1e-9)
            #expect(l.inkBounds.width > l.rect.width && l.inkBounds.height > l.rect.height)
        }
    }

    @Test func emptyTextHasZeroInk() {
        var s = plain(); s.stroke = TextStroke(color: .black, width: 3)
        #expect(TextLayout.layout(text: "", style: s, maxWidth: nil).inkBounds == .zero)
    }
}
