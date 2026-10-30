#if canImport(AppKit)
import AppKit
import Foundation
import Testing
import SQText
@testable import SQDrawKit

/// The shared UI's system font measures like AppKit's `Theme.Typography.ns` fonts (`monospacedDigitSystemFont`): kerning,
/// `trak` tracking and tabular digits give the same widths per size and weight, within the whole-pixel rounding of a line.
@MainActor @Suite struct MacFontParityTests {
    @Test func linesMeasureLikeAppKit() throws {
        let atlas = try #require(GlyphAtlas(font: GlyphRasterFont.macSystemUI ?? .inter))
        atlas.pointScale = 1
        let strings = ["Create Captions", "Replace Transcript", "Save as Preset", "Cancel", "Sequence 01 Clip Name 0123456789",
                       "00:01:23:12", "Auto-detect language (English)"]
        let weights: [(NSFont.Weight, Int)] = [(.regular, 0), (.medium, atlas.mediumFace), (.semibold, atlas.semiboldFace)]
        for (weight, face) in weights {
            for size in [10.0, 11, 12, 13, 15] {
                let ns = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
                for s in strings {
                    let expected = (s as NSString).size(withAttributes: [.font: ns]).width
                    let got = CGFloat(atlas.width(of: s, pixelSize: Float(size), face: face))
                    #expect(abs(got - expected) <= 1.01, "\(s) \(weight.rawValue) \(size): AppKit \(expected), shared \(got)")
                }
            }
        }
    }

    @Test func tabularDigitsHaveOneWidth() throws {
        let atlas = try #require(GlyphAtlas(font: GlyphRasterFont.macSystemUI ?? .inter))
        let one = atlas.width(of: "1111", pixelSize: 26), eight = atlas.width(of: "8888", pixelSize: 26)
        #expect(one == eight)
    }
}
#endif
