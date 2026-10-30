import Foundation
import SQDrawKit
import SQText
import Testing

/// Redraw cost (Color page round 6): the glyph atlas caches each character's glyph and advance, and a span cache replays
/// a polygon set's row spans; both draw exactly what the uncached paths drew.
@Suite struct DrawCostTests {
    /// The uncached width: the font's cmap and hmtx for every scalar (the old `GlyphAtlas.width`).
    static func directWidth(_ s: String, _ font: GlyphRasterFont, pixelSize: Float) -> Float {
        let k = pixelSize / Float(font.unitsPerEm)
        var pen: Float = 0
        for u in s.unicodeScalars { pen += Float(font.advance(glyph: font.glyph(for: u))) * k }
        return pen.rounded()
    }

    @Test func cachedMetricsMeasureLikeTheFont() throws {
        let atlas = try #require(GlyphAtlas())
        for s in ["Shadows", "Midtones 12.5 %", "Ünïcödé — “quoted” …", "日本", "", "AVAVAV ToTo"] {
            for size: Float in [11, 12, 13.5, 24] {
                #expect(atlas.width(of: s, pixelSize: size) == Self.directWidth(s, atlas.font, pixelSize: size))
                // A second call (cached) answers the same.
                #expect(atlas.width(of: s, pixelSize: size) == Self.directWidth(s, atlas.font, pixelSize: size))
            }
        }
        let g = atlas.metric(for: "A")
        #expect(g.glyph == atlas.font.glyph(for: "A") && g.advance == atlas.font.advance(glyph: g.glyph))
        let e = atlas.metric(for: "€")
        #expect(e.glyph == atlas.font.glyph(for: "€") && e.advance == atlas.font.advance(glyph: e.glyph))
    }

    @Test func textQuadsDoNotChangeWithTheCache() throws {
        let atlas = try #require(GlyphAtlas())
        var a = DrawList(width: 400, height: 100)
        a.text("Lift Gamma Gain €", x: 10.3, baseline: 40, pixelSize: 13, color: .white, atlas: atlas)
        a.text("A long label that has to end in an ellipsis", x: 10, baseline: 60, pixelSize: 12, color: .white, atlas: atlas,
               maxWidth: 120)
        // The expected pen positions from the font directly.
        let font = atlas.font, k: Float = 13 / Float(font.unitsPerEm)
        var pen: Float = 0, xs: [Float] = []
        for u in "Lift Gamma Gain €".unicodeScalars {
            let g = font.glyph(for: u), e = atlas.entry(glyph: g, pixelSize: 13)
            if e.w > 0 { xs.append(10 + pen.rounded() + Float(e.left)) }
            pen += Float(font.advance(glyph: g)) * k
        }
        let drawn = a.quads.prefix(xs.count).map(\.x)
        #expect(Array(drawn) == xs)
        let fitted = try #require(atlas.fitted("A long label that has to end in an ellipsis", pixelSize: 12, maxWidth: 120))
        #expect(fitted.hasSuffix("…") && atlas.width(of: fitted, pixelSize: 12) <= 120)
    }

    static func wedges(_ r: CGFloat) -> [([CGPoint], DrawColor)] {
        (0..<24).map { i in
            let a0 = Double(i) / 24 * 2 * .pi, a1 = Double(i + 1) / 24 * 2 * .pi + 0.01
            func p(_ a: Double, _ rr: CGFloat) -> CGPoint { CGPoint(x: r + rr * CGFloat(cos(a)), y: r - rr * CGFloat(sin(a))) }
            return ([p(a0, r * 0.25), p(a0, r), p(a1, r), p(a1, r * 0.25)], DrawColor(Float(i) / 24, 0.5, 0.2, 0.6))
        }
    }

    @Test func spanCacheReplaysThePolygonsAtAnyOrigin() throws {
        let cache = PolygonSpanCache()
        for (origin, scale) in [(CGPoint(x: 20, y: 30), Float(1)), (CGPoint(x: 20.25, y: 30.5), 1), (CGPoint(x: 120, y: 7.5), 2),
                                (CGPoint(x: 20, y: 31), 1)] {
            var direct = Canvas(width: 800, height: 600, atlas: nil, scale: scale)
            direct.translateBy(x: 3, y: 4)
            for (pts, c) in Self.wedges(40) { direct.fill(polygon: pts.map { CGPoint(x: $0.x + origin.x, y: $0.y + origin.y) }, c) }
            var cached = Canvas(width: 800, height: 600, atlas: nil, scale: scale)
            cached.translateBy(x: 3, y: 4)
            cached.fill(polygons: Self.wedges(40), at: origin, key: 40, cache: cache)
            #expect(cached.list.quads.count == direct.list.quads.count)
            for (a, b) in zip(cached.list.quads, direct.list.quads) {
                #expect(abs(a.x - b.x) < 1e-3 && abs(a.y - b.y) < 1e-3 && abs(a.w - b.w) < 1e-3 && a.h == b.h && a.color == b.color)
            }
        }
        // Same key and fraction: the polygons are built once and replayed.
        var c = Canvas(width: 800, height: 600, atlas: nil, scale: 1)
        var built = 0
        for x in [10, 50, 90] {
            c.fill(polygons: { built += 1; return Self.wedges(30) }(), at: CGPoint(x: x, y: 10), key: 30, cache: cache)
        }
        #expect(built == 1 && cache.count >= 1)
        #expect(c.list.quads.count > 0 && c.list.quads.count % 3 == 0)
    }
}
