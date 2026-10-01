import Foundation
import CoreText

/// Resolves a `TextStyle` (font name + weight) to a concrete Core Text font.
///
/// An explicit face name (PostScript or full name that differs from the family name, e.g. "Helvetica-Bold")
/// wins: the style's weight is ignored. Only a bare family name ("Helvetica", ".AppleSystemUIFont") lets
/// `weight` pick the face. Unknown names fall back to Core Text's substitute and are treated as family names.
/// Order (family mode): variable-font weight axis / weight trait first, then the nearest available face of the family.
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
        let upright = uprightFont(for: style)
        guard style.italic else { return upright }
        return italicVersion(of: upright)
    }

    /// The italic face of the same family when there is one, else the upright face sheared by 12 degrees (synthetic oblique).
    static func italicVersion(of font: CTFont) -> CTFont {
        if CTFontGetSymbolicTraits(font).contains(.italicTrait) { return font }
        let size = CTFontGetSize(font)
        if let it = CTFontCreateCopyWithSymbolicTraits(font, size, nil, .italicTrait, .italicTrait),
           CTFontGetSymbolicTraits(it).contains(.italicTrait) { return it }
        var shear = CGAffineTransform(a: 1, b: 0, c: CGFloat(tan(12.0 * Double.pi / 180)), d: 1, tx: 0, ty: 0)
        return CTFontCreateCopyWithAttributes(font, size, &shear, nil)
    }

    static func uprightFont(for style: TextStyle) -> CTFont {
        let size = CGFloat(style.size)
        let base = CTFontCreateWithName(style.fontName as CFString, size, nil)
        if isExplicitFace(style.fontName, resolved: base) { return base }
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

    /// True if `name` denotes one specific face: it matches the resolved font's PostScript or full name
    /// (case-insensitive) and is not just the family name (for Helvetica Regular all three coincide: family wins).
    static func isExplicitFace(_ name: String, resolved font: CTFont) -> Bool {
        let n = name.lowercased()
        let family = (CTFontCopyFamilyName(font) as String).lowercased()
        if n == family { return false }
        let ps = (CTFontCopyPostScriptName(font) as String).lowercased()
        let full = (CTFontCopyFullName(font) as String).lowercased()
        return n == ps || n == full
    }
}
