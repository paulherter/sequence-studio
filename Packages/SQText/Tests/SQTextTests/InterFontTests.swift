#if canImport(CoreText)
import CoreText
import Foundation
import Testing
@testable import SQText

@Suite struct InterFontTests {
    @Test func bundledFilesAndLicenceShip() {
        #expect(InterFont.fontURLs.count == 2)
        #expect(InterFont.licenseURL != nil)
        if let u = InterFont.licenseURL, let s = try? String(contentsOf: u, encoding: .utf8) {
            #expect(s.contains("SIL OPEN FONT LICENSE Version 1.1"))
        }
    }

    @Test func registersAndResolvesAsInter() {
        #expect(InterFont.register())
        let f = FontResolver.font(for: TextStyle(fontName: "Inter", size: 40, weight: .regular))
        #expect((CTFontCopyFamilyName(f) as String) == "Inter")
    }

    @Test func weightAxisIsUsed() {
        InterFont.register()
        let regular = FontResolver.weightTrait(of: FontResolver.font(for: TextStyle(fontName: "Inter", size: 40, weight: .regular)))
        let bold = FontResolver.weightTrait(of: FontResolver.font(for: TextStyle(fontName: "Inter", size: 40, weight: .bold)))
        #expect(bold > regular + 0.1)
    }

    @Test func italicUsesTheItalicFile() {
        InterFont.register()
        var s = TextStyle(fontName: "Inter", size: 40, weight: .regular)
        s.italic = true
        let f = FontResolver.font(for: s)
        #expect(CTFontGetSymbolicTraits(f).contains(.italicTrait))
        #expect((CTFontCopyFamilyName(f) as String) == "Inter")
    }

    @Test func newTextDefaultsToInterButSavedStylesKeepTheirFont() throws {
        #expect(TextStyle().fontName == "Inter")
        #expect(CaptionPresetLibrary.base.style(for: nil).fontName == "Inter")
        var old = TextStyle(fontName: "Helvetica", size: 50)
        old.fontName = "Helvetica"
        let back = try JSONDecoder().decode(TextStyle.self, from: JSONEncoder().encode(old))
        #expect(back.fontName == "Helvetica")
    }
}
#endif
