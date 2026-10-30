#if canImport(CoreText)
import Testing
import Foundation
import CoreText
@testable import SQText

@Suite struct FontScopedCacheTests {
    func describe(_ f: CTFont) -> String {
        "\(CTFontCopyPostScriptName(f)) \(CTFontGetSize(f)) \(FontResolver.weightTrait(of: f))"
    }

    /// Inside the scope every style resolves to the same face as without it, and a repeat returns the cached font.
    @Test func scopedCacheResolvesLikeUncached() {
        let styles = [TextStyle(fontName: "Helvetica", size: 40, weight: .bold),
                      TextStyle(fontName: "Helvetica-Bold", size: 40, weight: .regular),
                      TextStyle(fontName: ".AppleSystemUIFont", size: 31.5, weight: .semibold),
                      TextStyle(fontName: "Inter", size: 73, weight: .heavy),
                      TextStyle(fontName: "NoSuchFont-Here", size: 12, weight: .light)]
        let plain = styles.map { describe(FontResolver.font(for: $0)) }
        FontResolver.withScopedCache {
            #expect(FontResolver.scopedCache != nil)
            let first = styles.map { FontResolver.font(for: $0) }
            #expect(first.map(describe) == plain)
            let a = styles.map { FontResolver.uprightFont(for: $0) }
            let b = styles.map { FontResolver.uprightFont(for: $0) }
            #expect(zip(a, b).allSatisfy { $0 === $1 })
        }
        #expect(FontResolver.scopedCache == nil)
    }

    /// A new size derives from the cached face and matches fresh resolution.
    @Test func newSizesMatchUncached() {
        let names: [(String, FontWeight)] = [("Helvetica", .bold), (".AppleSystemUIFont", .semibold), ("Inter", .heavy), ("Helvetica-Bold", .regular)]
        var styles: [TextStyle] = []
        for (n, w) in names { for sz in [12.0, 31.5, 48, 73.25, 120] { styles.append(TextStyle(fontName: n, size: sz, weight: w)) } }
        let plain = styles.map { describe(FontResolver.font(for: $0)) }
        let scoped = FontResolver.withScopedCache { styles.map { describe(FontResolver.font(for: $0)) } }
        #expect(scoped == plain)
    }
}
#endif
