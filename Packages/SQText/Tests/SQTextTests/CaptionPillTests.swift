#if canImport(CoreText)
import Testing
import Foundation
import SQCore
@testable import SQText

@Suite struct CaptionPillTests {
    let lib = CaptionPresetLibrary.builtIn

    @Test func pillStyleIsInLibraryWithRoundedBackground() throws {
        #expect(lib.hasStyle(CaptionPill.styleID))
        let s = lib.style(for: CaptionPill.styleID)
        let bg = try #require(s.background)
        #expect(bg.padding.horizontal == (s.size * CaptionPill.horizontalEm).rounded())
        #expect(bg.padding.vertical == (s.size * CaptionPill.verticalEm).rounded())
        #expect(bg.cornerRadius > s.size * 2)   // clamped to half the pill height when drawn
    }

    @Test func pillRectSurroundsWordWithPadding() throws {
        let t = CaptionLayout.template(text: "Hello", style: lib.style(for: "pill"), canvasWidth: 1080, canvasHeight: 1920)
        let l = TextLayout.layout(text: t.text, style: t.style, maxWidth: t.box?.width, boxHeight: t.box?.height)
        let r = try #require(CaptionPill.rect(of: l))
        let pad = try #require(t.style.background).padding
        let line = try #require(l.lines.first)
        #expect(abs(r.width - (line.width + 2 * pad.horizontal)) < 0.01)
        #expect(abs(r.height - (line.height + 2 * pad.vertical)) < 0.01)
        #expect(abs((r.x + r.width / 2) - (line.x + line.width / 2)) < 0.01)   // centered on the word
    }

    @Test func plainShortVideoStyleHasNoPill() {
        #expect(lib.style(for: "tiktok").background == nil)
    }

    /// Monitor (TextGenerator) and burn-in (TextRenderer) draw the same pill: same raster size, pill inside the raster.
    @Test func monitorAndBurnInRastersMatch() throws {
        let t = CaptionLayout.template(text: "Wow", style: lib.style(for: "pill"), canvasWidth: 1080, canvasHeight: 1920)
        let canvas = SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 30))
        let f = try #require(try TextGenerator.frame(ref: TextGenerator.makeRef(template: t, animations: nil), localTime: .zero,
                                                      clipDuration: Time(2, 1), canvas: canvas, scale: 1))
        let r = try #require(try TextRenderer.render(text: t.text, style: t.style, maxWidth: t.box?.width, boxHeight: t.box?.height))
        #expect(abs(f.width - Double(r.pixelWidth)) < 0.01 && abs(f.height - Double(r.pixelHeight)) < 0.01)
        let l = TextLayout.layout(text: t.text, style: t.style, maxWidth: t.box?.width, boxHeight: t.box?.height)
        let rect = try #require(CaptionPill.rect(of: l))
        #expect(rect.width <= Double(r.pixelWidth) && rect.height <= Double(r.pixelHeight))
    }
}
#endif
