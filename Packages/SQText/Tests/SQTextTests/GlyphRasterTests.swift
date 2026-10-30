import Foundation
import Testing
@testable import SQText

@Suite("GlyphRaster")
struct GlyphRasterTests {
    @Test func squareCoverageIsExact() {
        // A 2x2 square from (1,1) to (3,3) in a 4x4 grid, clockwise in y-down pixels.
        var r = CoverageRasterizer(width: 4, height: 4)
        r.line(1, 1, 3, 1); r.line(3, 1, 3, 3); r.line(3, 3, 1, 3); r.line(1, 3, 1, 1)
        let c = r.coverage()
        #expect(c == [0, 0, 0, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 0, 0, 0])
    }

    @Test func halfPixelEdgeGivesHalfCoverage() {
        var r = CoverageRasterizer(width: 2, height: 1)
        r.line(0, 0, 1.5, 0); r.line(1.5, 0, 1.5, 1); r.line(1.5, 1, 0, 1); r.line(0, 1, 0, 0)
        let c = r.coverage()
        #expect(c[0] == 255)
        #expect(abs(Int(c[1]) - 128) <= 1)
    }

    @Test func interLettersRasterize() throws {
        let font = try #require(GlyphRasterFont.inter)
        let h = font.glyph(for: "H")
        #expect(h != 0)
        #expect(font.advance(glyph: h) > 0)
        let bmp = font.rasterize(glyph: h, pixelsPerEm: 20)
        // Cap height of Inter is ~0.73 em: about 15 px at 20 px/em, sitting on the baseline.
        #expect((13...17).contains(bmp.height))
        #expect(bmp.top == bmp.height)
        // The crossbar row is covered across the middle; the counters above it are open.
        let midRow = bmp.height / 2, mid = bmp.width / 2
        #expect(bmp.coverage[midRow * bmp.width + mid] > 200)
        #expect(bmp.coverage[2 * bmp.width + mid] < 30)
        // Composite or simple, 'é' and 'g' carry ink; space has none.
        #expect(font.rasterize(glyph: font.glyph(for: "é"), pixelsPerEm: 20).coverage.contains { $0 > 200 })
        #expect(font.rasterize(glyph: font.glyph(for: "g"), pixelsPerEm: 20).top < font.rasterize(glyph: font.glyph(for: "g"), pixelsPerEm: 20).height)
        #expect(font.rasterize(glyph: font.glyph(for: " "), pixelsPerEm: 20) == .empty)
    }

    #if os(macOS)
    /// The Mac shared UI sets its text in the system font, as the AppKit UI does (`NSFont.systemFont`), not Inter.
    @Test func macSystemFontLoadsWithWeights() throws {
        let font = try #require(GlyphRasterFont.macSystemUI)
        let h = font.glyph(for: "H")
        #expect(h != 0)
        let bmp = font.rasterize(glyph: h, pixelsPerEm: 20)
        #expect((12...16).contains(bmp.height))
        // Wider than Inter's "m" is not the point: it must be another face, and a weight instance keeps the optical size.
        let inter = try #require(GlyphRasterFont.inter)
        #expect(font.advance(glyph: font.glyph(for: "m")) * inter.unitsPerEm != inter.advance(glyph: inter.glyph(for: "m")) * font.unitsPerEm)
        let semibold = try #require(font.instance(weight: 600))
        #expect(semibold.coords != font.coords)
        #expect(semibold.settings["opsz"] == font.settings["opsz"])
        let ink = { (f: GlyphRasterFont) in f.rasterize(glyph: f.glyph(for: "H"), pixelsPerEm: 40).coverage.reduce(0) { $0 + Int($1) } }
        #expect(ink(semibold) > ink(font))
    }
    #endif
}
