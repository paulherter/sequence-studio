import Testing
import CoreGraphics
@testable import SSText

/// The newer style options have to show up in the pixels, not only in the layout numbers (playback and export draw
/// the same raster).
@Suite struct StyleRenderingTests {
    func style(_ v: TextVerticalAlignment = .top, tracking: Double = 0, italic: Bool = false) -> TextStyle {
        TextStyle(fontName: "Helvetica-Bold", size: 100, color: .white, alignment: .center,
                  tracking: tracking, italic: italic, verticalAlignment: v)
    }

    /// Rows (top = 0) that contain any opaque pixel.
    func opaqueRows(_ r: TextRaster) -> ClosedRange<Int>? {
        let p = RasterProbe(r.image)
        let rows = (0..<p.h).filter { y in (0..<p.w).contains { p.px($0, y).a > 128 } }
        guard let a = rows.first, let b = rows.last else { return nil }
        return a...b
    }

    @Test func verticalAlignmentMovesTheGlyphsInsideTheBox() throws {
        func centre(_ v: TextVerticalAlignment) throws -> Double {
            let r = try #require(try TextRenderer.render(text: "I", style: style(v), maxWidth: 300, boxHeight: 400))
            #expect(r.pixelHeight == 400)
            let rows = try #require(opaqueRows(r))
            return Double(rows.lowerBound + rows.upperBound) / 2
        }
        let top = try centre(.top), mid = try centre(.middle), bot = try centre(.bottom)
        #expect(top < 120 && mid > 160 && mid < 240 && bot > 280)
    }

    @Test func trackingSpreadsTheGlyphs() throws {
        func inkWidth(_ t: Double) throws -> Int {
            let r = try #require(try TextRenderer.render(text: "II", style: style(tracking: t), maxWidth: nil))
            let p = RasterProbe(r.image)
            let cols = (0..<p.w).filter { x in (0..<p.h).contains { p.px(x, $0).a > 128 } }
            return (cols.last ?? 0) - (cols.first ?? 0)
        }
        let plain = try inkWidth(0), wide = try inkWidth(40), tight = try inkWidth(-10)
        #expect(wide - plain >= 35 && wide - plain <= 45)       // one gap between the two letters grows by about 40
        #expect(tight < plain)
    }

    @Test func italicLeansRight() throws {
        func leftEdge(_ r: TextRaster, row: Int) -> Int {
            let p = RasterProbe(r.image)
            return (0..<p.w).first { p.px($0, row).a > 128 } ?? -1
        }
        let up = try #require(try TextRenderer.render(text: "I", style: style(), maxWidth: nil))
        let it = try #require(try TextRenderer.render(text: "I", style: style(italic: true), maxWidth: nil))
        let rows = try #require(opaqueRows(it))
        let top = rows.lowerBound + 5, bottom = rows.upperBound - 5
        #expect(leftEdge(it, row: top) - leftEdge(it, row: bottom) >= 8)      // the top of the stem is further right
        let urows = try #require(opaqueRows(up))
        #expect(abs(leftEdge(up, row: urows.lowerBound + 5) - leftEdge(up, row: urows.upperBound - 5)) <= 1)
    }

    @Test func shadowOpacityAndAngleShowInThePixels() throws {
        var s = style()
        s.shadow = TextShadow(color: RGBAColor(red: 0, green: 0, blue: 0, alpha: 1), angle: 135, distance: 12, blur: 0)
        let r = try #require(try TextRenderer.render(text: "I", style: s, maxWidth: nil))
        let p = RasterProbe(r.image)
        // A pure black, opaque pixel exists to the lower right of the white stem; with 30 % opacity it turns translucent.
        let dark = (0..<p.h).contains { y in (0..<p.w).contains { x in let c = p.px(x, y); return c.a > 200 && c.r < 40 } }
        #expect(dark)
        s.shadow = TextShadow(color: RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.3), angle: 135, distance: 12, blur: 0)
        let r2 = try #require(try TextRenderer.render(text: "I", style: s, maxWidth: nil))
        let p2 = RasterProbe(r2.image)
        let solid = (0..<p2.h).contains { y in (0..<p2.w).contains { x in let c = p2.px(x, y); return c.a > 200 && c.r < 40 } }
        let faint = (0..<p2.h).contains { y in (0..<p2.w).contains { x in let c = p2.px(x, y); return c.a > 50 && c.a < 110 } }
        #expect(!solid && faint)
    }
}
