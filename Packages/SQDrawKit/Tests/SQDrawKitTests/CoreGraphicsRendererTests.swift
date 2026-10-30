#if canImport(CoreGraphics)
import CoreGraphics
import Foundation
import Testing
@testable import SQDrawKit

/// The Mac Canvas backend against the reference rasterizer: the same list must give the same picture (edges may differ
/// by antialiasing, so the check is on the mean and on how many channels are clearly off).
@Suite struct CoreGraphicsRendererTests {
    static func compare(_ list: DrawList, _ w: Int, _ h: Int, atlas: GlyphAtlas?) throws -> (mean: Double, over: Double) {
        let clear = DrawColor(hex: 0x1E1E1E)
        let cg = try #require(CoreGraphicsRenderer.render(list, width: w, height: h, clear: clear, atlas: atlas))
        let sw = SoftwareRenderer.render(list, width: w, height: h, clear: clear, atlas: atlas)
        var sum = 0, over = 0, n = 0
        for i in 0..<sw.pixels.count where i % 4 != 3 {
            let d = abs(Int(cg.pixels[i]) - Int(sw.pixels[i]))
            sum += d; n += 1
            if d > 24 { over += 1 }
        }
        return (Double(sum) / Double(n), Double(over) / Double(n))
    }

    @Test func shapesMatchTheReference() throws {
        var c = Canvas(width: 200, height: 120, atlas: nil, scale: 1)
        c.fill(CGRect(x: 10, y: 10, width: 60, height: 30), DrawColor(hex: 0x3D7EFF))
        c.fill(roundedRect: CGRect(x: 80, y: 10, width: 60, height: 30), radius: 8, DrawColor(hex: 0xE5484D))
        c.stroke(roundedRect: CGRect(x: 10, y: 60, width: 60, height: 40), radius: 6, width: 2, .white)
        c.strokeLine(from: CGPoint(x: 90, y: 60), to: CGPoint(x: 180, y: 110), width: 3, DrawColor(hex: 0x30A46C))
        c.list.triangle(DrawRect(x: 150, y: 10, w: 20, h: 30), .white)
        let d = try Self.compare(c.list, 200, 120, atlas: nil)
        #expect(d.mean < 1.0)
        #expect(d.over < 0.005)
    }

    /// Large rounded fills are split into rects and clipped corners: still the reference picture, and no seam where the
    /// pieces meet even when translucent at fractional positions (dialog shadows).
    @Test func largeRoundedFillsAndThinAxisLinesMatchTheReference() throws {
        var c = Canvas(width: 240, height: 160, atlas: nil, scale: 1)
        c.fill(roundedRect: CGRect(x: 10.3, y: 8.6, width: 150.4, height: 120.7), radius: 12.5, DrawColor(hex: 0x3D7EFF).alpha(0.5))
        c.fill(roundedRect: CGRect(x: 120, y: 60, width: 100, height: 90), radius: 45, DrawColor(hex: 0xE5484D))
        c.strokeLine(from: CGPoint(x: 20, y: 140), to: CGPoint(x: 200, y: 140), width: 1, .white)
        c.strokeLine(from: CGPoint(x: 230, y: 10), to: CGPoint(x: 230, y: 150), width: 2, .white)
        let d = try Self.compare(c.list, 240, 160, atlas: nil)
        #expect(d.mean < 1.0)
        #expect(d.over < 0.005)
        let img = try #require(CoreGraphicsRenderer.render(c.list, width: 240, height: 160, clear: DrawColor(hex: 0x1E1E1E), atlas: nil))
        func px(_ x: Int, _ y: Int) -> Int { Int(img.pixels[(y * 240 + x) * 4]) }
        let inside = px(60, 60)
        for y in 15...30 { #expect(abs(px(60, y) - inside) <= 1) }      // across the top band / middle cut
        for x in 15...30 { #expect(abs(px(x, 60) - inside) <= 1) }      // across the left corner / middle cut
    }

    @Test func textMatchesTheReference() throws {
        let atlas = try #require(GlyphAtlas())
        var c = Canvas(width: 240, height: 40, atlas: atlas, scale: 2)
        c.draw("Sequence Studio", at: CGPoint(x: 4, y: 4), fontSize: 12, .white)
        let d = try Self.compare(c.list, 240, 40, atlas: atlas)
        #expect(c.list.quads.count > 10)
        #expect(d.mean < 1.0)
        #expect(d.over < 0.005)
    }
}
#endif
