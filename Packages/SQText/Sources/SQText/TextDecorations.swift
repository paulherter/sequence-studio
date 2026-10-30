import Foundation
#if canImport(CoreText)
import CoreText
#endif

/// Underline, strikethrough and overline: bars drawn across the text line in the glyph fill, in layout space (sequence
/// pixels, y down). One pure function feeds the plain renderer and the per-character animator renderer, so the monitor
/// and the export draw the same bars.
public enum TextDecorations {
    public enum Kind: String, Sendable, Hashable, CaseIterable { case underline, strikethrough, overline }

    /// One bar over the whole width of a line. `rect` spans `TextLine.x ... x + width`.
    public struct Bar: Sendable, Hashable {
        public let kind: Kind
        public let lineIndex: Int
        /// Which look the line is drawn in (`TextLine.styleIndex`).
        public let styleIndex: Int
        public let rect: TextRect
    }

    /// Which kinds `style` switches on, in drawing order.
    public static func kinds(of style: TextStyle) -> [Kind] {
        var k: [Kind] = []
        if style.underline { k.append(.underline) }
        if style.strikethrough { k.append(.strikethrough) }
        if style.overline { k.append(.overline) }
        return k
    }

    /// The bars of every non-empty line of `layout`; empty when the style has no decoration.
    public static func bars(layout: TextLayoutResult, style: TextStyle) -> [Bar] {
        let kinds = kinds(of: style)
        guard !kinds.isEmpty else { return [] }
        var fonts: [Int: Metrics] = [:]
        var out: [Bar] = []
        for (i, l) in layout.lines.enumerated() where !l.text.isEmpty && l.width > 0 {
            let m = fonts[l.styleIndex] ?? { let f = metrics(style.lineStyle(l.styleIndex)); fonts[l.styleIndex] = f; return f }()
            let size = m.size
            let thickness = max(1, m.underlineThickness, size * 0.045)
            let base = l.y + l.baseline
            for k in kinds {
                // Font metrics are y up from the baseline; `center` is converted to layout y (down).
                let center: Double
                switch k {
                case .underline: center = base - m.underlinePosition
                case .strikethrough: center = base - max(m.xHeight, size * 0.3) * 0.5
                case .overline: center = base - m.capHeight - thickness
                }
                out.append(Bar(kind: k, lineIndex: i, styleIndex: l.styleIndex,
                               rect: TextRect(x: l.x, y: center - thickness / 2, width: l.width, height: thickness)))
            }
        }
        return out
    }

    /// The font numbers the bars need, in layout px, y up from the baseline.
    struct Metrics { let size, underlinePosition, underlineThickness, xHeight, capHeight: Double }

    static func metrics(_ style: TextStyle) -> Metrics {
        #if canImport(CoreText)
        let font = TextLayout.makeFont(style)
        return Metrics(size: CTFontGetSize(font), underlinePosition: CTFontGetUnderlinePosition(font),
                       underlineThickness: CTFontGetUnderlineThickness(font), xHeight: CTFontGetXHeight(font),
                       capHeight: CTFontGetCapHeight(font))
        #else
        let font = TextLayout.makeFont(style), f = font.face, k = font.scale
        // A font without OS/2 v2 heights: Core Text's own estimates (x 0.5 em, caps 0.7 em).
        return Metrics(size: font.size, underlinePosition: Double(f.underlinePosition) * k,
                       underlineThickness: Double(f.underlineThickness) * k,
                       xHeight: f.xHeight > 0 ? Double(f.xHeight) * k : font.size * 0.5,
                       capHeight: f.capHeight > 0 ? Double(f.capHeight) * k : font.size * 0.7)
        #endif
    }
}
