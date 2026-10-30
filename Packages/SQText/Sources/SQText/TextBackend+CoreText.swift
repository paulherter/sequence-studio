#if canImport(CoreText)
import Foundation
import CoreText

public typealias PlatformFont = CTFont

extension TextLayout {
    static func fontMetrics(_ font: PlatformFont) -> TextFontMetrics {
        TextFontMetrics(ascent: CTFontGetAscent(font), descent: CTFontGetDescent(font), leading: CTFontGetLeading(font))
    }

    static func typesetter(_ para: String, font: PlatformFont, tracking: Double, rightToLeft: Bool?) -> any LineTypesetting {
        let attr = NSAttributedString(string: para, attributes: attributes(font: font, tracking: tracking, rightToLeft: rightToLeft))
        return CoreTextLines(ts: CTTypesetterCreateWithAttributedString(attr))
    }

    /// Core Text attributes of a line. `rightToLeft` pins the paragraph's base direction (nil = Core Text decides from
    /// the line's own first strong character, which is wrong for a wrapped line that starts with a Latin word).
    static func attributes(font: CTFont, tracking: Double, rightToLeft: Bool? = nil) -> [NSAttributedString.Key: Any] {
        var a: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        if tracking != 0 { a[NSAttributedString.Key(kCTKernAttributeName as String)] = tracking }
        if let rtl = rightToLeft {
            var dir: CTWritingDirection = rtl ? .rightToLeft : .leftToRight
            let setting = withUnsafeMutablePointer(to: &dir) {
                CTParagraphStyleSetting(spec: .baseWritingDirection, valueSize: MemoryLayout<CTWritingDirection>.size, value: $0)
            }
            a[NSAttributedString.Key(kCTParagraphStyleAttributeName as String)] = CTParagraphStyleCreate([setting], 1)
        }
        return a
    }

}

private struct CoreTextLines: LineTypesetting {
    let ts: CTTypesetter
    func line(location: Int, length: Int) -> TextLineMetrics {
        let line = CTTypesetterCreateLine(ts, CFRange(location: location, length: length))
        var a: CGFloat = 0, d: CGFloat = 0, l: CGFloat = 0
        let full = CTLineGetTypographicBounds(line, &a, &d, &l)
        return TextLineMetrics(width: full, trailingWhitespace: CTLineGetTrailingWhitespaceWidth(line),
                               ascent: a, descent: d, leading: l)
    }
}
/// Registers a font file for this process; false if it reports an error (an installed font stays usable).
@discardableResult
func registerFontFile(_ url: URL) -> Bool {
    var err: Unmanaged<CFError>?
    return CTFontManagerRegisterFontsForURL(url as CFURL, .process, &err)
}

func isInstalled(family: String) -> Bool {
    let d = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute as String: family] as CFDictionary)
    return CTFontDescriptorCreateMatchingFontDescriptors(d, nil) != nil
}
#endif
