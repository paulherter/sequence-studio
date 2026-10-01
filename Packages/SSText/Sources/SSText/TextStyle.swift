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

/// Vertical placement of the text inside an area text box (point text has no box height, so it never applies).
public enum TextVerticalAlignment: String, Sendable, Hashable, Codable { case top, middle, bottom }

/// Area text box in sequence pixels. `width` makes the text wrap; `height` gives the vertical alignment room.
public struct TextBox: Sendable, Hashable, Codable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = max(1, width); self.height = max(1, height) }
}

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
    /// Offset in layout space (sequence pixels, y down): positive `offsetY` moves the shadow down.
    public var offsetX: Double, offsetY: Double, blur: Double
    /// The light angle remembered while the distance is 0 (the offset alone cannot carry it); nil = never set.
    public var restingAngle: Double?
    public init(color: RGBAColor, offsetX: Double, offsetY: Double, blur: Double) {
        self.color = color; self.offsetX = offsetX; self.offsetY = offsetY; self.blur = max(0, blur)
    }

    /// Photoshop/Premiere convention: `angle` is the light direction in degrees (0 = from the right, counter-clockwise),
    /// so 135 casts the shadow down and to the right.
    public init(color: RGBAColor, angle: Double, distance: Double, blur: Double) {
        let a = angle * .pi / 180
        self.init(color: color, offsetX: -cos(a) * distance, offsetY: sin(a) * distance, blur: blur)
        var n = angle.truncatingRemainder(dividingBy: 360)
        if n < 0 { n += 360 }
        restingAngle = n
    }
    /// Light angle in degrees, 0..<360 (135 when there is no offset).
    public var angle: Double {
        guard distance > 1e-9 else { return restingAngle ?? 135 }
        var d = atan2(offsetY, -offsetX) * 180 / .pi
        if d < 0 { d += 360 }
        return d
    }
    public var distance: Double { (offsetX * offsetX + offsetY * offsetY).squareRoot() }
    /// Shadow opacity = alpha of the colour.
    public var opacity: Double { color.alpha }
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
    /// Extra space after every character in points (Premiere "Tracking"); negative tightens.
    public var tracking: Double
    public var italic: Bool
    /// Only used for area text (a box with a height).
    public var verticalAlignment: TextVerticalAlignment

    public init(fontName: String = "Helvetica", size: Double = 48, weight: FontWeight = .regular,
                color: RGBAColor = .white, stroke: TextStroke? = nil, background: TextBackground? = nil,
                shadow: TextShadow? = nil, alignment: TextAlignment = .center, lineSpacing: Double = 0,
                tracking: Double = 0, italic: Bool = false, verticalAlignment: TextVerticalAlignment = .top) {
        self.fontName = fontName; self.size = max(1, size); self.weight = weight; self.color = color
        self.stroke = stroke; self.background = background; self.shadow = shadow
        self.alignment = alignment; self.lineSpacing = lineSpacing
        self.tracking = tracking; self.italic = italic; self.verticalAlignment = verticalAlignment
    }

    private enum CodingKeys: String, CodingKey {
        case fontName, size, weight, color, stroke, background, shadow, alignment, lineSpacing
        case tracking, italic, verticalAlignment
    }

    /// Older files lack the newer keys: they read as 0 / false / top.
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init(fontName: try c.decode(String.self, forKey: .fontName),
                  size: try c.decode(Double.self, forKey: .size),
                  weight: try c.decode(FontWeight.self, forKey: .weight),
                  color: try c.decode(RGBAColor.self, forKey: .color),
                  stroke: try c.decodeIfPresent(TextStroke.self, forKey: .stroke),
                  background: try c.decodeIfPresent(TextBackground.self, forKey: .background),
                  shadow: try c.decodeIfPresent(TextShadow.self, forKey: .shadow),
                  alignment: try c.decode(TextAlignment.self, forKey: .alignment),
                  lineSpacing: try c.decode(Double.self, forKey: .lineSpacing),
                  tracking: try c.decodeIfPresent(Double.self, forKey: .tracking) ?? 0,
                  italic: try c.decodeIfPresent(Bool.self, forKey: .italic) ?? false,
                  verticalAlignment: try c.decodeIfPresent(TextVerticalAlignment.self, forKey: .verticalAlignment) ?? .top)
    }
}
