#if canImport(CoreText)
import Foundation
import CoreText

extension FontResolver {
    /// The weight trait of a font (`kCTFontWeightTrait`), 0 if unreported.
    public static func weightTrait(of font: CTFont) -> Double {
        let traits = CTFontCopyTraits(font) as NSDictionary
        return (traits[kCTFontWeightTrait as String] as? NSNumber)?.doubleValue ?? 0
    }


    static func resolveFont(for style: TextStyle) -> CTFont {
        let upright = uprightFont(for: style)
        let face = style.italic ? italicVersion(of: upright) : upright
        guard let axes = style.fontAxes, !axes.isEmpty else { return face }
        return applying(axes: axes, to: face)
    }


    /// The variation axes of the font a name resolves to (empty for a static font), in the font's axis order.
    public static func axes(forFontName name: String) -> [Axis] {
        InterFont.register()
        return axes(of: CTFontCreateWithName(name as CFString, 12, nil))
    }

    public static func axes(of font: CTFont) -> [Axis] {
        guard let list = CTFontCopyVariationAxes(font) as? [[String: Any]] else { return [] }
        return list.compactMap { d in
            guard let id = (d[kCTFontVariationAxisIdentifierKey as String] as? NSNumber)?.uint32Value,
                  let lo = (d[kCTFontVariationAxisMinimumValueKey as String] as? NSNumber)?.doubleValue,
                  let hi = (d[kCTFontVariationAxisMaximumValueKey as String] as? NSNumber)?.doubleValue else { return nil }
            let def = (d[kCTFontVariationAxisDefaultValueKey as String] as? NSNumber)?.doubleValue ?? lo
            let name = d[kCTFontVariationAxisNameKey as String] as? String ?? ""
            return Axis(tag: tag(of: id), name: name, minimum: lo, maximum: hi, defaultValue: def)
        }
    }


    /// `font` with the axis values set (clamped to each axis range); tags the font does not have are dropped.
    static func applying(axes values: [String: Double], to font: CTFont) -> CTFont {
        let available = axes(of: font)
        guard !available.isEmpty else { return font }
        var variation: [NSNumber: NSNumber] = [:]
        for a in available {
            guard let v = values[a.tag], v.isFinite, let id = identifier(of: a.tag) else { continue }
            variation[NSNumber(value: id)] = NSNumber(value: min(max(v, a.minimum), a.maximum))
        }
        guard !variation.isEmpty else { return font }
        let desc = CTFontDescriptorCreateCopyWithAttributes(
            CTFontCopyFontDescriptor(font), [kCTFontVariationAttribute as String: variation] as CFDictionary)
        return CTFontCreateWithFontDescriptor(desc, CTFontGetSize(font), nil)
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
        guard let cache = scopedCache else { return resolveUprightFont(for: style) }
        InterFont.register()
        return cache.font(.init(name: style.fontName, size: style.size, weight: style.weight)) {
            let fk = ScopedCache.FaceKey(name: style.fontName, weight: style.weight)
            if let face = cache.face(fk) {
                return CTFontCreateCopyWithAttributes(face, CGFloat(style.size), nil, nil)
            }
            let f = resolveUprightFont(for: style)
            cache.setFace(fk, f)
            return f
        }
    }

    static func resolveUprightFont(for style: TextStyle) -> CTFont {
        let size = CGFloat(style.size)
        InterFont.register()
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

extension FontResolver.Memo {
    func installFontChangeObservers() {
                    // Lives as long as the process, like the memo itself.
                    let name = NSNotification.Name(kCTFontManagerRegisteredFontsChangedNotification as String)
                    _ = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in FontResolver.fontsChanged() }
                    // The local center only hears fonts this process registers; a font installed for the user or the session
                    // (Font Book, another app) is announced on the distributed center.
                    _ = DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: nil) { _ in
                        FontResolver.fontsChanged()
                    }
    }
}
#endif
