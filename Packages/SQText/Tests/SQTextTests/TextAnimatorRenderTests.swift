#if canImport(CoreText)
import Testing
import Foundation
import CoreGraphics
import SQCore
@testable import SQText

/// Animated text has to show in the pixels: the monitor and the export draw the same raster.
@Suite struct TextAnimatorRenderTests {
    let style = TextStyle(fontName: "Helvetica-Bold", size: 100, color: .white)
    let canvas = SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30))

    func render(_ text: String, _ set: AnimationSet, at t: Time, clip: Time = Time(10, 1)) throws -> TextRaster? {
        let layout = TextLayout.layout(text: text, style: style, maxWidth: nil)
        let states = try #require(set.characterStates(units: TextUnits.segment(layout), clipTime: t, clipDuration: clip))
        return try TextRenderer.render(text: text, style: style, maxWidth: nil, characterStates: states)
    }

    func opaqueColumns(_ r: TextRaster, minAlpha: Int = 128) -> [Int] {
        let p = RasterProbe(r.image)
        return (0..<p.w).filter { x in (0..<p.h).contains { p.px(x, $0).a > minAlpha } }
    }

    func maxAlpha(_ r: TextRaster) -> Int {
        let p = RasterProbe(r.image)
        var m = 0
        for y in 0..<p.h { for x in 0..<p.w { m = max(m, p.px(x, y).a) } }
        return m
    }

    @Test func restStatesMatchTheStaticRaster() throws {
        let set = AnimationSet(in: KeyframeTemplate(textAnimator: TextAnimator(effect: .fade, unit: .word, duration: Time(1, 5),
                                                                               stagger: Time(1, 10))), out: nil)
        let a = try #require(try render("Hi you", set, at: Time(5, 1)))
        let b = try #require(try TextRenderer.render(text: "Hi you", style: style, maxWidth: nil))
        #expect(a.pixelWidth == b.pixelWidth && a.pixelHeight == b.pixelHeight)
        #expect(opaqueColumns(a) == opaqueColumns(b))
    }

    @Test func typewriterShowsOnlyTheStartedCharacters() throws {
        let set = AnimationSet(in: KeyframeTemplate(textAnimator: TextAnimator(effect: .typewriter, unit: .character,
                                                                               duration: .zero, stagger: Time(1, 1))), out: nil)
        let half = try #require(try render("II", set, at: Time(1, 2)))
        let full = try #require(try render("II", set, at: Time(3, 2)))
        let h = opaqueColumns(half), f = opaqueColumns(full)
        #expect(!h.isEmpty)
        #expect(h.last! < f.last! - 20)               // the second I is missing
        #expect(h.first == f.first)
    }

    @Test func fadeHalfwayIsHalfOpaque() throws {
        let set = AnimationSet(in: KeyframeTemplate(textAnimator: TextAnimator(effect: .fade, unit: .line, easing: .linear,
                                                                               duration: Time(1, 1), stagger: .zero)), out: nil)
        let r = try #require(try render("I", set, at: Time(1, 2)))
        let m = Int(maxAlpha(r))
        #expect(m > 110 && m < 145)
    }

    @Test func fadingStrokedTextHasNoInnerOutline() throws {
        // Stroke and fill of a character fade together as one layer: inside the glyph only the half-transparent fill shows.
        let stroked = TextStyle(fontName: "Helvetica-Bold", size: 200, color: .white, stroke: TextStroke(color: .black, width: 8))
        let layout = TextLayout.layout(text: "I", style: stroked, maxWidth: nil)
        let set = AnimationSet(in: KeyframeTemplate(textAnimator: TextAnimator(effect: .fade, unit: .character, easing: .linear,
                                                                               duration: Time(1, 1), stagger: .zero)), out: nil)
        let states = try #require(set.characterStates(units: TextUnits.segment(layout), clipTime: Time(1, 2), clipDuration: Time(10, 1)))
        let r = try #require(try TextRenderer.render(text: "I", style: stroked, maxWidth: nil, characterStates: states))
        let p = RasterProbe(r.image)
        let c = p.px(p.w / 2, p.h / 2)
        #expect(c.a > 110 && c.a < 145)          // one layer at 50 %, not stroke + fill stacked (~75 %)
        #expect(c.r > 110)                       // white fill, no black stroke underneath
    }

    @Test func animatedFramesDoNotFillTheStaticCache() throws {
        TextGenerator.clearCache()
        let anim = TextAnimator(effect: .fade, unit: .character, easing: .linear, duration: Time(1, 1), stagger: .zero)
        let ref = try TextGenerator.makeRef(template: TextTemplate(name: "t", text: "Cache", style: style),
                                            animations: AnimationSet(in: KeyframeTemplate(textAnimator: anim), out: nil))
        _ = try TextGenerator.frame(ref: ref, localTime: Time(5, 1), clipDuration: Time(10, 1), canvas: canvas, scale: 1)
        let before = TextGenerator.staticCacheBytes
        for i in 1..<10 {
            _ = try TextGenerator.frame(ref: ref, localTime: Time(Int64(i), 10), clipDuration: Time(10, 1), canvas: canvas, scale: 1)
        }
        #expect(TextGenerator.staticCacheBytes == before)
        #expect(TextGenerator.animatedCacheBytes > 0)
        #expect(TextGenerator.animatedCacheByteLimit < TextGenerator.cacheByteLimit)
    }

    @Test func slideGrowsTheRasterByTheOffset() throws {
        let set = AnimationSet(in: KeyframeTemplate(textAnimator: TextAnimator(effect: .slide, unit: .word, easing: .linear,
                                                                               duration: Time(1, 1), stagger: .zero,
                                                                               distance: 60, direction: .up)), out: nil)
        let still = try #require(try TextRenderer.render(text: "I", style: style, maxWidth: nil))
        let r = try #require(try render("I", set, at: Time(1, 2)))
        // Half way: 30 px below the rest position.
        #expect(abs((r.originY + Double(r.pixelHeight)) - (still.originY + Double(still.pixelHeight)) - 30) <= 1.5)
        #expect(r.originY <= still.originY)
    }

    @Test func blurSpreadsBeyondTheGlyph() throws {
        let set = AnimationSet(in: KeyframeTemplate(textAnimator: TextAnimator(effect: .blur, unit: .character, easing: .linear,
                                                                               duration: Time(1, 1), stagger: .zero,
                                                                               blurRadius: 20)), out: nil)
        let still = try #require(try TextRenderer.render(text: "I", style: style, maxWidth: nil))
        let r = try #require(try render("I", set, at: Time(1, 4)))
        let wide = opaqueColumns(r, minAlpha: 4), sharp = opaqueColumns(still, minAlpha: 4)
        #expect(wide.count > sharp.count + 10)
        #expect(maxAlpha(r) > 20)
    }

    @Test func generatorUsesTheStaticRasterAtRestAndAnimatesInBetween() throws {
        let anim = TextAnimator(effect: .typewriter, unit: .character, duration: .zero, stagger: Time(1, 1))
        let ref = try TextGenerator.makeRef(template: TextTemplate(name: "t", text: "II", style: style),
                                            animations: AnimationSet(in: KeyframeTemplate(textAnimator: anim), out: nil))
        let plain = try TextGenerator.makeRef(template: TextTemplate(name: "t", text: "II", style: style), animations: nil)
        let dur = Time(10, 1)
        let rest = try #require(try TextGenerator.frame(ref: ref, localTime: Time(5, 1), clipDuration: dur, canvas: canvas, scale: 1))
        let still = try #require(try TextGenerator.frame(ref: plain, localTime: Time(5, 1), clipDuration: dur, canvas: canvas, scale: 1))
        #expect(rest.buffer === still.buffer)
        let mid = try #require(try TextGenerator.frame(ref: ref, localTime: Time(1, 2), clipDuration: dur, canvas: canvas, scale: 1))
        #expect(mid.buffer !== still.buffer)
        // Same block placement: the raster's left edge stays put.
        #expect(abs(mid.x - still.x) < 1)
    }
}
#endif
