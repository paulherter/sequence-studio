import Testing
import Foundation
import SQCore
@testable import SQText

@Suite struct GeneratedCaptionLooksTests {
    private let looks = GeneratedCaptionLooks.all

    @Test func sizeAndUniqueness() {
        #expect((30...80).contains(looks.count))
        #expect(Set(looks.map(\.id)).count == looks.count)
        #expect(Set(looks.map(\.title)).count == looks.count)
        let all = CaptionStyleLooks.all
        #expect(Set(all.map(\.id)).count == all.count, "ids unique across the whole gallery")
        #expect(looks.allSatisfy { $0.group == .collection })
    }

    @Test func noTitleFamilies() {
        // Captions are small text on the lower third: the big title families do not belong here.
        for l in looks { #expect(l.category != nil && l.category != .titles, "\(l.id)") }
    }

    @Test func refsResolveInTheBuiltInLibrary() {
        let lib = CaptionPresetLibrary.builtIn
        for l in looks {
            #expect(lib.hasStyle(l.styleRef), "\(l.styleRef)")
            #expect(lib.hasAnimation(l.animationRef), "\(l.animationRef)")
            #expect(BundledFonts.isBundled(lib.style(for: l.styleRef).fontName))
        }
    }

    @Test func stylesAreReadableAndTheHighlightToo() {
        let lib = CaptionPresetLibrary.builtIn
        for l in looks {
            let s = lib.style(for: l.styleRef)
            #expect(TextLookGenerator.readability(of: s) >= 4.5, "\(l.id)")
            if let k = l.karaoke {
                let lit = RGBAColor(red: k.red, green: k.green, blue: k.blue)
                // The lit word keeps its contrast against what carries the text, and differs from the unlit color.
                let backing = s.background.map { ColorContrast.composite($0.color, overGrey: 0.5) } ?? s.stroke?.color ?? s.shadow?.color ?? .black
                #expect(ColorContrast.ratio(lit, backing) >= 4.5, "\(l.id) highlight")
                #expect(abs(lit.red - s.color.red) + abs(lit.green - s.color.green) + abs(lit.blue - s.color.blue) >= 0.3, "\(l.id) highlight differs")
            }
        }
    }

    @Test func deterministicAndMatchable() {
        #expect(GeneratedCaptionLooks.all == looks)
        let l = looks[3]
        // Generated looks leave the gallery while the built-in switch is off; the styles still resolve by id.
        guard BuiltInTextLooks.isEnabled else {
            #expect(CaptionStyleLooks.look(id: l.id) == nil)
            #expect(CaptionPresetLibrary.builtIn.hasStyle(l.styleRef))
            return
        }
        #expect(CaptionStyleLooks.look(id: l.id) == l)
        #expect(CaptionStyleLooks.matching(styleRef: l.styleRef, animationRef: l.animationRef, karaoke: l.karaoke)?.styleRef == l.styleRef)
    }

    @Test func existingLibraryStylesStayUntouched() {
        let lib = CaptionPresetLibrary.builtIn
        for id in ["default", "classic", "bold-box", "outline", "title", "tiktok", "youtube", "pill", "ghost", "sticker", "neon"] {
            #expect(lib.hasStyle(id), "\(id)")
        }
    }
}
