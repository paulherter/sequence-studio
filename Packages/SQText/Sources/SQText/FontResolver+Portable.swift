#if !canImport(CoreText)
import Foundation

// Font resolution without a platform font manager: the bundled families only (Inter plus BundledFonts), looked up by
// family name or file name, as Core Text picks them (`PortableFontMatch`: named instance nearest the weight, italic file,
// optical size from the point size, style axes).
// shortcut: no system fonts. Upgrade with DirectWrite font enumeration (the Windows port plan "Seam 2 status").
extension FontResolver {
    public static func weightTrait(of font: PlatformFont) -> Double { font.choice.weightTrait }

    public static func axes(forFontName name: String) -> [Axis] { PortableFontMatch.axes(forFontName: name) }
    public static func axes(of font: PlatformFont) -> [Axis] {
        (font.face.variations?.axes ?? []).map { Axis(tag: $0.tag, name: $0.tag, minimum: $0.minimum, maximum: $0.maximum,
                                                     defaultValue: $0.defaultValue) }
    }

    static func resolveFont(for style: TextStyle) -> PlatformFont {
        _ = InterFont.register()
        guard let choice = PortableFontMatch.choose(name: style.fontName, weight: style.weight, italic: style.italic,
                                                    size: style.size, axes: style.fontAxes) else {
            preconditionFailure("bundled Inter font missing")
        }
        return PortableFont(choice: choice, size: style.size)
    }
}

extension FontResolver.Memo {
    func installFontChangeObservers() {}   // no system font manager to listen to
}
#endif
