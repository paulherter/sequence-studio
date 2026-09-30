import Foundation

/// sRGB color with components clamped to 0...1.
public struct RGBAColor: Sendable, Hashable, Codable {
    public let red: Double, green: Double, blue: Double, alpha: Double
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        func c(_ v: Double) -> Double { min(1, max(0, v)) }
        self.red = c(red); self.green = c(green); self.blue = c(blue); self.alpha = c(alpha)
    }
    public static let white = RGBAColor(red: 1, green: 1, blue: 1)
    public static let black = RGBAColor(red: 0, green: 0, blue: 0)
    public static let clear = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0)
}

public enum FontWeight: Int, Sendable, Hashable, Codable, Comparable {
    case thin = 100, light = 300, regular = 400, medium = 500, semibold = 600, bold = 700, heavy = 800, black = 900
    public static func < (a: FontWeight, b: FontWeight) -> Bool { a.rawValue < b.rawValue }
}

public enum TextAlignment: String, Sendable, Hashable, Codable { case left, center, right }

public struct BoxPadding: Sendable, Hashable, Codable {
    public let horizontal: Double, vertical: Double
    public init(horizontal: Double, vertical: Double) {
        self.horizontal = max(0, horizontal); self.vertical = max(0, vertical)
    }
    public static let zero = BoxPadding(horizontal: 0, vertical: 0)
}

public struct TextStroke: Sendable, Hashable, Codable {
    public var color: RGBAColor
    public var width: Double
    public init(color: RGBAColor, width: Double) { self.color = color; self.width = max(0, width) }
}

public struct TextBackground: Sendable, Hashable, Codable {
    public var color: RGBAColor
    public var padding: BoxPadding
    public var cornerRadius: Double
    public init(color: RGBAColor, padding: BoxPadding = .zero, cornerRadius: Double = 0) {
        self.color = color; self.padding = padding; self.cornerRadius = max(0, cornerRadius)
    }
}

public struct TextShadow: Sendable, Hashable, Codable {
    public var color: RGBAColor
    public var offsetX: Double, offsetY: Double, blur: Double
    public init(color: RGBAColor, offsetX: Double, offsetY: Double, blur: Double) {
        self.color = color; self.offsetX = offsetX; self.offsetY = offsetY; self.blur = max(0, blur)
    }
}

public struct TextStyle: Sendable, Hashable, Codable {
    /// PostScript name (e.g. "Helvetica-Bold") or family name; resolved by the layout/renderer.
    public var fontName: String
    public var size: Double
    public var weight: FontWeight
    public var color: RGBAColor
    public var stroke: TextStroke?
    public var background: TextBackground?
    public var shadow: TextShadow?
    public var alignment: TextAlignment
    /// Extra spacing between lines in points (added to the font's natural leading).
    public var lineSpacing: Double

    public init(fontName: String = "Helvetica", size: Double = 48, weight: FontWeight = .regular,
                color: RGBAColor = .white, stroke: TextStroke? = nil, background: TextBackground? = nil,
                shadow: TextShadow? = nil, alignment: TextAlignment = .center, lineSpacing: Double = 0) {
        self.fontName = fontName; self.size = max(1, size); self.weight = weight; self.color = color
        self.stroke = stroke; self.background = background; self.shadow = shadow
        self.alignment = alignment; self.lineSpacing = lineSpacing
    }
}
