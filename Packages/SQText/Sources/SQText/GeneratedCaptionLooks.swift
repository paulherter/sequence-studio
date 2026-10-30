import Foundation
import SQCore

/// Caption styles from the same generator as the text Looks (`TextLookGenerator`): every third or fourth palette of each
/// caption-sized family (TikTok, YouTube, Professional), as gallery looks (style + entrance animation + word highlight).
/// Their styles are merged into `CaptionPresetLibrary.builtIn`, so the refs resolve in the monitor and the burn-in.
/// Deterministic like the table it comes from.
public enum GeneratedCaptionLooks {
    /// The caption selection of the generator: `paletteIndex % 4 == familyIndex % 4`, no title families.
    static let source: [GeneratedTextLook] = {
        let fams = TextLookGenerator.families
        return TextLookGenerator.all.filter { g in
            guard g.look.category != .titles,
                  let fi = fams.firstIndex(where: { $0.noun == g.family }),
                  let pi = TextLookGenerator.palettes.firstIndex(where: { $0.name == g.palette }) else { return false }
            return pi % 4 == fi % 4
        }
    }()

    public static let stylePrefix = "gen-"

    /// Style by ref (`CaptionStyleLook.styleRef`).
    public static let styles: [String: TextStyle] = Dictionary(uniqueKeysWithValues: source.map { ($0.id, $0.look.style) })

    private static let entrances: [TextPresetCategory: [String]] = [
        .tiktok: ["pop", "bounce-in"], .youtube: ["rise", "slide-side"], .professional: ["fade", "rise"],
    ]

    /// The look's lit-word color: the first of accent, fill, paper that stands apart from the text color and still reads
    /// against what carries the text. Dark text (on a light box) gets none: a lit word would vanish into the box.
    static func highlight(for g: GeneratedTextLook, palette p: LookPalette) -> KaraokeStyle? {
        let s = g.look.style
        guard ColorContrast.luminance(s.color) > 0.35 else { return nil }
        let backing = s.background.map { ColorContrast.composite($0.color, overGrey: 0.5) } ?? s.stroke?.color ?? s.shadow?.color ?? .black
        func apart(_ c: RGBAColor) -> Bool {
            abs(c.red - s.color.red) + abs(c.green - s.color.green) + abs(c.blue - s.color.blue) >= 0.3
        }
        guard let c = [p.accent, p.fill, p.paper].first(where: { apart($0) && ColorContrast.ratio($0, backing) >= 4.5 }) else { return nil }
        return KaraokeStyle(red: c.red, green: c.green, blue: c.blue, keepSpoken: g.look.category != .tiktok)
    }

    public static let all: [CaptionStyleLook] = source.enumerated().map { i, g in
        let p = TextLookGenerator.palettes.first { $0.name == g.palette }!
        let anims = entrances[g.look.category] ?? ["fade"]
        var l = CaptionStyleLook(id: g.id, title: g.look.name, group: .collection, styleRef: g.id,
                                 animationRef: anims[i % anims.count], karaoke: highlight(for: g, palette: p))
        l.category = g.look.category
        return l
    }
}
