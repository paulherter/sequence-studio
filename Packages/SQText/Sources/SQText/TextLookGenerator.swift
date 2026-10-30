import Foundation
import SQCore

/// WCAG relative luminance and contrast ratio (sRGB). Used by the look generator and its tests.
public enum ColorContrast {
    public static func luminance(_ c: RGBAColor) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.red) + 0.7152 * lin(c.green) + 0.0722 * lin(c.blue)
    }
    /// 1...21; opaque colors.
    public static func ratio(_ a: RGBAColor, _ b: RGBAColor) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
    /// `c` laid over an opaque gray `level` (0 black ... 1 white).
    public static func composite(_ c: RGBAColor, overGrey level: Double) -> RGBAColor {
        RGBAColor(red: c.red * c.alpha + level * (1 - c.alpha), green: c.green * c.alpha + level * (1 - c.alpha),
                  blue: c.blue * c.alpha + level * (1 - c.alpha))
    }
}

/// Four related colors: a bright main color, a second bright accent, a very dark tinted ink and a tinted off-white.
/// Every look is built from one palette, so the dark ink against any of the three light colors always reads.
public struct LookPalette: Sendable, Hashable, Identifiable {
    public var id: String, name: String
    public var fill: RGBAColor, accent: RGBAColor, ink: RGBAColor, paper: RGBAColor
    init(_ id: String, _ name: String, fill: (Double, Double, Double), accent: (Double, Double, Double),
         ink: (Double, Double, Double), paper: (Double, Double, Double)) {
        self.id = id; self.name = name
        self.fill = RGBAColor(red: fill.0, green: fill.1, blue: fill.2)
        self.accent = RGBAColor(red: accent.0, green: accent.1, blue: accent.2)
        self.ink = RGBAColor(red: ink.0, green: ink.1, blue: ink.2)
        self.paper = RGBAColor(red: paper.0, green: paper.1, blue: paper.2)
    }
}

/// A generated look with its origin.
public struct GeneratedTextLook: Sendable, Hashable, Identifiable {
    public var look: TextLook
    public var family: String
    public var palette: String
    public var id: String { look.id }
}

/// Parametric title/caption look generator: 15 families x 12 palettes, each family rotating through its own pool of
/// bundled OFL fonts, each look paired with a motion of its category (`TextLook.suggestedMotionID`). Pure and
/// deterministic (no randomness, no clock): the same table on every run, so tests can pin it. Names are our own:
/// palette word + family noun.
public enum TextLookGenerator {
    // MARK: Palettes

    public static let palettes: [LookPalette] = [
        LookPalette("saffron", "Saffron", fill: (1, 0.80, 0.10), accent: (1, 0.55, 0.15), ink: (0.12, 0.08, 0.02), paper: (1, 0.97, 0.88)),
        LookPalette("coral", "Coral", fill: (1, 0.42, 0.38), accent: (1, 0.75, 0.30), ink: (0.16, 0.04, 0.05), paper: (1, 0.94, 0.92)),
        LookPalette("lagoon", "Lagoon", fill: (0.10, 0.85, 0.85), accent: (0.30, 0.60, 1), ink: (0.02, 0.10, 0.14), paper: (0.90, 1, 1)),
        LookPalette("moss", "Moss", fill: (0.60, 0.85, 0.20), accent: (0.20, 0.75, 0.40), ink: (0.05, 0.10, 0.03), paper: (0.95, 1, 0.90)),
        LookPalette("orchid", "Orchid", fill: (0.85, 0.45, 1), accent: (1, 0.40, 0.75), ink: (0.10, 0.03, 0.15), paper: (0.97, 0.92, 1)),
        LookPalette("cobalt", "Cobalt", fill: (0.30, 0.55, 1), accent: (0.50, 0.90, 1), ink: (0.02, 0.04, 0.16), paper: (0.92, 0.95, 1)),
        LookPalette("ember", "Ember", fill: (1, 0.35, 0.10), accent: (1, 0.78, 0.20), ink: (0.15, 0.03, 0), paper: (1, 0.93, 0.86)),
        LookPalette("slate", "Slate", fill: (0.62, 0.70, 0.80), accent: (0.85, 0.90, 0.95), ink: (0.07, 0.09, 0.12), paper: (0.94, 0.96, 0.98)),
        LookPalette("ivory", "Ivory", fill: (0.96, 0.93, 0.82), accent: (0.85, 0.70, 0.40), ink: (0.10, 0.08, 0.05), paper: (1, 0.99, 0.96)),
        LookPalette("mint", "Mint", fill: (0.55, 1, 0.80), accent: (0.30, 0.90, 0.60), ink: (0.02, 0.12, 0.08), paper: (0.93, 1, 0.97)),
        LookPalette("plum", "Plum", fill: (0.90, 0.35, 0.60), accent: (0.70, 0.40, 1), ink: (0.12, 0.02, 0.08), paper: (1, 0.92, 0.96)),
        LookPalette("sand", "Sand", fill: (0.90, 0.70, 0.45), accent: (0.75, 0.50, 0.30), ink: (0.12, 0.07, 0.03), paper: (0.99, 0.95, 0.90)),
    ]

    // MARK: Fonts

    /// Faces that exist in one weight only (static families); everything else is a variable font that takes any weight.
    private static let staticFonts: Set<String> = [
        "Bebas Neue", "Anton", "Archivo Black", "Passion One", "Russo One", "Lilita One", "Righteous", "DM Serif Display",
        "Pacifico", "Lobster", "Knewave", "Bangers", "Bungee", "Bowlby One", "Sigmar One",
    ]

    /// The weight `font` can actually draw closest to `wanted`.
    static func weight(_ font: String, _ wanted: FontWeight) -> FontWeight {
        if staticFonts.contains(font) { return .regular }
        if font == "Poppins" { return wanted >= .heavy ? .heavy : wanted >= .bold ? .bold : .medium }
        return wanted
    }

    // MARK: Families

    struct Family: Sendable {
        var id: String, noun: String
        var category: TextPresetCategory
        var fonts: [String]
        var build: @Sendable (_ p: LookPalette, _ font: String) -> TextStyle
    }

    private static func shadow(_ c: RGBAColor, _ a: Double, _ dist: Double, _ blur: Double, angle: Double = 135) -> TextShadow {
        TextShadow(color: RGBAColor(red: c.red, green: c.green, blue: c.blue, alpha: a), angle: angle, distance: dist, blur: blur)
    }

    private static func dim(_ c: RGBAColor, _ a: Double) -> RGBAColor { RGBAColor(red: c.red, green: c.green, blue: c.blue, alpha: a) }

    // Every pool holds at least as many faces as there are palettes, so no two looks of a family share a font.
    static let heavyFonts = ["Anton", "Bebas Neue", "Passion One", "Russo One", "Archivo Black", "League Spartan", "Lilita One",
                             "Bangers", "Bungee", "Bowlby One", "Sigmar One", "Oswald", "Righteous", "Knewave"]
    static let boldFonts = ["Montserrat", "Rubik", "Poppins", "Archivo Black", "League Spartan", "Outfit", "Anton", "Lilita One",
                            "Space Grotesk", "Fredoka", "Oswald", "Russo One", "Righteous"]
    static let cleanFonts = ["Montserrat", "Poppins", "Rubik", "Space Grotesk", "Outfit", "Inter", "Fredoka", "League Spartan",
                             "Oswald", "Righteous", "Playfair Display", "DM Serif Display"]
    static let serifFonts = ["Playfair Display", "DM Serif Display", "Caveat", "Lobster", "Pacifico", "Montserrat", "Poppins",
                             "Outfit", "Space Grotesk", "Rubik", "Inter", "Fredoka"]
    static let displayFonts = ["DM Serif Display", "Playfair Display", "Bowlby One", "Archivo Black", "Righteous", "Sigmar One",
                               "Bungee", "Anton", "Passion One", "Lobster", "Pacifico", "Bebas Neue", "Oswald"]

    static let families: [Family] = [
        // TikTok
        Family(id: "outline-stack", noun: "Outliner", category: .tiktok,
               fonts: boldFonts) { p, f in
            TextStyle(fontName: f, size: 76, weight: weight(f, .black), color: p.paper, stroke: TextStroke(color: p.ink, width: 11),
                      shadow: shadow(p.ink, 0.55, 3, 8), lineSpacing: 2)
        },
        Family(id: "burst", noun: "Burst", category: .tiktok,
               fonts: heavyFonts) { p, f in
            TextStyle(fontName: f, size: 84, weight: weight(f, .bold), color: p.fill, stroke: TextStroke(color: p.ink, width: 10),
                      shadow: shadow(p.ink, 0.65, 4, 0), tracking: 1, allCaps: true)
        },
        Family(id: "marker", noun: "Marker", category: .tiktok,
               fonts: heavyFonts) { p, f in
            TextStyle(fontName: f, size: 64, weight: weight(f, .black), color: p.ink,
                      background: TextBackground(color: p.fill, padding: BoxPadding(horizontal: 22, vertical: 10), cornerRadius: 14),
                      allCaps: true)
        },
        Family(id: "sticker", noun: "Sticker", category: .tiktok,
               fonts: heavyFonts) { p, f in
            TextStyle(fontName: f, size: 58, weight: weight(f, .heavy), color: p.ink,
                      background: TextBackground(color: p.paper, padding: BoxPadding(horizontal: 20, vertical: 9), cornerRadius: 22),
                      shadow: shadow(p.accent, 1, 7, 0, angle: 315))
        },
        Family(id: "glow", noun: "Glow", category: .tiktok,
               fonts: heavyFonts) { p, f in
            TextStyle(fontName: f, size: 62, weight: weight(f, .heavy), color: p.paper, stroke: TextStroke(color: p.ink, width: 5),
                      shadow: shadow(p.accent, 0.85, 0, 18, angle: 90), tracking: 2)
        },
        Family(id: "splash", noun: "Splash", category: .tiktok,
               fonts: heavyFonts) { p, f in
            TextStyle(fontName: f, size: 88, weight: weight(f, .regular), color: p.paper,
                      stroke: TextStroke(color: p.ink, width: 8, position: .centre),
                      shadow: shadow(p.accent, 1, 7, 0), tracking: 2)
        },
        // YouTube
        Family(id: "shout", noun: "Shout", category: .youtube,
               fonts: heavyFonts) { p, f in
            TextStyle(fontName: f, size: 86, weight: weight(f, .black), color: p.fill, stroke: TextStroke(color: p.ink, width: 9),
                      shadow: shadow(p.ink, 0.8, 6, 0))
        },
        Family(id: "banner", noun: "Banner", category: .youtube,
               fonts: heavyFonts) { p, f in
            TextStyle(fontName: f, size: 76, weight: weight(f, .bold), color: p.ink,
                      background: TextBackground(color: p.accent, padding: BoxPadding(horizontal: 26, vertical: 8), cornerRadius: 4),
                      tracking: 3, allCaps: true)
        },
        Family(id: "ribbon", noun: "Ribbon", category: .youtube,
               fonts: cleanFonts) { p, f in
            TextStyle(fontName: f, size: 56, weight: weight(f, .bold), color: p.paper,
                      background: TextBackground(color: dim(p.ink, 0.82), padding: BoxPadding(horizontal: 20, vertical: 10), cornerRadius: 12),
                      lineSpacing: 2)
        },
        Family(id: "whisper", noun: "Whisper", category: .youtube,
               fonts: cleanFonts) { p, f in
            TextStyle(fontName: f, size: 64, weight: weight(f, .bold), color: p.paper, stroke: TextStroke(color: p.ink, width: 3),
                      shadow: shadow(p.ink, 0.7, 4, 11))
        },
        // Professional
        Family(id: "lower-third", noun: "Lower", category: .professional,
               fonts: cleanFonts) { p, f in
            TextStyle(fontName: f, size: 44, weight: weight(f, .semibold), color: p.paper,
                      background: TextBackground(color: dim(p.ink, 0.9), padding: BoxPadding(horizontal: 30, vertical: 14), cornerRadius: 2),
                      alignment: .left, tracking: 1)
        },
        Family(id: "hairline", noun: "Hairline", category: .professional,
               fonts: cleanFonts) { p, f in
            TextStyle(fontName: f, size: 42, weight: weight(f, .light), color: p.paper, stroke: TextStroke(color: p.ink, width: 2),
                      shadow: shadow(p.ink, 0.6, 2, 7), tracking: 8, allCaps: true)
        },
        Family(id: "editorial", noun: "Editorial", category: .professional,
               fonts: serifFonts) { p, f in
            TextStyle(fontName: f, size: 66, weight: weight(f, .regular), color: p.paper,
                      shadow: shadow(p.ink, 0.75, 3, 9), tracking: 1, italic: true)
        },
        // Titles
        Family(id: "poster", noun: "Poster", category: .titles,
               fonts: heavyFonts) { p, f in
            TextStyle(fontName: f, size: 128, weight: weight(f, .bold), color: p.fill, stroke: TextStroke(color: p.ink, width: 7),
                      shadow: shadow(p.ink, 0.7, 6, 0), tracking: 6, allCaps: true)
        },
        Family(id: "monument", noun: "Monument", category: .titles,
               fonts: displayFonts) { p, f in
            TextStyle(fontName: f, size: 112, weight: weight(f, .black), color: p.paper, stroke: TextStroke(color: p.ink, width: 6),
                      shadow: shadow(p.accent, 1, 8, 0))
        },
    ]

    // MARK: Table

    /// Every look, in family order then palette order. Fonts rotate per family (`pool[(paletteIndex + familyIndex) % pool.count]`),
    /// so neighboring palettes of one family differ in font as well as color.
    public static let all: [GeneratedTextLook] = {
        var out: [GeneratedTextLook] = []
        var motionCursor: [TextPresetCategory: Int] = [:]
        for (fi, fam) in families.enumerated() {
            let motions = TextPresetCatalog.motions(in: fam.category).filter { $0.animationIn != nil }
            for (pi, pal) in palettes.enumerated() {
                let font = fam.fonts[(pi + fi) % fam.fonts.count]
                let n = motionCursor[fam.category, default: 0]; motionCursor[fam.category] = n + 1
                var look = TextLook(id: "gen-\(fam.id)-\(pal.id)", name: "\(pal.name) \(fam.noun)", category: fam.category,
                                    style: fam.build(pal, font))
                look.suggestedMotionID = motions.isEmpty ? nil : motions[n % motions.count].id
                out.append(GeneratedTextLook(look: look, family: fam.noun, palette: pal.name))
            }
        }
        return out
    }()

    public static var looks: [TextLook] { all.map(\.look) }
    public static var familyNames: [String] { families.map(\.noun) }
    private static let familyByID: [String: String] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.family) })
    /// The family noun of a generated look id (nil for hand-made looks): the Effects panel keeps one sub-folder per family.
    public static func family(ofLookID id: String) -> String? { familyByID[id] }

    /// The contrast of the text against what carries it: its box, else its stroke, else a dense shadow (1 when none).
    /// Boxes with alpha are judged over black and white alike (the worse of the two).
    public static func readability(of s: TextStyle) -> Double {
        if let b = s.background {
            return min(ColorContrast.ratio(s.color, ColorContrast.composite(b.color, overGrey: 0)),
                       ColorContrast.ratio(s.color, ColorContrast.composite(b.color, overGrey: 1)))
        }
        if let st = s.stroke { return ColorContrast.ratio(s.color, st.color) }
        if let sh = s.shadow, sh.color.alpha >= 0.5 { return ColorContrast.ratio(s.color, sh.color) }
        return 1
    }
}
