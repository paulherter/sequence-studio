import Foundation
import CoreText

/// Resolves a `TextStyle` (font name + weight) to a concrete Core Text font.
///
/// The style's weight always selects the face within the named font's family: the name picks the family,
/// `weight` picks the face (so "Helvetica-Bold" with `.regular` resolves to Helvetica Regular).
/// Order: variable-font weight axis / weight trait first, then the nearest available face of the family.
public enum FontResolver {
    /// Core Text weight trait (`kCTFontWeightTrait`, about -1...1) for a `FontWeight`.
    public static func traitValue(for weight: FontWeight) -> Double {
        switch weight {
        case .thin: -0.6
        case .light: -0.4
        case .regular: 0
        case .medium: 0.23
        case .semibold: 0.3
        case .bold: 0.4
        case .heavy: 0.56
        case .black: 0.62
        }
    }

    /// The weight trait of a font (`kCTFontWeightTrait`), 0 if unreported.
    public static func weightTrait(of font: CTFont) -> Double {
        let traits = CTFontCopyTraits(font) as NSDictionary
        return (traits[kCTFontWeightTrait as String] as? NSNumber)?.doubleValue ?? 0
    }

    /// Weight trait of the font the style resolves to.
    public static func resolvedWeightTrait(for style: TextStyle) -> Double {
        weightTrait(of: font(for: style))
    }

    public static func font(for style: TextStyle) -> CTFont {
        let size = CGFloat(style.size)
        let base = CTFontCreateWithName(style.fontName as CFString, size, nil)
        let target = traitValue(for: style.weight)

        var best = base
        var bestDist = abs(weightTrait(of: base) - target)
        func consider(_ f: CTFont) {
            let d = abs(weightTrait(of: f) - target)
            if d < bestDist - 1e-6 { best = f; bestDist = d }
        }

        // 1. Weight trait on the base descriptor (drives the variable weight axis of the system font).
        let traitAttrs = [kCTFontTraitsAttribute as String: [kCTFontWeightTrait as String: target]] as CFDictionary
        let viaTrait = CTFontCreateWithFontDescriptor(
            CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(base), traitAttrs), size, nil)
        consider(viaTrait)

        // 2. Nearest available face in the family (static families such as Helvetica).
        if bestDist > 0.05 {
            let family = CTFontCopyFamilyName(base)
            let query = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute as String: family] as CFDictionary)
            let members = (CTFontDescriptorCreateMatchingFontDescriptors(query, nil) as? [CTFontDescriptor]) ?? []
            let baseItalic = CTFontGetSymbolicTraits(base).contains(.italicTrait)
            for d in members {
                let f = CTFontCreateWithFontDescriptor(d, size, nil)
                guard CTFontGetSymbolicTraits(f).contains(.italicTrait) == baseItalic else { continue }
                consider(f)
            }
        }
        return best
    }
}
