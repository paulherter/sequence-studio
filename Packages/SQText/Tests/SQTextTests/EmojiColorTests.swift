import Foundation
import Testing
@testable import SQText

/// COLR/CPAL layers and GSUB emoji joining, on a tiny hand-made font and (where the machine has it) the real Segoe UI Emoji.
@Suite struct EmojiColorTests {
    static func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    static func be32(_ v: Int) -> [UInt8] { be16(v >> 16) + be16(v & 0xFFFF) }

    /// An sfnt directory around the given tables (4-byte aligned, checksums zero).
    static func sfnt(_ tables: [(String, [UInt8])]) -> FontBytes {
        var dir = be32(0x10000) + be16(tables.count) + [0, 0, 0, 0, 0, 0]
        var body: [UInt8] = []
        var offset = 12 + 16 * tables.count
        for (tag, data) in tables {
            dir += Array(tag.utf8) + be32(0) + be32(offset) + be32(data.count)
            let padded = data + [UInt8](repeating: 0, count: (4 - data.count % 4) % 4)
            body += padded; offset += padded.count
        }
        return FontBytes(b: dir + body)
    }

    /// COLR v0: glyph 10 = layers (3 red, 4 foreground); CPAL: one palette, red.
    static var colr: [UInt8] {
        be16(0) + be16(1) + be32(14) + be32(20) + be16(2)
            + be16(10) + be16(0) + be16(2)
            + be16(3) + be16(0) + be16(4) + be16(0xFFFF)
    }
    static var cpal: [UInt8] { be16(0) + be16(1) + be16(1) + be16(1) + be32(14) + be16(0) + [0, 0, 255, 255] }   // BGRA red

    /// GSUB feature ccmp -> lookup 0 (ligature 5 6 7 -> 10, 5 6 -> 9), lookup 1 (single 9 -> 11 by delta).
    static var gsub: [UInt8] {
        let liga: [UInt8] = be16(1) + be16(8) + be16(1) + be16(8 + 6 + 2)   // placeholder fixed below
        _ = liga
        // ligature subtable: format 1, coverage at 8, 1 set
        let coverage = be16(1) + be16(1) + be16(5)
        let lig3 = be16(10) + be16(3) + be16(6) + be16(7)
        let lig2 = be16(9) + be16(2) + be16(6)
        let set = be16(2) + be16(6) + be16(6 + lig3.count) + lig3 + lig2
        let sub0 = be16(1) + be16(8 + set.count) + be16(1) + be16(8) + set + coverage
        // single subtable format 1: coverage, delta 2 (9 -> 11)
        let sub1 = be16(1) + be16(6) + be16(2) + be16(1) + be16(1) + be16(9)
        let lookup0 = be16(4) + be16(0) + be16(1) + be16(8) + sub0
        let lookup1 = be16(1) + be16(0) + be16(1) + be16(8) + sub1
        let lookupList = be16(2) + be16(6) + be16(6 + lookup0.count) + lookup0 + lookup1
        let feature = be16(0) + be16(2) + be16(0) + be16(1)
        let featureList = be16(1) + Array("ccmp".utf8) + be16(8) + feature
        let header = be32(0x10000) + be16(10) + be16(10) + be16(10 + featureList.count)
        return header + featureList + lookupList
    }

    @Test func colorLayersAreReadWithTheirPaletteColors() throws {
        let b = Self.sfnt([("COLR", Self.colr), ("CPAL", Self.cpal)])
        let layers = try #require(ColorGlyphs(b, tables: b.tables())?.layers(of: 10))
        #expect(layers.map(\.glyph) == [3, 4])
        #expect(layers[0].color == RGBAColor(red: 1, green: 0, blue: 0, alpha: 1))
        #expect(layers[1].color == nil)
        #expect(ColorGlyphs(b, tables: b.tables())?.layers(of: 11) == nil)
    }

    @Test func ligaturesJoinTheLongestSequenceFirstAndLaterLookupsSeeTheResult() throws {
        let b = Self.sfnt([("GSUB", Self.gsub)])
        let sub = try #require(GlyphSubstitution(b, tables: b.tables()))
        #expect(sub.apply([5, 6, 7]) == [10])
        #expect(sub.apply([5, 6]) == [11])         // ligature 9, then the single lookup 9 -> 11
        #expect(sub.apply([1, 5, 6, 7, 2]) == [1, 10, 2])
        #expect(sub.apply([5, 7]) == [5, 7])
    }

    static func segoe() -> GlyphRasterFont? {
        let env = ProcessInfo.processInfo.environment
        let path = env["SQ_EMOJI_FONT"] ?? env["SystemRoot"].map { $0 + "\\Fonts\\seguiemj.ttf" }
        return path.flatMap { GlyphRasterFont(url: URL(fileURLWithPath: $0)) }
    }

    @Test func realEmojiFontJoinsSequencesIntoOneColorGlyph() throws {
        guard let font = Self.segoe() else { return }   // no Segoe UI Emoji on this machine (Mac): the synthetic tests cover the parsing
        let primary = try PortableFallbackTests.inter()
        let samples = ["\u{1F600}", "\u{1F44D}\u{1F3FD}", "\u{1F469}\u{200D}\u{1F4BB}", "\u{2764}\u{FE0F}", "1\u{FE0F}\u{20E3}"]
        for text in samples {
            let scalars = Array(text.unicodeScalars)
            let plan = PortableFallback.plan(scalars, primary: primary, fallbacks: [font])
            #expect(plan.filter { !$0.skip }.count == 1, "\(text.unicodeScalars.map { String($0.value, radix: 16) })")
            let pick = try #require(plan.first?.pick)
            #expect(pick.font != nil && pick.font! === font)
            #expect(font.face.colorGlyphs?.layers(of: pick.glyph)?.isEmpty == false, "no color layers for \(text.unicodeScalars.map { String($0.value, radix: 16) })")
        }
        // A ZWJ family is not a ligature in this font: the person glyphs are joined variants, the ZWJs vanish.
        let family = Array("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}".unicodeScalars)
        let plan = PortableFallback.plan(family, primary: primary, fallbacks: [font])
        #expect(plan.map(\.skip) == [false, false, false, false, true, true, true])
        #expect(plan[0].pick.glyph != font.glyph(for: "\u{1F468}"))
        // No person of the family may have a zero advance (they would stand on top of each other).
        #expect(plan.filter { !$0.skip }.allSatisfy { ($0.pick.advance ?? 0) > 0 })
    }

    @Test func colorEmojiIsDrawnInColorNotInTheTextColor() throws {
        guard let segoe = Self.segoe() else { return }
        let saved = PortableFallback.fonts
        PortableFallback.fonts = [segoe]
        defer { PortableFallback.fonts = saved }
        let style = TextStyle(fontName: InterFont.familyName, size: 80, color: .white)
        let raster = try #require(PortableTextRenderer.render(text: "\u{1F600}", style: style, maxWidth: nil))
        var colored = 0
        for i in stride(from: 0, to: raster.picture.pixels.count, by: 4) where raster.picture.pixels[i + 3] > 0.9 {
            let r = raster.picture.pixels[i], g = raster.picture.pixels[i + 1], bl = raster.picture.pixels[i + 2]
            if abs(r - bl) > 0.2 || abs(r - g) > 0.2 { colored += 1 }
        }
        #expect(colored > 200)
    }
}
