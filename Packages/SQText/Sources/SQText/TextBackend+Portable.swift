#if !canImport(CoreText)
import Foundation

// Portable text backend (Windows, Linux): measuring and Latin-grade layout from the font files themselves, no platform
// text engine. A small TrueType/OpenType reader supplies advance widths and vertical metrics.
// Variable-font instances and GPOS pair kerning as the raster draws them (`PortableFontMatch`, `PairKerning`).
// shortcut: no ligatures, bidi or complex scripts, no font fallback. Upgrade path: HarfBuzz for shaping
// (the Windows port plan "Seam 2 status").

/// A font face at a size, read straight from a .ttf/.otf file, at one point of its variation space.
public final class PortableFont: @unchecked Sendable {
    let choice: PortableFontChoice
    let size: Double
    var face: SfntFace { choice.face }
    var coords: [Double] { choice.coords }
    init(choice: PortableFontChoice, size: Double) { self.choice = choice; self.size = size }
    var scale: Double { size / Double(face.unitsPerEm) }
    var metrics: TextFontMetrics {
        TextFontMetrics(ascent: Double(face.ascender) * scale, descent: -Double(face.descender) * scale,
                        leading: Double(face.lineGap) * scale)
    }
    func glyph(_ scalar: Unicode.Scalar) -> Int { face.glyph(for: scalar) }
    func advance(glyph g: Int) -> Double { face.advance(glyph: g, coords: coords) * scale }
    func kern(_ a: Int, _ b: Int) -> Double { face.kern(a, b, coords: coords) * scale }
}

public typealias PlatformFont = PortableFont

/// Line widths from per-scalar advances, pair kerning and tracking after every glyph (as the Core Text kern attribute does).
private struct PortableLines: LineTypesetting {
    let prefix: [Double]            // prefix[i] = width of the first i UTF-16 units
    let whitespace: [Bool]          // per UTF-16 unit
    let metrics: TextFontMetrics

    init(_ para: String, font: PortableFont, tracking: Double) {
        let units = Array(para.utf16)
        var p = [0.0], ws = [Bool]()
        p.reserveCapacity(units.count + 1); ws.reserveCapacity(units.count)
        var total = 0.0
        var i = 0
        var previous: Int?
        while i < units.count {
            let n = UTF16.isLeadSurrogate(units[i]) && i + 1 < units.count ? 2 : 1
            let scalar = n == 2
                ? UnicodeScalar(0x10000 + (UInt32(units[i]) - 0xD800) << 10 + (UInt32(units[i + 1]) - 0xDC00)) ?? "\u{FFFD}"
                : UnicodeScalar(UInt32(units[i])) ?? "\u{FFFD}"
            let g = font.glyph(scalar)
            if let p = previous { total += font.kern(p, g) }
            total += font.advance(glyph: g) + tracking
            previous = g
            let isSpace = scalar.properties.isWhitespace
            for k in 0..<n { p.append(k == n - 1 ? total : p.last!); ws.append(isSpace) }
            i += n
        }
        prefix = p; whitespace = ws; metrics = font.metrics
    }

    func line(location: Int, length: Int) -> TextLineMetrics {
        let a = min(max(0, location), prefix.count - 1), b = min(max(a, location + length), prefix.count - 1)
        var t = b
        while t > a, whitespace[t - 1] { t -= 1 }
        return TextLineMetrics(width: prefix[b] - prefix[a], trailingWhitespace: prefix[b] - prefix[t],
                               ascent: metrics.ascent, descent: metrics.descent, leading: metrics.leading)
    }
}

extension TextLayout {
    static func fontMetrics(_ font: PlatformFont) -> TextFontMetrics { font.metrics }

    static func typesetter(_ para: String, font: PlatformFont, tracking: Double, rightToLeft: Bool?) -> any LineTypesetting {
        PortableLines(para, font: font, tracking: tracking)
    }
}

/// Portable fonts are read from the bundled files on demand; there is nothing to register with the system.
@discardableResult
func registerFontFile(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

func isInstalled(family: String) -> Bool { false }
#endif
