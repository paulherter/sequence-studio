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

/// Base writing direction of a paragraph. `TextStyle.direction == nil` is automatic: the first strong character decides.
public enum TextDirection: String, Sendable, Hashable, Codable {
    case leftToRight, rightToLeft

    /// Whether a paragraph is laid out right to left: the override, else the first strong character (Hebrew, Arabic,
    /// Syriac, Thaana, N'Ko and their presentation forms are right to left; any other letter is left to right).
    public static func isRightToLeft(_ paragraph: String, override: TextDirection?) -> Bool {
        if let o = override { return o == .rightToLeft }
        for u in paragraph.unicodeScalars {
            if isStrongRTL(u.value) { return true }
            if u.properties.isAlphabetic { return false }
        }
        return false
    }

    private static func isStrongRTL(_ v: UInt32) -> Bool {
        switch v {
        case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF: return true
        default: return false
        }
    }
}

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

/// Where the stroke sits on the glyph outline. `width` is the visible thickness either way.
public enum StrokePosition: String, Sendable, Hashable, Codable {
    /// Outside the glyphs: the fill stays whole, the ink grows by the width (the default, and what older files mean).
    case outside
    /// Centered on the outline, drawn over the fill: half of it eats into the glyph, the ink grows by half the width.
    case centre
}

/// Footage fill: the glyphs take their look from the picture below the text clip instead of a color.
public enum TextFootageFill: String, Sendable, Hashable, Codable {
    /// The glyphs are a window onto what is below: it shows only inside them, the rest of the frame is cleared.
    case stencil
    /// The glyphs invert what is below them.
    case inverted
}

public struct TextStroke: Sendable, Hashable, Codable {
    public var color: RGBAColor
    public var width: Double
    public var position: StrokePosition
    public init(color: RGBAColor, width: Double, position: StrokePosition = .outside) {
        self.color = color; self.width = max(0, width); self.position = position
    }

    private enum CodingKeys: String, CodingKey { case color, width, position }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init(color: try c.decode(RGBAColor.self, forKey: .color), width: try c.decode(Double.self, forKey: .width),
                  position: try c.decodeIfPresent(StrokePosition.self, forKey: .position) ?? .outside)
    }

    /// How far the stroke reaches beyond the glyph outline.
    public var reach: Double { position == .outside ? width : width / 2 }
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
    /// Premiere's shadow "Size": the glyph shape grows by this many px (layout space) before the blur, so thin glyphs still
    /// cast a dense shadow. 0 = off (projects saved before it existed decode as 0).
    public var spread: Double = 0 { didSet { if spread < 0 { spread = 0 } } }
    private enum CodingKeys: String, CodingKey { case color, offsetX, offsetY, blur, restingAngle, spread }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        color = try c.decode(RGBAColor.self, forKey: .color)
        offsetX = try c.decode(Double.self, forKey: .offsetX)
        offsetY = try c.decode(Double.self, forKey: .offsetY)
        blur = try c.decode(Double.self, forKey: .blur)
        restingAngle = try c.decodeIfPresent(Double.self, forKey: .restingAngle)
        spread = max(0, try c.decodeIfPresent(Double.self, forKey: .spread) ?? 0)
    }
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
    /// Shadow opacity = alpha of the color.
    public var opacity: Double { color.alpha }
}

/// List marker put in front of every non-empty paragraph (nil = plain text, every older file).
public enum TextListKind: String, Sendable, Hashable, Codable {
    case bullet, numbered

    /// The marker of the `number`-th (1-based) non-empty paragraph, with its trailing gap.
    public func marker(_ number: Int) -> String {
        switch self {
        case .bullet: return "\u{2022} "
        case .numbered: return "\(number). "
        }
    }
}

/// Two-color linear gradient that fills the glyphs instead of `TextStyle.color`. `angle` is in degrees, 0 = start at the
/// left and end at the right, 90 = start at the top and end at the bottom (y down).
public struct TextGradient: Sendable, Hashable, Codable {
    public var start: RGBAColor
    public var end: RGBAColor
    public var angle: Double
    public init(start: RGBAColor, end: RGBAColor, angle: Double = 90) {
        self.start = start; self.end = end; self.angle = angle
    }

    /// Start and end points of the gradient axis across `rect` (layout space): the axis runs through the center and
    /// spans the rect's extent along the angle, so corners take the pure end colors.
    public func axis(in rect: TextRect) -> (start: (x: Double, y: Double), end: (x: Double, y: Double)) {
        let a = angle * .pi / 180
        let dx = cos(a), dy = sin(a)
        let half = (abs(rect.width * dx) + abs(rect.height * dy)) / 2
        let cx = rect.x + rect.width / 2, cy = rect.y + rect.height / 2
        return ((cx - dx * half, cy - dy * half), (cx + dx * half, cy + dy * half))
    }
}

/// The look of the second line of a two-style text (N4: small top line over a big bottom line). Only the glyph look
/// changes; stroke, shadow, background, alignment, tracking and line spacing stay block-wide (the clip style).
public struct TextLineStyle: Sendable, Hashable, Codable {
    public var fontName: String
    public var size: Double
    public var weight: FontWeight
    public var color: RGBAColor
    public var italic: Bool

    public init(fontName: String, size: Double, weight: FontWeight, color: RGBAColor, italic: Bool = false) {
        self.fontName = fontName; self.size = max(1, size); self.weight = weight; self.color = color; self.italic = italic
    }

    /// The glyph look of `style` (a fresh second line starts as the first one).
    public init(from style: TextStyle) {
        self.init(fontName: style.fontName, size: style.size, weight: style.weight, color: style.color, italic: style.italic)
    }

    private enum CodingKeys: String, CodingKey { case fontName, size, weight, color, italic }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init(fontName: try c.decode(String.self, forKey: .fontName), size: try c.decode(Double.self, forKey: .size),
                  weight: try c.decode(FontWeight.self, forKey: .weight), color: try c.decode(RGBAColor.self, forKey: .color),
                  italic: try c.decodeIfPresent(Bool.self, forKey: .italic) ?? false)
    }
}

public struct TextStyle: Sendable, Hashable, Codable {
    /// Font of new text and captions: bundled Inter (`InterFont`). Saved styles keep the font they were saved with.
    public static let defaultFontName = InterFont.familyName
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
    /// All caps: the glyphs are drawn in capitals, the stored text stays as typed.
    public var allCaps: Bool
    /// Line styles: a bar under the baseline, through the x-height and over the capitals, drawn in the fill color across
    /// each line (`TextDecorations`). Block-wide; older files decode as off.
    public var underline: Bool
    public var strikethrough: Bool
    public var overline: Bool
    /// Two-style text: every paragraph after the first is drawn in this look. Nil = one style (all older files).
    public var secondLine: TextLineStyle?
    /// W8.3: fields bound to the project's style kit tokens (see `resolved(in:)`). Nil = every field is a literal.
    public var tokens: TextStyleTokens?
    /// Footage fill (nil = the `color` fills the glyphs, every older file). Drawn as a white glyph without outline, shadow
    /// or background (`drawn`); the compositor turns it into a stencil or an inversion.
    public var footageFill: TextFootageFill?
    /// Base writing direction; nil = automatic per paragraph (every older file). Alignment stays physical
    /// (left/center/right), the direction changes how mixed-direction runs order and where punctuation sits.
    public var direction: TextDirection?
    /// Variable-font axis values by four-letter tag ("wght", "wdth", "opsz", "slnt"). Nil = no axis set (every older
    /// file): the discrete `weight` picks the face. A value wins over `weight` for its axis and is clamped to the
    /// font's range; tags the font lacks are ignored. Animate by interpolating (`interpolateAxes`). Optional JSON key.
    public var fontAxes: [String: Double]?
    /// Shrink to box: in an area text box the glyphs scale down until the block fits the box (never up). Nil/false = off.
    public var autoFit: Bool?
    /// Bullets or numbers in front of every non-empty paragraph. Nil = plain.
    public var list: TextListKind?
    /// Gradient fill of the glyphs (nil = the solid `color`). Karaoke highlights and footage fills win over it.
    public var gradient: TextGradient?
    /// Per-paragraph looks: paragraph `i` is drawn in `lineStyles[i]`; paragraphs past the list fall back to
    /// `secondLine`, then the clip style. Nil = none (every older file).
    public var lineStyles: [TextLineStyle]?

    public init(fontName: String = TextStyle.defaultFontName, size: Double = 48, weight: FontWeight = .regular,
                color: RGBAColor = .white, stroke: TextStroke? = nil, background: TextBackground? = nil,
                shadow: TextShadow? = nil, alignment: TextAlignment = .center, lineSpacing: Double = 0,
                tracking: Double = 0, italic: Bool = false, verticalAlignment: TextVerticalAlignment = .top,
                allCaps: Bool = false, secondLine: TextLineStyle? = nil, tokens: TextStyleTokens? = nil,
                underline: Bool = false, strikethrough: Bool = false, overline: Bool = false,
                footageFill: TextFootageFill? = nil, direction: TextDirection? = nil,
                fontAxes: [String: Double]? = nil, autoFit: Bool? = nil, list: TextListKind? = nil,
                gradient: TextGradient? = nil, lineStyles: [TextLineStyle]? = nil) {
        self.autoFit = autoFit; self.list = list; self.gradient = gradient; self.lineStyles = lineStyles
        self.footageFill = footageFill; self.direction = direction; self.fontAxes = fontAxes
        self.fontName = fontName; self.size = max(1, size); self.weight = weight; self.color = color
        self.stroke = stroke; self.background = background; self.shadow = shadow
        self.alignment = alignment; self.lineSpacing = lineSpacing
        self.tracking = tracking; self.italic = italic; self.verticalAlignment = verticalAlignment
        self.allCaps = allCaps; self.secondLine = secondLine; self.tokens = tokens
        self.underline = underline; self.strikethrough = strikethrough; self.overline = overline
    }

    /// The style the raster is drawn in: the style itself, or for a footage fill the plain glyph without outline, shadow
    /// and background (the picture below supplies the look). A stencil keeps the fill color at full opacity (only the
    /// glyph's coverage matters to the stencil, and a transition side that draws it plain shows the title's own color);
    /// an inverted fill is white, which Difference turns into the negative.
    public var drawn: TextStyle {
        guard let fill = footageFill else { return self }
        var s = self
        s.color = TextStyle.footageColor(color, fill); s.stroke = nil; s.shadow = nil; s.background = nil
        if let second = s.secondLine?.color { s.secondLine?.color = TextStyle.footageColor(second, fill) }
        s.gradient = nil
        s.lineStyles = s.lineStyles?.map { var l = $0; l.color = TextStyle.footageColor(l.color, fill); return l }
        return s
    }

    /// `highlight` (karaoke) in the look of `drawn`.
    public func drawn(highlight: TextHighlight?) -> TextHighlight? {
        guard let fill = footageFill, var h = highlight else { return highlight }
        h.color = TextStyle.footageColor(h.color, fill)
        return h
    }

    private static func footageColor(_ c: RGBAColor, _ fill: TextFootageFill) -> RGBAColor {
        switch fill {
        case .inverted: return .white
        case .stencil: return RGBAColor(red: c.red, green: c.green, blue: c.blue)
        }
    }

    /// The style line group `index` is drawn in: 0 = the first paragraph (this style), 1 = every later paragraph (the
    /// `secondLine` look over this style's block-wide values). Both come back without a `secondLine`.
    public func lineStyle(_ index: Int) -> TextStyle {
        var s = self
        s.secondLine = nil; s.lineStyles = nil
        let l: TextLineStyle
        if let own = lineStyles, own.indices.contains(index) { l = own[index] }
        else if index > 0, let second = secondLine { l = second }
        else { return s }
        s.fontName = l.fontName; s.size = l.size; s.weight = l.weight; s.color = l.color; s.italic = l.italic
        return s
    }

    /// How many distinct paragraph looks the layout needs: 1 plain, 2 with a second line; per-paragraph styles add the
    /// looks of the list plus one for the paragraphs after it.
    public var lineStyleCount: Int {
        guard let own = lineStyles else { return secondLine == nil ? 1 : 2 }
        return max(own.count, secondLine == nil ? 1 : 2) + 1
    }

    /// Whether paragraphs differ in look (the fill pass then colors every line itself).
    public var hasLineLooks: Bool { lineStyleCount > 1 }

    private enum CodingKeys: String, CodingKey {
        case fontName, size, weight, color, stroke, background, shadow, alignment, lineSpacing
        case tracking, italic, verticalAlignment, allCaps, secondLine, tokens, underline, strikethrough, overline, footageFill, direction, fontAxes
        case autoFit, list, gradient, lineStyles
    }

    /// Axis values between `a` and `b` at `t` (0...1), per tag; a tag set on one side only keeps that value.
    public static func interpolateAxes(_ a: [String: Double]?, _ b: [String: Double]?, t: Double) -> [String: Double]? {
        guard a != nil || b != nil else { return nil }
        var out: [String: Double] = [:]
        for k in Set(a?.keys.map { $0 } ?? []).union(b?.keys.map { $0 } ?? []) {
            switch (a?[k], b?[k]) {
            case let (x?, y?): out[k] = x + (y - x) * t
            case let (x?, nil): out[k] = x
            case let (nil, y?): out[k] = y
            default: break
            }
        }
        return out
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
                  verticalAlignment: try c.decodeIfPresent(TextVerticalAlignment.self, forKey: .verticalAlignment) ?? .top,
                  allCaps: try c.decodeIfPresent(Bool.self, forKey: .allCaps) ?? false,
                  secondLine: try c.decodeIfPresent(TextLineStyle.self, forKey: .secondLine),
                  tokens: try c.decodeIfPresent(TextStyleTokens.self, forKey: .tokens),
                  underline: try c.decodeIfPresent(Bool.self, forKey: .underline) ?? false,
                  strikethrough: try c.decodeIfPresent(Bool.self, forKey: .strikethrough) ?? false,
                  overline: try c.decodeIfPresent(Bool.self, forKey: .overline) ?? false,
                  footageFill: try c.decodeIfPresent(TextFootageFill.self, forKey: .footageFill),
                  direction: try c.decodeIfPresent(TextDirection.self, forKey: .direction),
                  fontAxes: try c.decodeIfPresent([String: Double].self, forKey: .fontAxes),
                  autoFit: try c.decodeIfPresent(Bool.self, forKey: .autoFit),
                  list: try c.decodeIfPresent(TextListKind.self, forKey: .list),
                  gradient: try c.decodeIfPresent(TextGradient.self, forKey: .gradient),
                  lineStyles: try c.decodeIfPresent([TextLineStyle].self, forKey: .lineStyles))
    }
}
