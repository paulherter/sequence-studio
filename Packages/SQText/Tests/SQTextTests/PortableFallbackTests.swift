import Foundation
import Testing
@testable import SQText

@Suite struct PortableFallbackTests {
    static func inter() throws -> GlyphRasterFont {
        try #require(PortableFontMatch.choose(name: InterFont.familyName, weight: .regular, italic: false, size: 20, axes: nil)).font
    }

    @Test func joinersWithoutAnyFallbackAreDropped() throws {
        // a thumbs up with skin tone and VS16 with no fallback face: the modifiers have no glyph and take no room
        let s = Array("\u{1F44D}\u{1F3FD}\u{FE0F}".unicodeScalars)
        let plan = PortableFallback.plan(s, primary: try Self.inter(), fallbacks: [])
        #expect(plan.map(\.skip) == [false, true, true])
    }

    @Test func missingGlyphGoesToTheFirstFallbackThatHasIt() throws {
        let primary = try Self.inter()
        let scalar: Unicode.Scalar = "\u{4E2D}"
        #expect(primary.glyph(for: scalar) == 0)
        let other = BundledFonts.families.flatMap { BundledFonts.fontURLs(of: $0) }.compactMap { GlyphRasterFont(url: $0) }
            .first { $0.glyph(for: scalar) != 0 }
        guard let other else {   // no bundled face covers it: without a fallback the box stays
            #expect(PortableFallback.plan([scalar], primary: primary, fallbacks: []).first?.pick.glyph == 0)
            return
        }
        let pick = PortableFallback.plan([scalar], primary: primary, fallbacks: [other])[0].pick
        #expect(pick.font === other && pick.glyph != 0)
    }

    @Test func spacesStayOnThePrimaryFace() throws {
        let plan = PortableFallback.plan([" ", "A"], primary: try Self.inter(), fallbacks: [])
        #expect(plan.allSatisfy { $0.pick.font == nil && !$0.skip })
    }

    #if os(Windows)
    @Test func emojiGetsAGlyphFromSegoeUIEmoji() throws {
        let plan = PortableFallback.plan(["\u{1F600}"], primary: try Self.inter())
        let pick = try #require(plan.first?.pick)
        #expect(pick.font != nil && pick.glyph != 0)
        let font = try #require(pick.font)
        #expect(!font.contours(glyph: pick.glyph).isEmpty)
    }
    #endif
}
