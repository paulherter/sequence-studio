import Foundation
import SQCore

/// Gallery group of a look (the order of the gallery sections).
public enum LookGroup: String, Sendable, CaseIterable, Hashable {
    case wordLight, entrance, motion, exit, collection
    public var title: String {
        switch self {
        case .wordLight: "Word light"
        case .entrance: "Entrance"
        case .motion: "Loop"
        case .exit: "Exit"
        case .collection: "Collection"
        }
    }
}

/// A ready caption/title look: a style, an animation and (for captions) a word highlight, all by the refs of
/// `CaptionPresetLibrary`, so applying one only sets the same values the panels edit by hand and everything stays
/// editable afterwards.
public struct CaptionStyleLook: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var group: LookGroup
    public var styleRef: String
    public var animationRef: String
    /// Word highlight of caption tracks; titles have no spoken words and ignore it.
    public var karaoke: KaraokeStyle?
    /// Family of a generated look (`GeneratedCaptionLooks`); nil for the hand-made ones.
    public var category: TextPresetCategory? = nil

    public init(id: String, title: String, group: LookGroup, styleRef: String, animationRef: String, karaoke: KaraokeStyle? = nil) {
        self.id = id; self.title = title; self.group = group
        self.styleRef = styleRef; self.animationRef = animationRef; self.karaoke = karaoke
    }

    /// `current` with this look's animation in the slot of its anchor (in-animation or out-animation); the other slot
    /// is kept, so an entrance look does not remove an exit look.
    public func animationSet(in library: CaptionPresetLibrary, keeping current: AnimationSet) -> AnimationSet {
        let t = library.animation(for: animationRef)
        guard t != .none else { return current }
        return t.anchor == .start ? AnimationSet(in: t, out: current.animationOut)
                                  : AnimationSet(in: current.animationIn, out: t)
    }
}

/// Where a look's text sits at one moment of its preview (the maths behind the gallery swatches).
public struct LookPose: Sendable, Equatable {
    public var scale: Double, opacity: Double, offsetX: Double, offsetY: Double
}

public enum CaptionStyleLooks {
    /// Length of the preview window; exit animations play at its end, a lit word advances evenly across it.
    public static let previewDuration = Time(2, 1)

    /// The hand-made looks first, then the generated collection.
    /// Generated ones only while `BuiltInTextLooks.isEnabled` (off: removed from the gallery, styles still resolve by id).
    public static let all: [CaptionStyleLook] = handmade + (BuiltInTextLooks.isEnabled ? GeneratedCaptionLooks.all : [])

    static let handmade: [CaptionStyleLook] = [
        CaptionStyleLook(id: "spark", title: "Spark", group: .wordLight, styleRef: "tiktok", animationRef: "pop",
                    karaoke: KaraokeStyle(red: 1, green: 0.86, blue: 0.1, keepSpoken: false)),
        CaptionStyleLook(id: "fill-up", title: "Fill-up", group: .wordLight, styleRef: "youtube", animationRef: "fade",
                    karaoke: KaraokeStyle(red: 0.3, green: 0.85, blue: 1, keepSpoken: true)),
        CaptionStyleLook(id: "ember", title: "Ember", group: .wordLight, styleRef: "outline", animationRef: "pop-in",
                    karaoke: KaraokeStyle(red: 1, green: 0.5, blue: 0.1, keepSpoken: true)),
        CaptionStyleLook(id: "mint-card", title: "Mint card", group: .wordLight, styleRef: "bold-box", animationRef: "fade",
                    karaoke: KaraokeStyle(red: 0.35, green: 1, blue: 0.65, keepSpoken: false)),
        CaptionStyleLook(id: "type-on", title: "Type-on", group: .wordLight, styleRef: "ghost", animationRef: "none",
                    karaoke: KaraokeStyle(red: 1, green: 1, blue: 1, keepSpoken: true)),

        CaptionStyleLook(id: "pop", title: "Pop", group: .entrance, styleRef: "title", animationRef: "pop"),
        CaptionStyleLook(id: "rise", title: "Rise", group: .entrance, styleRef: "sticker", animationRef: "rise"),
        CaptionStyleLook(id: "slide-in", title: "Slide in", group: .entrance, styleRef: "neon", animationRef: "slide-side"),
        CaptionStyleLook(id: "drop-in", title: "Drop in", group: .entrance, styleRef: "tiktok", animationRef: "bounce-in"),

        CaptionStyleLook(id: "word-bounce", title: "Word bounce", group: .entrance, styleRef: "tiktok", animationRef: "word-bounce"),
        CaptionStyleLook(id: "ripple", title: "Ripple", group: .entrance, styleRef: "title", animationRef: "ripple-in"),

        CaptionStyleLook(id: "wave", title: "Wave", group: .motion, styleRef: "title", animationRef: "wave"),
        CaptionStyleLook(id: "hop", title: "Hop", group: .motion, styleRef: "tiktok", animationRef: "hop"),
        CaptionStyleLook(id: "pulse", title: "Pulse", group: .motion, styleRef: "neon", animationRef: "pulse"),
        CaptionStyleLook(id: "sway", title: "Sway", group: .motion, styleRef: "youtube", animationRef: "sway"),
        CaptionStyleLook(id: "shake", title: "Shake", group: .motion, styleRef: "outline", animationRef: "shake"),

        CaptionStyleLook(id: "fade-away", title: "Fade away", group: .exit, styleRef: "classic", animationRef: "fade-out"),
        CaptionStyleLook(id: "shrink-out", title: "Shrink out", group: .exit, styleRef: "bold-box", animationRef: "shrink-out"),
        CaptionStyleLook(id: "slide-away", title: "Slide away", group: .exit, styleRef: "title", animationRef: "slide-out"),
        CaptionStyleLook(id: "ripple-out", title: "Ripple out", group: .exit, styleRef: "title", animationRef: "ripple-out"),
        CaptionStyleLook(id: "word-pop-out", title: "Word pop out", group: .exit, styleRef: "tiktok", animationRef: "word-pop-out"),
    ]

    public static func look(id: String) -> CaptionStyleLook? { all.first { $0.id == id } }
    public static func looks(in group: LookGroup) -> [CaptionStyleLook] { all.filter { $0.group == group } }

    /// The look whose style, animation and highlight all match (nil once any of them was edited).
    public static func matching(styleRef: String, animationRef: String, karaoke: KaraokeStyle?) -> CaptionStyleLook? {
        all.first { $0.styleRef == styleRef && $0.animationRef == animationRef && $0.karaoke == karaoke }
    }

    /// Pose of the look at preview time `t` (0 ..< `previewDuration`), from the same template maths playback uses.
    public static func pose(of look: CaptionStyleLook, library: CaptionPresetLibrary = .builtIn, at t: Time) -> LookPose {
        let a = library.animation(for: look.animationRef)
        func v(_ p: String, _ d: Double) -> Double { a.value(of: p, clipTime: t, clipDuration: previewDuration) ?? d }
        return LookPose(scale: v("scale", 1), opacity: min(1, max(0, v("opacity", 1))), offsetX: v("positionX", 0), offsetY: v("positionY", 0))
    }

    /// Index of the word lit at preview time `t` when the words share the window evenly; nil without words.
    public static func litWord(count: Int, at t: Time) -> Int? {
        guard count > 0 else { return nil }
        let p = previewDuration
        let n = Int128(t.value) * Int128(count) * Int128(p.timescale)
        let d = Int128(t.timescale) * Int128(p.value)
        let i = n < 0 ? 0 : Int(n / d)
        return min(max(i, 0), count - 1)
    }

    // MARK: Animations the looks need (merged into `CaptionPresetLibrary.builtIn`)

    static let extraAnimations: [String: KeyframeTemplate] = {
        let f = Time(1, 30)
        func fadeIn(_ end: Time) -> AnimationTrack {
            AnimationTrack(property: "opacity", keys: [(.zero, 0, .linear), (end, 1, .linear)])
        }
        // Scale 0 / 120 / 100 at frames 0 / 4 / 10 (the pop caption of USAGE-PREMIERE).
        let pop = KeyframeTemplate(tracks: [
            AnimationTrack(property: "scale", keys: [(.zero, 0, .easeOut), (f * 4, 1.2, .easeInOut), (f * 10, 1, .linear)]),
        ], duration: f * 10)
        let rise = KeyframeTemplate(tracks: [
            AnimationTrack(property: "positionY", keys: [(.zero, 48, .easeOut), (Time(1, 4), 0, .linear)]), fadeIn(Time(1, 6)),
        ], duration: Time(1, 4))
        let slideSide = KeyframeTemplate(tracks: [
            AnimationTrack(property: "positionX", keys: [(.zero, -90, .easeOut), (Time(1, 4), 0, .linear)]), fadeIn(Time(1, 6)),
        ], duration: Time(1, 4))
        let bounceIn = KeyframeTemplate(tracks: [
            AnimationTrack(property: "positionY", keys: [(.zero, 70, .overshoot), (Time(1, 3), 0, .linear)]), fadeIn(Time(1, 10)),
        ], duration: Time(1, 3))
        // Loops: the last key equals the first, so the cycle repeats without a jump.
        let wave = KeyframeTemplate(tracks: [
            AnimationTrack(property: "positionY", keys: [(.zero, 0, .easeInOut), (Time(1, 4), -14, .easeInOut),
                                                         (Time(3, 4), 14, .easeInOut), (Time(1, 1), 0, .linear)]),
        ], duration: Time(1, 1), loops: true)
        let hop = KeyframeTemplate(tracks: [
            AnimationTrack(property: "positionY", keys: [(.zero, 0, .easeOut), (Time(1, 6), -24, .easeIn),
                                                         (Time(1, 3), 0, .linear), (Time(2, 3), 0, .linear)]),
        ], duration: Time(2, 3), loops: true)
        let pulse = KeyframeTemplate(tracks: [
            AnimationTrack(property: "scale", keys: [(.zero, 1, .easeInOut), (Time(1, 2), 1.08, .easeInOut), (Time(1, 1), 1, .linear)]),
        ], duration: Time(1, 1), loops: true)
        let sway = KeyframeTemplate(tracks: [
            AnimationTrack(property: "positionX", keys: [(.zero, 0, .easeInOut), (Time(3, 8), -10, .easeInOut),
                                                         (Time(9, 8), 10, .easeInOut), (Time(3, 2), 0, .linear)]),
        ], duration: Time(3, 2), loops: true)
        let shrinkOut = KeyframeTemplate(tracks: [
            AnimationTrack(property: "scale", keys: [(.zero, 1, .easeIn), (Time(1, 5), 0, .linear)]),
        ], duration: Time(1, 5), anchor: .end)
        let slideOut = KeyframeTemplate(tracks: [
            AnimationTrack(property: "positionY", keys: [(.zero, 0, .easeIn), (Time(1, 4), 48, .linear)]),
            AnimationTrack(property: "opacity", keys: [(.zero, 1, .linear), (Time(1, 4), 0, .linear)]),
        ], duration: Time(1, 4), anchor: .end)
        // Neutral pair for graphic items and captions: a small scale with a fade, no overshoot.
        let scaleIn = KeyframeTemplate(tracks: [
            AnimationTrack(property: "scale", keys: [(.zero, 0.9, .easeOut), (Time(1, 5), 1, .linear)]), fadeIn(Time(1, 5)),
        ], duration: Time(1, 5))
        let scaleOut = KeyframeTemplate(tracks: [
            AnimationTrack(property: "scale", keys: [(.zero, 1, .easeIn), (Time(1, 5), 0.9, .linear)]),
            AnimationTrack(property: "opacity", keys: [(.zero, 1, .linear), (Time(1, 5), 0, .linear)]),
        ], duration: Time(1, 5), anchor: .end)
        // Shake: a short side-to-side jitter that returns to its start, so the cycle repeats without a jump.
        let shake = KeyframeTemplate(tracks: [
            AnimationTrack(property: "positionX", keys: [(.zero, 0, .easeInOut), (f * 2, -7, .easeInOut), (f * 5, 7, .easeInOut),
                                                         (f * 8, -4, .easeInOut), (f * 10, 0, .linear)]),
        ], duration: f * 10, loops: true)
        // Per-unit entrances and exits ride on the text animator (no keyframe tracks): words pop with overshoot, characters
        // rise one after another. The exits mirror them against the caption end.
        let wordBounce = KeyframeTemplate(textAnimator: TextAnimator(effect: .pop, unit: .word, easing: .overshoot,
                                                                     duration: Time(1, 5), stagger: Time(1, 10)))
        let rippleIn = KeyframeTemplate(textAnimator: TextAnimator(effect: .slide, unit: .character, easing: .easeOut,
                                                                   duration: Time(1, 5), stagger: Time(1, 30),
                                                                   distance: 28, direction: .up))
        let rippleOut = KeyframeTemplate(textAnimator: TextAnimator(effect: .slide, unit: .character, easing: .easeIn,
                                                                    duration: Time(1, 5), stagger: Time(1, 30),
                                                                    distance: 28, direction: .up), anchor: .end)
        let wordPopOut = KeyframeTemplate(textAnimator: TextAnimator(effect: .pop, unit: .word, easing: .easeIn,
                                                                     duration: Time(1, 6), stagger: Time(1, 12)), anchor: .end)
        return ["word-bounce": wordBounce, "ripple-in": rippleIn, "ripple-out": rippleOut, "word-pop-out": wordPopOut,
                "shake": shake, "pop": pop, "rise": rise, "slide-side": slideSide, "bounce-in": bounceIn, "wave": wave, "hop": hop,
                "pulse": pulse, "sway": sway, "shrink-out": shrinkOut, "slide-out": slideOut,
                "scale-in": scaleIn, "scale-out": scaleOut]
    }()

    /// The clean presets (fade, rise, scale; no bounce), listed first among the Intro / Outro choices.
    public static let neutralIntroIDs = ["fade", "rise", "scale-in"]
    public static let neutralOutroIDs = ["fade-out", "slide-out", "scale-out"]
}
