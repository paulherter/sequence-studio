#if canImport(CoreText)
import CoreText
import Foundation
import Testing
@testable import SQText

@Suite struct BundledFontsTests {
    @Test func catalogHasAboutTwentyFiveUniqueFamilies() {
        let names = BundledFonts.families.map(\.name)
        #expect(names.count >= 25)
        #expect(Set(names).count == names.count)
        #expect(BundledFonts.pickerNames.first == "Inter")
        #expect(BundledFonts.isBundled("Anton") && !BundledFonts.isBundled("Helvetica"))
    }

    @Test func everyFamilyShipsFilesAndAnOFLLicence() throws {
        for fam in BundledFonts.families {
            #expect(BundledFonts.fontURLs(of: fam).count == fam.files.count, "files of \(fam.name)")
            let url = try #require(BundledFonts.licenseURL(of: fam), "license of \(fam.name)")
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text.uppercased().contains("OPEN FONT LICENSE"), "\(fam.name) license is not OFL")
            #expect(text.contains("Copyright"), "\(fam.name) license lacks a copyright line")
        }
    }

    @Test func registerFindsAllFiles() { #expect(BundledFonts.register()) }

    @Test func everyFamilyResolvesToItself() {
        for fam in BundledFonts.families {
            let f = FontResolver.font(for: TextStyle(fontName: fam.name, size: 48, weight: .regular))
            #expect((CTFontCopyFamilyName(f) as String) == fam.name, "\(fam.name) resolved to \(CTFontCopyFamilyName(f))")
        }
    }

    @Test func variableFamilyFollowsWeight() {
        func trait(_ w: FontWeight) -> Double {
            FontResolver.weightTrait(of: FontResolver.font(for: TextStyle(fontName: "Montserrat", size: 48, weight: w)))
        }
        #expect(trait(.black) > trait(.regular) + 0.2)
    }

    @Test func staticFamilyPicksNearestBundledFace() {
        let bold = FontResolver.font(for: TextStyle(fontName: "Poppins", size: 48, weight: .bold))
        #expect((CTFontCopyPostScriptName(bold) as String) == "Poppins-Bold")
        let heavy = FontResolver.font(for: TextStyle(fontName: "Poppins", size: 48, weight: .black))
        #expect((CTFontCopyPostScriptName(heavy) as String) == "Poppins-ExtraBold")
    }

    @Test func singleWeightFamilyStillResolvesWithBoldAndItalic() {
        var s = TextStyle(fontName: "Bebas Neue", size: 48, weight: .bold)
        s.italic = true
        let f = FontResolver.font(for: s)
        #expect((CTFontCopyFamilyName(f) as String) == "Bebas Neue")
    }
}
#endif
