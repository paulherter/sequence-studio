#if canImport(CoreText)
import CoreText
import Foundation
import Testing
@testable import SQText

@Suite struct FontAxisTests {
    func inter(_ axes: [String: Double]?, weight: FontWeight = .regular) -> TextStyle {
        InterFont.register()
        var s = TextStyle(fontName: "Inter", size: 40, weight: weight)
        s.fontAxes = axes
        return s
    }

    @Test func interExposesWeightAxis() {
        InterFont.register()
        let axes = FontResolver.axes(forFontName: "Inter")
        let w = axes.first { $0.tag == "wght" }
        #expect(w != nil)
        #expect((w?.minimum ?? 0) <= 100 + 1e-6)
        #expect((w?.maximum ?? 0) >= 900 - 1e-6)
        #expect(FontResolver.axes(forFontName: "Georgia").isEmpty)
    }

    @Test func weightAxisValueChangesTheFont() {
        let light = FontResolver.weightTrait(of: FontResolver.font(for: inter(["wght": 200])))
        let heavy = FontResolver.weightTrait(of: FontResolver.font(for: inter(["wght": 900])))
        #expect(heavy > light + 0.2)
        // Axis values win over the discrete weight.
        let overridden = FontResolver.weightTrait(of: FontResolver.font(for: inter(["wght": 900], weight: .thin)))
        #expect(abs(overridden - heavy) < 1e-6)
    }

    @Test func valuesBetweenStepsGiveBetweenWidths() {
        func width(_ w: Double) -> Double {
            TextLayout.layout(text: "Variable weight", style: inter(["wght": w]), maxWidth: nil).bounds.width
        }
        #expect(width(300) < width(500))
        #expect(width(500) < width(800))
    }

    @Test func outOfRangeValuesClampAndUnknownAxesAreIgnored() {
        let top = FontResolver.weightTrait(of: FontResolver.font(for: inter(["wght": 900])))
        let beyond = FontResolver.weightTrait(of: FontResolver.font(for: inter(["wght": 5000])))
        #expect(abs(top - beyond) < 1e-6)
        let plain = FontResolver.font(for: inter(nil))
        let unknown = FontResolver.font(for: inter(["zzzz": 3]))
        #expect(CTFontCopyPostScriptName(plain) as String == CTFontCopyPostScriptName(unknown) as String)
        #expect(FontResolver.weightTrait(of: plain) == FontResolver.weightTrait(of: unknown))
    }

    @Test func styleWithAxesIsDistinctAndCodableWithOptionalField() throws {
        var s = TextStyle()
        let plain = try JSONEncoder().encode(s)
        #expect(!String(decoding: plain, as: UTF8.self).contains("fontAxes"))
        #expect(try JSONDecoder().decode(TextStyle.self, from: plain).fontAxes == nil)
        s.fontAxes = ["wght": 640, "opsz": 20]
        #expect(s != TextStyle())
        let back = try JSONDecoder().decode(TextStyle.self, from: JSONEncoder().encode(s))
        #expect(back.fontAxes == ["wght": 640, "opsz": 20])
    }

    @Test func memoDoesNotMixAxisValues() {
        let a = FontResolver.weightTrait(of: FontResolver.font(for: inter(["wght": 250])))
        let b = FontResolver.weightTrait(of: FontResolver.font(for: inter(["wght": 850])))
        let a2 = FontResolver.weightTrait(of: FontResolver.font(for: inter(["wght": 250])))
        #expect(a != b)
        #expect(a == a2)
    }

    @Test func interpolatesAxisValues() {
        let a: [String: Double] = ["wght": 200]
        let b: [String: Double] = ["wght": 800, "opsz": 30]
        let mid = TextStyle.interpolateAxes(a, b, t: 0.5)
        #expect(mid?["wght"] == 500)
        #expect(mid?["opsz"] == 30)
        #expect(TextStyle.interpolateAxes(nil, nil, t: 0.5) == nil)
        #expect(TextStyle.interpolateAxes(a, b, t: 0) == ["wght": 200, "opsz": 30])
    }
}
#endif
