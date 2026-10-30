import Testing
import Foundation
import SQCore
@testable import SQText

@Suite struct TextLookGeneratorTests {
    private let all = TextLookGenerator.all

    @Test func contrastMaths() {
        #expect(abs(ColorContrast.ratio(.black, .white) - 21) < 0.01)
        #expect(abs(ColorContrast.ratio(.white, .white) - 1) < 0.001)
    }

    @Test func sizeIdsAndNames() {
        #expect((150...300).contains(all.count))
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(Set(all.map { $0.look.name }).count == all.count)
        // The whole catalog stays unique with the hand-made looks and the motions.
        let ids = TextPresetCatalog.looks.map(\.id) + TextPresetCatalog.motions.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func ownVocabularyNames() {
        let banned = ["premiere", "capcut", "adobe", "tiktok", "youtube", "mogrt", "final cut", "resolve", "canva", "alight"]
        for g in all {
            let n = g.look.name.lowercased()
            for b in banned { #expect(!n.contains(b), "\(g.look.name)") }
        }
    }

    @Test func everyCategoryHasLooks() {
        for c in TextPresetCategory.allCases { #expect(all.filter { $0.look.category == c }.count >= 20, "\(c)") }
    }

    @Test func deterministic() {
        #expect(TextLookGenerator.looks == TextLookGenerator.all.map(\.look))
        // The table is rebuilt from the same inputs: the first and last entries are pinned.
        #expect(all.first?.id == "gen-outline-stack-saffron")
        #expect(all.last?.id == "gen-monument-sand")
    }

    @Test func allBundledFontsAreUsed() {
        let used = Set(all.map { $0.look.style.fontName })
        for f in BundledFonts.families { #expect(used.contains(f.name), "\(f.name) unused") }
        for u in used { #expect(BundledFonts.isBundled(u), "\(u)") }
    }

    @Test func fontsNeverRepeatWithinAFamily() {
        for fam in TextLookGenerator.families {
            #expect(fam.fonts.count >= TextLookGenerator.palettes.count, "\(fam.id)")
            let fonts = all.filter { $0.look.id.hasPrefix("gen-\(fam.id)-") }.map { $0.look.style.fontName }
            #expect(Set(fonts).count == fonts.count, "\(fam.id)")
        }
    }

    @Test func staticFontsKeepRegularWeight() {
        for g in all where ["Anton", "Bebas Neue", "Bangers", "Pacifico"].contains(g.look.style.fontName) {
            #expect(g.look.style.weight == .regular, "\(g.id)")
        }
    }

    @Test func paletteInvariants() {
        for p in TextLookGenerator.palettes {
            #expect(ColorContrast.ratio(p.fill, p.ink) >= 4.5, "\(p.name) fill")
            #expect(ColorContrast.ratio(p.accent, p.ink) >= 4.5, "\(p.name) accent")
            #expect(ColorContrast.ratio(p.paper, p.ink) >= 10, "\(p.name) paper")
        }
        #expect(Set(TextLookGenerator.palettes.map(\.name)).count == TextLookGenerator.palettes.count)
    }

    /// WCAG-ish: text against what carries it (box, stroke or dense shadow) is at least 4.5:1 for every look; every palette
    /// and every font appears, so this covers every palette/font pair that ships.
    @Test func everyLookIsReadable() {
        for g in all {
            let r = TextLookGenerator.readability(of: g.look.style)
            #expect(r >= 4.5, "\(g.id) \(g.look.style.fontName): \(r)")
            #expect(g.look.style.size >= 40)
        }
    }

    @Test func glowAndShadowAccentsDoNotCarryTheText() {
        // A look whose only backing is a shadow must have a dense one (alpha >= 0.5); none of ours rely on the accent alone.
        for g in all where g.look.style.stroke == nil && g.look.style.background == nil {
            #expect((g.look.style.shadow?.color.alpha ?? 0) >= 0.5, "\(g.id)")
        }
    }

    /// Curation: no two looks are near-identical.
    @Test func noNearDuplicates() {
        func d(_ a: RGBAColor, _ b: RGBAColor) -> Double {
            ((a.red - b.red) * (a.red - b.red) + (a.green - b.green) * (a.green - b.green) + (a.blue - b.blue) * (a.blue - b.blue)).squareRoot()
        }
        func distance(_ x: TextStyle, _ y: TextStyle) -> Double {
            var s = d(x.color, y.color)
            s += d(x.stroke?.color ?? .clear, y.stroke?.color ?? .clear)
            s += d(x.background?.color ?? .clear, y.background?.color ?? .clear)
            s += d(x.shadow?.color ?? .clear, y.shadow?.color ?? .clear) * 0.5
            if x.fontName != y.fontName { s += 0.6 }
            if (x.stroke == nil) != (y.stroke == nil) { s += 0.6 }
            if (x.background == nil) != (y.background == nil) { s += 0.6 }
            if x.allCaps != y.allCaps { s += 0.3 }
            if x.italic != y.italic { s += 0.3 }
            if x.alignment != y.alignment { s += 0.3 }
            s += abs(x.size - y.size) / 40 + abs(x.tracking - y.tracking) / 10
            s += abs((x.stroke?.width ?? 0) - (y.stroke?.width ?? 0)) / 8
            s += abs((x.background?.cornerRadius ?? 0) - (y.background?.cornerRadius ?? 0)) / 20
            return s
        }
        let styles = all.map { ($0.id, $0.look.style) } + TextPresetCatalog.handmade.map { ($0.id, $0.style) }
        var close: [String] = []
        for i in 0..<styles.count {
            for j in (i + 1)..<styles.count {
                let v = distance(styles[i].1, styles[j].1)
                if v < 0.45 { close.append("\(styles[i].0) ~ \(styles[j].0): \(v)") }
            }
        }
        #expect(close.isEmpty, "\(close.count) near-duplicates, e.g. \(close.prefix(12))")
    }

    @Test func suggestedMotionsExistAndFitTheCategory() {
        for g in all {
            let id = try! #require(g.look.suggestedMotionID, "\(g.id)")
            let m = try! #require(TextPresetCatalog.motions.first { $0.id == id }, "\(id)")
            #expect(m.category == g.look.category && m.animationIn != nil)
        }
        // Every in-motion of a category is suggested somewhere (the animation presets are all reachable).
        for c in TextPresetCategory.allCases {
            let ins = Set(TextPresetCatalog.motions(in: c).filter { $0.animationIn != nil }.map(\.id))
            let used = Set(all.filter { $0.look.category == c }.compactMap(\.look.suggestedMotionID))
            #expect(used == ins, "\(c)")
        }
    }

    @Test func lookIsFoundByPasteboardID() {
        let g = all[40]
        #expect(TextPresetCatalog.look(id: TextPresetCatalog.lookID(g.look)) == g.look)
    }
}
