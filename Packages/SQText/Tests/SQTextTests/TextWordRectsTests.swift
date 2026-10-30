#if canImport(CoreText)
import Testing
import Foundation
import CoreGraphics
import SQCore
@testable import SQText

/// Per-word pill of a karaoke caption (NEXT: per-word rects from `wordSpans`).
@Suite struct TextWordRectsTests {
    let style = CaptionPresetLibrary.builtIn.style(for: CaptionPill.styleID)

    func layout(_ text: String, maxWidth: Double? = nil, style s: TextStyle? = nil) -> TextLayoutResult {
        TextLayout.layout(text: text, style: s ?? style, maxWidth: maxWidth)
    }

    @Test func oneRectPerWordInReadingOrderWithoutOverlap() {
        let l = layout("Hello big world")
        let r = TextWordRects.rects(layout: l, style: style)
        #expect(r.count == 3)
        for i in 1..<r.count { #expect(r[i].x > r[i - 1].maxX) }          // a visible gap, the pills never merge
        let block = l.backgroundRect!
        for w in r { #expect(w.x >= block.x - 0.01 && w.maxX <= block.maxX + 0.01 && w.y >= block.y - 0.01 && w.maxY <= block.maxY + 0.01) }
        #expect(abs(r[0].height - block.height) < 0.01)                    // same vertical padding as the block pill
    }

    @Test func aSingleWordOrNoBackgroundHasNoPerWordRects() {
        #expect(TextWordRects.rects(layout: layout("Hello"), style: style).isEmpty)
        var plain = style; plain.background = nil
        #expect(TextWordRects.rects(layout: layout("Hello world", style: plain), style: plain).isEmpty)
    }

    @Test func wrappedTextGetsARectOnEachLine() {
        let l = layout("one two three four five six seven eight", maxWidth: 300)
        #expect(l.lines.count > 1)
        let r = TextWordRects.rects(layout: l, style: style)
        #expect(r.count >= 8)
        #expect(Set(r.map { $0.y.rounded() }).count == l.lines.count)         // rows match the lines
    }

    @Test func paddingNeverExceedsTheStylesAndKeepsAGap() throws {
        let l = layout("a b")
        let r = TextWordRects.rects(layout: l, style: style)
        let line = try #require(l.lines.first)
        let pad = try #require(style.background).padding.horizontal
        #expect(r[0].x >= line.x - pad - 0.01)
        #expect(r[1].x - r[0].maxX > 0.5)
    }

    @Test func plainHighlightOnlyForKaraokePillCaptionsWithSeveralWords() {
        let k = KaraokeStyle()
        #expect(CaptionKaraoke.plainHighlight(style: style, karaoke: k, wordCount: 3)?.perWordPill == true)
        #expect(CaptionKaraoke.plainHighlight(style: style, karaoke: nil, wordCount: 3) == nil)
        #expect(CaptionKaraoke.plainHighlight(style: style, karaoke: k, wordCount: 1) == nil)
        var plain = style; plain.background = nil
        #expect(CaptionKaraoke.plainHighlight(style: plain, karaoke: k, wordCount: 3) == nil)
    }

    @Test func highlightWithoutThePillFlagDecodesAsBefore() throws {
        let old = #"{"words":[0,1],"color":{"red":1,"green":0,"blue":0,"alpha":1}}"#
        let h = try JSONDecoder().decode(TextHighlight.self, from: Data(old.utf8))
        #expect(h.perWordPill == false && h.onlyLit == false)
    }

    /// The rasterized pill: with the flag the gap between two words is transparent, without it the block pill is solid there.
    @Test func perWordPillLeavesTheGapBetweenWordsClear() throws {
        let text = "Hello world"
        let l = layout(text)
        let r = TextWordRects.rects(layout: l, style: style)
        try #require(r.count == 2)
        let gapX = (r[0].maxX + r[1].x) / 2
        func alpha(_ highlight: TextHighlight?) throws -> UInt8 {
            let raster = try #require(try TextRenderer.render(text: text, style: style, maxWidth: nil, highlight: highlight))
            let px = Int((gapX - raster.originX).rounded())
            let py = Int(((l.backgroundRect!.y + l.backgroundRect!.height / 2) - raster.originY).rounded())
            let img = raster.image
            let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
            let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
            // CGContext memory is top row first for a bitmap context created with data: nil.
            return data[py * ctx.bytesPerRow + px * 4 + 3]
        }
        let plain = try alpha(nil)
        let perWord = try alpha(TextHighlight(words: 0..<0, color: .white, perWordPill: true))
        #expect(plain > 150)
        #expect(perWord < 10)
    }
}
#endif
