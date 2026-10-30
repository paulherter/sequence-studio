import Foundation
import SQCore

/// Library families of the built-in text presets (Library folder names).
public enum TextPresetCategory: String, Sendable, CaseIterable, Hashable {
    case tiktok, youtube, professional, titles

    public var title: String {
        switch self {
        case .tiktok: "TikTok"
        case .youtube: "YouTube"
        case .professional: "Professional"
        case .titles: "Titles"
        }
    }
}

/// How a text looks: font, color, stroke, shadow, background. Applying it changes the style only.
public struct TextLook: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var category: TextPresetCategory
    public var style: TextStyle
    /// A motion (`TextMotion.id`) that suits the look: the hover preview plays it. Applying the look never applies it.
    public var suggestedMotionID: String? = nil
}

/// How a text moves: an in-animation, an out-animation or both. Applying it changes the keyframes only.
public struct TextMotion: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var category: TextPresetCategory
    public var animationIn: KeyframeTemplate?
    public var animationOut: KeyframeTemplate?
}

/// Pure apply logic: a look and a motion are independent and stack in any order.
public enum TextPresetApply {
    /// The template with the look's style; text, box, highlight and animation stay.
    public static func apply(look: TextLook, to template: TextTemplate) -> TextTemplate {
        var t = template
        t.style = look.style
        return t
    }

    /// The animation set with the motion's in and/or out side replaced; a side the motion does not carry stays.
    public static func apply(motion: TextMotion, to set: AnimationSet?) -> AnimationSet {
        AnimationSet(in: motion.animationIn ?? set?.animationIn, out: motion.animationOut ?? set?.animationOut)
    }

    /// A text layer's generator payload with the look applied (text, box and animation stay).
    public static func apply(look: TextLook, to ref: GeneratorRef) throws -> GeneratorRef {
        let (template, animations) = try TextGenerator.decode(ref)
        return try TextGenerator.makeRef(template: apply(look: look, to: template), animations: animations)
    }

    /// A text layer's generator payload with the motion applied (style and text stay).
    public static func apply(motion: TextMotion, to ref: GeneratorRef) throws -> GeneratorRef {
        let (template, animations) = try TextGenerator.decode(ref)
        return try TextGenerator.makeRef(template: template, animations: apply(motion: motion, to: animations))
    }
}

/// Built-in set. Looks use only bundled (OFL) fonts. Styled after common creator content, not after any template pack.
public enum TextPresetCatalog {
    public static let lookPrefix = "textlook.", motionPrefix = "textanim."

    public static func lookID(_ l: TextLook) -> String { lookPrefix + l.id }
    public static func motionID(_ m: TextMotion) -> String { motionPrefix + m.id }
    public static func isTextPresetID(_ id: String) -> Bool { id.hasPrefix(lookPrefix) || id.hasPrefix(motionPrefix) }

    /// Accepts the prefixed (pasteboard) id.
    public static func look(id: String) -> TextLook? {
        guard id.hasPrefix(lookPrefix) else { return nil }
        let raw = String(id.dropFirst(lookPrefix.count))
        return looks.first { $0.id == raw }
    }
    public static func motion(id: String) -> TextMotion? {
        guard id.hasPrefix(motionPrefix) else { return nil }
        let raw = String(id.dropFirst(motionPrefix.count))
        return motions.first { $0.id == raw }
    }
    public static func looks(in c: TextPresetCategory) -> [TextLook] { looks.filter { $0.category == c } }
    public static func motions(in c: TextPresetCategory) -> [TextMotion] { motions.filter { $0.category == c } }

    // MARK: Looks

    private static func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> RGBAColor { RGBAColor(red: r, green: g, blue: b, alpha: a) }
    private static let ink = RGBAColor.black
    private static func shadow(_ a: Double = 0.55, _ dist: Double = 3, _ blur: Double = 8) -> TextShadow {
        TextShadow(color: rgb(0, 0, 0, a), angle: 135, distance: dist, blur: blur)
    }

    /// The hand-made looks first, then the generated collection (`TextLookGenerator`).
    public static let looks: [TextLook] = handmade + TextLookGenerator.looks

    public static let handmade: [TextLook] = [
        // TikTok
        TextLook(id: "tiktok-classic", name: "Classic Outline", category: .tiktok,
                 style: TextStyle(fontName: "Montserrat", size: 72, weight: .black, stroke: TextStroke(color: ink, width: 9),
                                  shadow: shadow(), lineSpacing: 2)),
        TextLook(id: "tiktok-yellow", name: "Yellow Caps", category: .tiktok,
                 style: TextStyle(fontName: "Anton", size: 84, weight: .regular, color: rgb(1, 0.85, 0),
                                  stroke: TextStroke(color: ink, width: 10), shadow: shadow(0.6, 4, 0), tracking: 1, allCaps: true)),
        TextLook(id: "tiktok-word-box", name: "Highlight Box", category: .tiktok,
                 style: TextStyle(fontName: "Archivo Black", size: 64, weight: .regular, color: ink,
                                  background: TextBackground(color: rgb(1, 0.88, 0.1), padding: BoxPadding(horizontal: 22, vertical: 10), cornerRadius: 12),
                                  allCaps: true)),
        TextLook(id: "tiktok-comic", name: "Comic Pop", category: .tiktok,
                 style: TextStyle(fontName: "Bangers", size: 88, weight: .regular, color: .white,
                                  stroke: TextStroke(color: ink, width: 8, position: .centre),
                                  shadow: TextShadow(color: rgb(0.9, 0.1, 0.25), angle: 135, distance: 7, blur: 0), tracking: 2)),
        // YouTube
        TextLook(id: "yt-reaction", name: "Reaction Bold", category: .youtube,
                 style: TextStyle(fontName: "Lilita One", size: 86, weight: .regular, stroke: TextStroke(color: ink, width: 9),
                                  shadow: TextShadow(color: rgb(0, 0, 0, 0.8), angle: 135, distance: 6, blur: 0))),
        TextLook(id: "yt-caption-bar", name: "Caption Bar", category: .youtube,
                 style: TextStyle(fontName: "Poppins", size: 54, weight: .bold,
                                  background: TextBackground(color: rgb(0, 0, 0, 0.72), padding: BoxPadding(horizontal: 18, vertical: 8), cornerRadius: 6),
                                  lineSpacing: 2)),
        TextLook(id: "yt-red-flag", name: "Red Flag", category: .youtube,
                 style: TextStyle(fontName: "Anton", size: 76, weight: .regular, color: .white,
                                  background: TextBackground(color: rgb(0.86, 0.08, 0.1), padding: BoxPadding(horizontal: 24, vertical: 8), cornerRadius: 4),
                                  tracking: 2, allCaps: true)),
        TextLook(id: "yt-clean", name: "Clean Shadow", category: .youtube,
                 style: TextStyle(fontName: "Outfit", size: 64, weight: .bold, shadow: shadow(0.7, 4, 10))),
        // Professional
        TextLook(id: "pro-lower-third", name: "Lower Third", category: .professional,
                 style: TextStyle(fontName: "Montserrat", size: 46, weight: .semibold, shadow: shadow(0.5, 2, 6), alignment: .left)),
        TextLook(id: "pro-minimal", name: "Minimal Caps", category: .professional,
                 style: TextStyle(fontName: "Outfit", size: 42, weight: .light, shadow: shadow(0.4, 2, 6), tracking: 8, allCaps: true)),
        TextLook(id: "pro-dark-box", name: "Dark Box", category: .professional,
                 style: TextStyle(fontName: "Inter", size: 44, weight: .medium,
                                  background: TextBackground(color: rgb(0.05, 0.06, 0.08, 0.78), padding: BoxPadding(horizontal: 26, vertical: 12), cornerRadius: 3))),
        TextLook(id: "pro-serif", name: "Editorial Serif", category: .professional,
                 style: TextStyle(fontName: "Playfair Display", size: 62, weight: .regular, shadow: shadow(0.5, 2, 8))),
        // Titles
        TextLook(id: "title-bebas", name: "Tall Title", category: .titles,
                 style: TextStyle(fontName: "Bebas Neue", size: 132, weight: .regular, shadow: shadow(0.55, 4, 12), tracking: 6, allCaps: true)),
        TextLook(id: "title-oswald", name: "Poster Bold", category: .titles,
                 style: TextStyle(fontName: "Oswald", size: 110, weight: .bold, color: .white, shadow: shadow(0.6, 5, 12), tracking: 3, allCaps: true)),
        TextLook(id: "title-serif", name: "Display Serif", category: .titles,
                 style: TextStyle(fontName: "DM Serif Display", size: 108, weight: .regular, shadow: shadow(0.55, 4, 12))),
        TextLook(id: "title-spartan", name: "Heavy Geometric", category: .titles,
                 style: TextStyle(fontName: "League Spartan", size: 112, weight: .black, stroke: TextStroke(color: rgb(0.1, 0.35, 1), width: 8),
                                  shadow: shadow(0.5, 4, 10), allCaps: true)),
    ]

    // MARK: Motions

    private typealias Key = (time: Time, value: Double, shape: SegmentShape)
    private static func t(_ n: Int64, _ d: Int64) -> Time { Time(n, d) }
    private static func inAnim(_ dur: Time, _ tracks: [(String, [Key])]) -> KeyframeTemplate {
        KeyframeTemplate(tracks: tracks.map { AnimationTrack(property: $0.0, keys: $0.1) }, duration: dur, anchor: .start)
    }
    private static func outAnim(_ dur: Time, _ tracks: [(String, [Key])]) -> KeyframeTemplate {
        KeyframeTemplate(tracks: tracks.map { AnimationTrack(property: $0.0, keys: $0.1) }, duration: dur, anchor: .end)
    }
    private static func fadeIn(_ d: Time) -> (String, [Key]) { ("opacity", [(.zero, 0, .easeOut), (d, 1, .linear)]) }
    private static func fadeOut(_ d: Time) -> (String, [Key]) { ("opacity", [(.zero, 1, .easeIn), (d, 0, .linear)]) }

    private static let fadeOutQuick = outAnim(t(1, 5), [fadeOut(t(1, 5))])

    public static let motions: [TextMotion] = [
        // TikTok
        TextMotion(id: "tiktok-pop", name: "Pop", category: .tiktok,
                   animationIn: inAnim(t(1, 4), [("scale", [(.zero, 0.6, .overshoot), (t(1, 4), 1, .linear)]),
                                                 ("opacity", [(.zero, 0, .easeOut), (t(1, 8), 1, .linear), (t(1, 4), 1, .linear)])]),
                   animationOut: outAnim(t(1, 6), [("scale", [(.zero, 1, .easeIn), (t(1, 6), 0.8, .linear)]), fadeOut(t(1, 6))])),
        TextMotion(id: "tiktok-bounce", name: "Bounce", category: .tiktok,
                   animationIn: inAnim(t(1, 2), [("scale", [(.zero, 0.5, .easeOut), (t(3, 20), 1.18, .easeInOut), (t(6, 20), 0.94, .easeInOut), (t(1, 2), 1, .linear)]),
                                                 ("opacity", [(.zero, 0, .linear), (t(1, 10), 1, .linear), (t(1, 2), 1, .linear)])]),
                   animationOut: nil),
        TextMotion(id: "tiktok-jolt", name: "Jolt", category: .tiktok,
                   animationIn: inAnim(t(1, 3), [("rotation", [(.zero, -8, .easeOut), (t(1, 12), 6, .easeInOut), (t(1, 6), -3, .easeInOut), (t(1, 3), 0, .linear)]),
                                                 ("scale", [(.zero, 1.25, .easeOut), (t(1, 6), 1, .linear), (t(1, 3), 1, .linear)]),
                                                 ("opacity", [(.zero, 0, .linear), (t(1, 20), 1, .linear), (t(1, 3), 1, .linear)])]),
                   animationOut: nil),
        TextMotion(id: "tiktok-pop-out", name: "Pop Out", category: .tiktok, animationIn: nil,
                   animationOut: outAnim(t(1, 5), [("scale", [(.zero, 1, .easeIn), (t(1, 5), 0.5, .linear)]), fadeOut(t(1, 5))])),
        // YouTube
        TextMotion(id: "yt-slide-up", name: "Slide Up", category: .youtube,
                   animationIn: inAnim(t(1, 3), [("positionY", [(.zero, 70, .easeOut), (t(1, 3), 0, .linear)]), fadeIn(t(1, 4))]),
                   animationOut: outAnim(t(1, 4), [("positionY", [(.zero, 0, .easeIn), (t(1, 4), 50, .linear)]), fadeOut(t(1, 4))])),
        TextMotion(id: "yt-slide-left", name: "Slide From Left", category: .youtube,
                   animationIn: inAnim(t(2, 5), [("positionX", [(.zero, -160, .easeOut), (t(2, 5), 0, .linear)]), fadeIn(t(1, 5))]),
                   animationOut: outAnim(t(1, 4), [("positionX", [(.zero, 0, .easeIn), (t(1, 4), -120, .linear)]), fadeOut(t(1, 4))])),
        TextMotion(id: "yt-drop", name: "Drop In", category: .youtube,
                   animationIn: inAnim(t(2, 5), [("positionY", [(.zero, -140, .overshoot), (t(2, 5), 0, .linear)]), fadeIn(t(1, 8))]),
                   animationOut: nil),
        TextMotion(id: "yt-slide-out", name: "Slide Out Down", category: .youtube, animationIn: nil,
                   animationOut: outAnim(t(1, 3), [("positionY", [(.zero, 0, .easeIn), (t(1, 3), 90, .linear)]), fadeOut(t(1, 3))])),
        // Professional
        TextMotion(id: "pro-fade", name: "Fade", category: .professional,
                   animationIn: inAnim(t(1, 2), [fadeIn(t(1, 2))]), animationOut: outAnim(t(1, 2), [fadeOut(t(1, 2))])),
        TextMotion(id: "pro-rise", name: "Soft Rise", category: .professional,
                   animationIn: inAnim(t(3, 5), [("positionY", [(.zero, 24, .easeOut), (t(3, 5), 0, .linear)]), fadeIn(t(3, 5))]),
                   animationOut: outAnim(t(2, 5), [fadeOut(t(2, 5))])),
        TextMotion(id: "pro-soft-zoom", name: "Soft Zoom", category: .professional,
                   animationIn: inAnim(t(3, 5), [("scale", [(.zero, 0.94, .easeOut), (t(3, 5), 1, .linear)]), fadeIn(t(3, 5))]),
                   animationOut: nil),
        TextMotion(id: "pro-fade-out", name: "Fade Out", category: .professional, animationIn: nil, animationOut: fadeOutQuick),
        // Titles
        TextMotion(id: "title-punch", name: "Zoom Punch", category: .titles,
                   animationIn: inAnim(t(1, 3), [("scale", [(.zero, 1.5, .easeOut), (t(1, 3), 1, .linear)]), fadeIn(t(1, 6))]),
                   animationOut: nil),
        TextMotion(id: "title-spin", name: "Spin In", category: .titles,
                   animationIn: inAnim(t(1, 2), [("rotation", [(.zero, -90, .overshoot), (t(1, 2), 0, .linear)]),
                                                 ("scale", [(.zero, 0.3, .easeOut), (t(1, 2), 1, .linear)]), fadeIn(t(1, 6))]),
                   animationOut: nil),
        TextMotion(id: "title-flicker", name: "Flicker", category: .titles,
                   animationIn: inAnim(t(1, 3), [("opacity", [(.zero, 0, .hold), (t(1, 15), 1, .hold), (t(2, 15), 0.2, .hold), (t(1, 5), 1, .hold), (t(1, 3), 1, .linear)])]),
                   animationOut: outAnim(t(1, 4), [("opacity", [(.zero, 1, .hold), (t(1, 12), 0.3, .hold), (t(1, 6), 1, .hold), (t(1, 4), 0, .linear)])])),
        // Characters appear one by one (no fade); ends with the text fully shown, so no out side.
        TextMotion(id: "title-typewriter", name: "Typewriter", category: .titles,
                   animationIn: KeyframeTemplate(textAnimator: TextAnimator(effect: .typewriter, unit: .character,
                                                                            duration: .zero, stagger: t(1, 20))),
                   animationOut: nil),
        TextMotion(id: "title-rise-out", name: "Rise Out", category: .titles, animationIn: nil,
                   animationOut: outAnim(t(2, 5), [("positionY", [(.zero, 0, .easeIn), (t(2, 5), -80, .linear)]), fadeOut(t(2, 5))])),
    ]
}

/// One internal switch for the built-in text Looks / Animations and the generated caption looks and presets: removed from
/// every panel until a designed system exists (feedback 2026-10-06, the design notes). Catalogs and tests stay; styles still
/// resolve by id, so a project that uses one opens and renders unchanged. No user setting.
public enum BuiltInTextLooks {
    public static let isEnabled = false
}
