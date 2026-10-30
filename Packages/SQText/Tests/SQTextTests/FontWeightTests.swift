#if canImport(CoreText)
import Testing
import Foundation
import CoreText
@testable import SQText

@Suite struct FontWeightTests {
    func trait(_ name: String, _ w: FontWeight) -> Double {
        FontResolver.resolvedWeightTrait(for: TextStyle(fontName: name, size: 40, weight: w))
    }

    @Test func traitValuesAreMonotonic() {
        let all: [FontWeight] = [.thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black]
        let v = all.map(FontResolver.traitValue(for:))
        #expect(zip(v, v.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test func systemFontGivesDistinctWeights() {
        let ws: [FontWeight] = [.thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black]
        let resolved = ws.map { trait(".AppleSystemUIFont", $0) }
        #expect(Set(resolved.map { ($0 * 1000).rounded() }).count >= 6, "\(resolved)")
        #expect(zip(resolved, resolved.dropFirst()).allSatisfy { $0 <= $1 + 1e-6 }, "\(resolved)")
        #expect(trait(".AppleSystemUIFont", .bold) > trait(".AppleSystemUIFont", .regular))
        #expect(trait(".AppleSystemUIFont", .thin) < trait(".AppleSystemUIFont", .regular))
    }

    @Test func resolvedWeightIsCloseToTargetOnSystemFont() {
        for w in [FontWeight.light, .regular, .bold] {
            #expect(abs(trait(".AppleSystemUIFont", w) - FontResolver.traitValue(for: w)) < 0.1)
        }
    }

    @Test func limitedFamilyFallsBackToNearestFace() {
        // Georgia ships Regular and Bold only: thin..medium must land on Regular, semibold..black on Bold.
        let regular = trait("Georgia", .regular), bold = trait("Georgia", .bold)
        #expect(bold > regular)
        #expect(trait("Georgia", .thin) == regular)
        #expect(trait("Georgia", .light) == regular)
        #expect(trait("Georgia", .black) == bold)
        #expect(trait("Georgia", .heavy) == bold)
        let f = FontResolver.font(for: TextStyle(fontName: "Georgia", size: 30, weight: .black))
        #expect(CTFontCopyFamilyName(f) as String == "Georgia")
    }

    @Test func layoutWidthGrowsWithWeight() {
        func width(_ w: FontWeight) -> Double {
            TextLayout.layout(text: "Weight matters", style: TextStyle(fontName: ".AppleSystemUIFont", size: 40, weight: w, alignment: .left), maxWidth: nil).bounds.width
        }
        #expect(width(.black) > width(.thin))
    }

    @Test func unknownFontStillResolves() {
        let f = FontResolver.font(for: TextStyle(fontName: "NoSuchFont-XYZ", size: 20, weight: .bold))
        #expect(CTFontGetSize(f) == 20)
    }

    // Explicit face / PostScript names win over the style weight; weight only applies to a bare family name.
    @Test func explicitFaceNameWinsOverWeight() {
        let regular = trait("Helvetica", .regular), bold = trait("Helvetica-Bold", .regular)
        #expect(bold > regular)
        #expect(trait("Helvetica-Bold", .thin) == bold)
        #expect(trait("Helvetica-Bold", .black) == bold)
        let f = FontResolver.font(for: TextStyle(fontName: "Helvetica-Bold", size: 30, weight: .regular))
        #expect(CTFontCopyPostScriptName(f) as String == "Helvetica-Bold")
        let l = FontResolver.font(for: TextStyle(fontName: "Helvetica-Light", size: 30, weight: .black))
        #expect(CTFontCopyPostScriptName(l) as String == "Helvetica-Light")
    }

    @Test func familyNameWithWeightResolvesThatWeight() {
        let f = FontResolver.font(for: TextStyle(fontName: "Helvetica", size: 30, weight: .bold))
        #expect(CTFontCopyPostScriptName(f) as String == "Helvetica-Bold")
        let r = FontResolver.font(for: TextStyle(fontName: "Helvetica", size: 30, weight: .regular))
        #expect(CTFontCopyPostScriptName(r) as String == "Helvetica")
        // Family name is matched case-insensitively.
        #expect(trait("helvetica", .bold) == trait("Helvetica-Bold", .regular))
    }

    @Test func explicitFaceOfOtherFamiliesAlsoWins() {
        #expect(trait("Georgia-Bold", .thin) == trait("Georgia", .bold))
        #expect(trait("Georgia", .thin) == trait("Georgia", .regular))
    }
}
#endif
