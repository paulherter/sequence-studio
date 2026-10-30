#if canImport(CoreText)
import Testing
import CoreGraphics
import Foundation
@testable import SQText

/// Premiere's text shadow "Size" is a spread: the glyph shape grows by `spread` px before the blur, so a thin glyph still
/// casts a dense shadow. Without it a large blur turns a thin text's shadow into a faint haze.
@Suite struct TextShadowSpreadTests {
    let style = TextStyle(fontName: "Helvetica-Bold", size: 120, color: RGBAColor(red: 1, green: 1, blue: 1))
    func shadow(spread: Double) -> TextShadow {
        var s = TextShadow(color: RGBAColor(red: 0, green: 0, blue: 0), offsetX: 0, offsetY: 0, blur: 0)
        s.spread = spread
        return s
    }

    @Test func spreadDefaultsToZeroAndOldProjectsStillDecode() throws {
        #expect(shadow(spread: 0).spread == 0)
        let old = #"{"color":{"red":0,"green":0,"blue":0,"alpha":0.5},"offsetX":1,"offsetY":2,"blur":3}"#
        let s = try JSONDecoder().decode(TextShadow.self, from: Data(old.utf8))
        #expect(s.spread == 0 && s.blur == 3 && s.offsetY == 2)
        let back = try JSONDecoder().decode(TextShadow.self, from: JSONEncoder().encode(shadow(spread: 7)))
        #expect(back.spread == 7)
    }

    @Test func negativeSpreadIsClampedToZero() {
        var s = shadow(spread: 0)
        s.spread = -5
        #expect(s.spread == 0)
    }

    @Test func spreadGrowsTheInkBounds() throws {
        var a = style, b = style
        a.shadow = shadow(spread: 0); b.shadow = shadow(spread: 20)
        let ra = try #require(try TextRenderer.render(text: "I", style: a, maxWidth: nil, scale: 1))
        let rb = try #require(try TextRenderer.render(text: "I", style: b, maxWidth: nil, scale: 1))
        #expect(rb.layout.inkBounds.width >= ra.layout.inkBounds.width + 39)
    }

    @Test func spreadWidensTheShadowAroundTheGlyphAndKeepsTheGlyph() throws {
        var st = style
        st.shadow = shadow(spread: 20)
        let r = try #require(try TextRenderer.render(text: "I", style: st, maxWidth: nil, scale: 1))
        let l = r.layout.lines[0]
        let p = RasterProbe(r.image)
        let cx = Int(l.x + l.width / 2 - r.originX), y = Int(l.y + l.baseline - 50 - r.originY)
        #expect(p.px(cx, y).r > 240)                         // the white glyph itself is untouched
        // Find the stem edge, then probe 10 px outside it: inside the 20 px spread, so the shadow is solid there.
        var edge = cx
        while p.px(edge, y).r > 128 { edge += 1 }
        let near = p.px(edge + 10, y)
        #expect(near.a > 240 && near.r < 20)
        #expect(p.px(edge + 40, y).a < 10)                   // beyond the spread: clear (no blur)
    }

    @Test func spreadShadowFollowsTheOffset() throws {
        var st = style
        var sh = TextShadow(color: RGBAColor(red: 0, green: 0, blue: 0), offsetX: 0, offsetY: 30, blur: 0)
        sh.spread = 10
        st.shadow = sh
        let r = try #require(try TextRenderer.render(text: "I", style: st, maxWidth: nil, scale: 1))
        let l = r.layout.lines[0]
        let p = RasterProbe(r.image)
        let cx = Int(l.x + l.width / 2 - r.originX)
        let baseline = Int(l.y + l.baseline - r.originY)
        #expect(p.px(cx, baseline + 20).a > 240)             // 30 down + 10 spread reaches 40 below the baseline
        #expect(p.px(cx, baseline + 50).a < 10)
    }

    @Test func blurredSpreadShadowIsDenserThanBlurAlone() throws {
        var plain = style, spread = style
        var s0 = TextShadow(color: RGBAColor(red: 0, green: 0, blue: 0), offsetX: 0, offsetY: 0, blur: 40)
        plain.shadow = s0
        s0.spread = 20
        spread.shadow = s0
        func edgeAlpha(_ st: TextStyle) throws -> Int {
            let r = try #require(try TextRenderer.render(text: "I", style: st, maxWidth: nil, scale: 1))
            let l = r.layout.lines[0]
            let p = RasterProbe(r.image)
            let cx = Int(l.x + l.width / 2 - r.originX), y = Int(l.y + l.baseline - 50 - r.originY)
            var edge = cx
            while p.px(edge, y).r > 128 { edge += 1 }
            return p.px(edge + 8, y).a
        }
        #expect(try edgeAlpha(spread) > edgeAlpha(plain) + 40)
    }

    @Test func animatedRendererDrawsTheSpreadLikeTheStaticOne() throws {
        var st = style
        st.shadow = shadow(spread: 20)
        let r = try #require(try TextRenderer.render(text: "I", style: st, maxWidth: nil, scale: 1, characterStates: []))
        let l = r.layout.lines[0]
        let p = RasterProbe(r.image)
        let cx = Int(l.x + l.width / 2 - r.originX), y = Int(l.y + l.baseline - 50 - r.originY)
        #expect(p.px(cx, y).r > 240)
        var edge = cx
        while p.px(edge, y).r > 128 { edge += 1 }
        #expect(p.px(edge + 10, y).a > 240 && p.px(edge + 10, y).r < 20)
        #expect(p.px(edge + 40, y).a < 10)
    }
}
#endif
