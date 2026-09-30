import Testing
import Foundation
import CoreText
@testable import SSText

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
}
