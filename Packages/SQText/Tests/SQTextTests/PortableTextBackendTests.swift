import Foundation
import Testing
@testable import SQText

@Suite struct PortableTextBackendTests {
    private func inter() throws -> SfntFace {
        let url = try #require(InterFont.fontURLs.first)
        return try #require(SfntFace(url: url))
    }

    @Test func readsMetricsAndAdvances() throws {
        let f = try inter()
        #expect(f.unitsPerEm == 2048)
        #expect(f.ascender > 0 && f.descender < 0)
        let a = f.glyph(for: "A"), space = f.glyph(for: " ")
        #expect(a > 0 && space > 0 && a != space)
        #expect(f.advance(glyph: a) > f.advance(glyph: space))
        #expect(f.glyph(for: "\u{1F600}") == 0)   // not in the font: .notdef
    }

    @Test func everyBundledFamilyFileParses() throws {
        for fam in BundledFonts.families {
            for u in BundledFonts.fontURLs(of: fam) {
                let face = try #require(SfntFace(url: u), "\(u.lastPathComponent)")
                #expect(face.glyph(for: "e") > 0, "\(u.lastPathComponent)")
            }
        }
    }

    #if canImport(CoreText)
    @Test func widthsMatchCoreTextWithinKerningAndOpticalSize() throws {
        _ = InterFont.register()
        let face = try inter()
        let text = "Sequence Studio"
        let ct = TextLayout.layout(text: text, style: TextStyle(fontName: "Inter", size: 40), maxWidth: nil).lines[0].width
        let own = text.unicodeScalars.reduce(0.0) { $0 + Double(face.advance(glyph: face.glyph(for: $1))) * 40 / Double(face.unitsPerEm) }
        #expect(abs(ct - own) / ct < 0.12, "ct \(ct) own \(own)")
    }
    #else
    @Test func layoutMeasuresAndWraps() {
        let style = TextStyle(fontName: "Inter", size: 40)
        let one = TextLayout.layout(text: "Hello world again", style: style, maxWidth: nil)
        #expect(one.lines.count == 1 && one.lines[0].width > 100)
        let wrapped = TextLayout.layout(text: "Hello world again", style: style, maxWidth: one.lines[0].width * 0.6)
        #expect(wrapped.lines.count >= 2)
        #expect(wrapped.lines.allSatisfy { $0.height > 40 })
    }
    #endif
}
