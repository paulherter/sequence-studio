#if canImport(CoreText)
import CoreText
import Foundation
import Testing
@testable import SQText

/// The portable font choice (Windows) against Core Text: same face per weight, same advances with kerning, same
/// variable-font outlines.
@Suite struct PortableFontMatchTests {
    private func style(_ name: String, _ size: Double, _ weight: FontWeight, italic: Bool = false) -> TextStyle {
        InterFont.register()
        return TextStyle(fontName: name, size: size, weight: weight, italic: italic)
    }

    @Test func weightPicksTheSameFaceAsCoreText() throws {
        for name in ["Inter", "Montserrat", "Poppins", "Oswald", "Rubik"] {
            for w in [FontWeight.thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black] {
                let mac = FontResolver.weightTrait(of: FontResolver.font(for: style(name, 40, w)))
                let pc = try #require(PortableFontMatch.choose(name: name, weight: w, italic: false, size: 40))
                #expect(abs(pc.weightTrait - mac) < 0.01, "\(name) \(w): \(pc.weightTrait) vs \(mac)")
            }
        }
    }

    @Test func italicUsesTheItalicFile() throws {
        let c = try #require(PortableFontMatch.choose(name: "Inter", weight: .bold, italic: true, size: 40))
        #expect(!c.shear)
        let sheared = try #require(PortableFontMatch.choose(name: "Montserrat", weight: .bold, italic: true, size: 40))
        #expect(sheared.shear)
    }

    /// Pen advance of `text` with kerning, in points, as the portable layout and raster place glyphs.
    private func portableWidth(_ text: String, _ s: TextStyle) throws -> Double {
        let c = try #require(PortableFontMatch.choose(name: s.fontName, weight: s.weight, italic: s.italic, size: s.size))
        let unit = s.size / Double(c.font.unitsPerEm)
        var pen = 0.0, previous: Int?
        for scalar in text.unicodeScalars {
            let g = c.font.glyph(for: scalar)
            if let p = previous { pen += c.face.kern(p, g, coords: c.coords) * unit }
            pen += c.font.advance(glyph: g, coords: c.coords) * unit
            previous = g
        }
        return pen
    }

    private func coreTextWidth(_ text: String, _ s: TextStyle) -> Double {
        let font = FontResolver.font(for: s)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font]))
        return CTLineGetTypographicBounds(line, nil, nil, nil)
    }

    @Test(arguments: [FontWeight.regular, .bold, .black, .light])
    func advancesAndKerningMatchCoreText(_ w: FontWeight) throws {
        // Inter only: Core Text may pick an installed copy of the other families (other glyph ids) on a dev Mac.
        for (name, size) in [("Inter", 56.0), ("Inter", 12.0), ("Inter", 24.0)] {
            for text in ["AVATAR Toyota", "Sequence Studio", "WAVE yes, To Ty"] {
                for italic in [false, true] {
                    let s = style(name, size, w, italic: italic)
                    let pc = try portableWidth(text, s), mac = coreTextWidth(text, s)
                    #expect(abs(pc - mac) < 0.02 * size / 12, "\(name) \(size) \(w) italic \(italic) \(text): \(pc) vs \(mac)")
                }
            }
        }
    }

    @Test func boldOutlinesMatchCoreText() throws {
        for (w, italic) in [(FontWeight.bold, false), (.black, true), (.thin, false)] {
            let s = style("Inter", 64, w, italic: italic)
            let c = try #require(PortableFontMatch.choose(name: "Inter", weight: w, italic: italic, size: 64))
            let font = FontResolver.font(for: s)
            let unit = 64 / Double(c.font.unitsPerEm)
            for ch in "aRg&é" {
                let scalar = ch.unicodeScalars.first!
                let g = c.font.glyph(for: scalar)
                var ctGlyph = CGGlyph(0)
                var u = UniChar(scalar.value)
                CTFontGetGlyphsForCharacters(font, &u, &ctGlyph, 1)
                #expect(Int(ctGlyph) == g)
                let path = try #require(CTFontCreatePathForGlyph(font, ctGlyph, nil))
                let box = path.boundingBoxOfPath
                let pts = OutlineFonts.polylines(c.font.contours(glyph: g, coords: c.coords), pixelsPerUnit: unit) { x, y in
                    SIMD2(x * unit, y * unit)
                }.flatMap { $0 }
                let minX = pts.map(\.x).min()!, maxX = pts.map(\.x).max()!
                let minY = pts.map(\.y).min()!, maxY = pts.map(\.y).max()!
                // The flattened curves' box; bold and thin differ from the default instance by several points.
                #expect(abs(minX - box.minX) < 0.35 && abs(maxX - box.maxX) < 0.35, "\(w) \(ch) x \(minX)...\(maxX) vs \(box)")
                #expect(abs(minY - box.minY) < 0.35 && abs(maxY - box.maxY) < 0.35, "\(w) \(ch) y \(minY)...\(maxY) vs \(box)")
            }
        }
    }
}
#endif
