import Foundation
import SQCore

/// Resolves the opaque `styleRef` / `animationRef` strings (see SQTranscribe `CaptionPreset`).
/// Unknown or nil refs fall back to the library default.
public struct CaptionPresetLibrary: Sendable {
    public let styles: [String: TextStyle]
    public let animations: [String: KeyframeTemplate]
    public let defaultStyleID: String
    public let defaultAnimationID: String
    /// FB-Y: where the captions of this library's project sit (the kit's `captionPosition`; bottom center without one).
    public var position: CaptionPosition = .default

    public init(styles: [String: TextStyle], animations: [String: KeyframeTemplate],
                defaultStyleID: String, defaultAnimationID: String) {
        precondition(styles[defaultStyleID] != nil && animations[defaultAnimationID] != nil, "defaults must exist")
        self.styles = styles; self.animations = animations
        self.defaultStyleID = defaultStyleID; self.defaultAnimationID = defaultAnimationID
    }

    public var styleIDs: [String] { styles.keys.sorted() }
    public var animationIDs: [String] { animations.keys.sorted() }
    public func hasStyle(_ id: String) -> Bool { styles[id] != nil }
    public func hasAnimation(_ id: String) -> Bool { animations[id] != nil }
    public func style(for ref: String?) -> TextStyle { ref.flatMap { styles[$0] } ?? styles[defaultStyleID]! }
    public func animation(for ref: String?) -> KeyframeTemplate { ref.flatMap { animations[$0] } ?? animations[defaultAnimationID]! }

    /// The built-in looks plus every user Caption Look registered in `CaptionLookRegistry` (so saved looks render in the
    /// monitor and the burn-in through the same call sites).
    public static var builtIn: CaptionPresetLibrary { CaptionLookRegistry.shared.library }

    /// A copy with `look` added under `id`-derived style and animation ids (see `CaptionLook.styleID(for:)`).
    public func adding(_ look: CaptionLook, id: String) -> CaptionPresetLibrary {
        var s = styles, a = animations
        s[CaptionLook.styleID(for: id)] = look.style
        a[CaptionLook.animationID(for: id)] = look.animation
        var lib = CaptionPresetLibrary(styles: s, animations: a, defaultStyleID: defaultStyleID, defaultAnimationID: defaultAnimationID)
        lib.position = position
        return lib
    }

    /// Font of the built-in styles before they moved to Inter (projects without `Project.builtInStyles`).
    public static let legacyFontName = "Helvetica"

    /// The built-in styles: Inter, or the Helvetica set an old project was made with.
    static func base(legacyFont: Bool) -> CaptionPresetLibrary { legacyFont ? legacyBase : base }

    static let legacyBase: CaptionPresetLibrary = {
        CaptionPresetLibrary(styles: base.styles.mapValues { var s = $0; s.fontName = legacyFontName; return s },
                             animations: base.animations, defaultStyleID: base.defaultStyleID,
                             defaultAnimationID: base.defaultAnimationID)
    }()

    static let base: CaptionPresetLibrary = {
        let classic = TextStyle(fontName: TextStyle.defaultFontName, size: 56, weight: .semibold, color: .white,
                                shadow: TextShadow(color: RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.6), offsetX: 0, offsetY: 2, blur: 6),
                                alignment: .center, lineSpacing: 4)
        let box = TextStyle(fontName: TextStyle.defaultFontName, size: 52, weight: .bold, color: .white,
                            background: TextBackground(color: RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.75),
                                                       padding: BoxPadding(horizontal: 20, vertical: 10), cornerRadius: 12),
                            alignment: .center, lineSpacing: 4)
        let outline = TextStyle(fontName: TextStyle.defaultFontName, size: 60, weight: .heavy, color: .white,
                                stroke: TextStroke(color: .black, width: 6), alignment: .center, lineSpacing: 2)
        let softShadow = TextShadow(color: RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.55), angle: 135, distance: 3, blur: 8)
        // Type tool default and the two short-video looks: bold sans, white fill.
        let title = TextStyle(fontName: TextStyle.defaultFontName, size: 72, weight: .bold, color: .white, shadow: softShadow,
                              alignment: .center, lineSpacing: 2)
        let tiktok = TextStyle(fontName: TextStyle.defaultFontName, size: 64, weight: .black, color: .white,
                               stroke: TextStroke(color: .black, width: 8), shadow: softShadow, alignment: .center, lineSpacing: 2)
        let youtube = TextStyle(fontName: TextStyle.defaultFontName, size: 56, weight: .bold, color: .white,
                                background: TextBackground(color: RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.7),
                                                           padding: BoxPadding(horizontal: 14, vertical: 6), cornerRadius: 6),
                                alignment: .center, lineSpacing: 2)
        // Short-video pill: bold white word on a rounded black pill (no outline, the pill carries the contrast).
        let pill = CaptionPill.apply(to: TextStyle(fontName: TextStyle.defaultFontName, size: 64, weight: .black, color: .white,
                                                   alignment: .center, lineSpacing: 2))
        let popIn = KeyframeTemplate(tracks: [
            AnimationTrack(property: "scale", keys: [
                (.zero, 0.8, .overshoot), (Time(1, 4), 1.0, .linear),
            ]),
            AnimationTrack(property: "opacity", keys: [
                (.zero, 0, .easeOut), (Time(1, 8), 1, .linear), (Time(1, 4), 1, .linear),
            ]),
        ], duration: Time(1, 4))
        let fade = KeyframeTemplate(tracks: [
            AnimationTrack(property: "opacity", keys: [(.zero, 0, .linear), (Time(1, 5), 1, .linear)]),
        ], duration: Time(1, 5))
        let fadeOut = KeyframeTemplate(tracks: [
            AnimationTrack(property: "opacity", keys: [(.zero, 1, .linear), (Time(1, 5), 0, .linear)]),
        ], duration: Time(1, 5), anchor: .end)
        // Styles of the look gallery (CaptionStyleLooks): a dim base whose lit words fill in, a sticker, a neon outline.
        let ghost = TextStyle(fontName: TextStyle.defaultFontName, size: 64, weight: .heavy,
                              color: RGBAColor(red: 1, green: 1, blue: 1, alpha: 0.3), alignment: .center, lineSpacing: 2)
        let sticker = TextStyle(fontName: TextStyle.defaultFontName, size: 56, weight: .black, color: RGBAColor(red: 0.08, green: 0.08, blue: 0.1),
                                background: TextBackground(color: RGBAColor(red: 1, green: 1, blue: 1, alpha: 0.96),
                                                           padding: BoxPadding(horizontal: 18, vertical: 8), cornerRadius: 10),
                                alignment: .center, lineSpacing: 2)
        let neon = TextStyle(fontName: TextStyle.defaultFontName, size: 60, weight: .heavy, color: RGBAColor(red: 0.85, green: 1, blue: 0.95),
                             stroke: TextStroke(color: RGBAColor(red: 0, green: 0.55, blue: 0.6), width: 5),
                             shadow: TextShadow(color: RGBAColor(red: 0, green: 0.9, blue: 0.9, alpha: 0.8), angle: 90, distance: 0, blur: 16),
                             alignment: .center, lineSpacing: 2)
        var animations: [String: KeyframeTemplate] = ["none": .none, "fade": fade, "fade-out": fadeOut, "pop-in": popIn,
                                                      CaptionLook.popAnimationID: .captionPop]
        animations.merge(CaptionStyleLooks.extraAnimations) { a, _ in a }
        var styles: [String: TextStyle] = ["default": classic, "classic": classic, "bold-box": box, "outline": outline,
                                           "title": title, "tiktok": tiktok, "youtube": youtube, CaptionPill.styleID: pill,
                                           "ghost": ghost, "sticker": sticker, "neon": neon]
        styles.merge(GeneratedCaptionLooks.styles) { a, _ in a }
        return CaptionPresetLibrary(
            styles: styles, animations: animations,
            defaultStyleID: "default", defaultAnimationID: "none")
    }()
}

extension KeyframeTemplate {
    /// The maintainer's caption pop, softened after FB-Y ("far too strong, ease softer toward the end"): scale 96 % at the start,
    /// 102 % at 0.08 s (ease out), then easing out back to 100 % at 0.28 s. Anchored at the caption start; the pivot is
    /// the center of the text (`CaptionLayout.pivot`).
    public static let captionPop = KeyframeTemplate(tracks: [
        AnimationTrack(property: "scale", keys: [
            (.zero, 0.96, .easeOut), (Time(2, 25), 1.02, .easeOut), (Time(7, 25), 1.0, .linear),
        ]),
    ], duration: Time(7, 25), anchor: .start)
}

/// A Caption Look: text style + keyframe animation, played once per caption by its anchor; its `textAnimator` (if any)
/// animates per character / word / line in the monitor and the burn-in alike (W7.3). Saved as a PresetStore `.caption` preset
/// (the host pairs it with the segmentation, `CaptionPreset`).
public struct CaptionLook: Sendable, Hashable, Codable {
    public static let payloadVersion = 1
    public static let popAnimationID = "caption-pop"

    public var style: TextStyle
    public var animation: KeyframeTemplate

    public init(style: TextStyle, animation: KeyframeTemplate) {
        self.style = style; self.animation = animation
    }

    /// Bold white text with drop shadow and the caption pop: what Create Captions applies unless the user picked another look.
    public static let `default` = CaptionLook(style: CaptionPresetLibrary.base.style(for: "default"), animation: .captionPop)

    public static func styleID(for id: String) -> String { "look-\(id)" }
    public static func animationID(for id: String) -> String { "look-\(id)" }

    public func payload() throws -> Data { try JSONEncoder().encode(self) }
    public init(payload: Data, version: Int) throws {
        guard version <= Self.payloadVersion else { throw CaptionLookError.newerVersion }
        self = try JSONDecoder().decode(CaptionLook.self, from: payload)
    }
}

public enum CaptionLookError: Error, Equatable, Sendable { case newerVersion }

/// Process-wide set of user looks (loaded from the preset store at start, updated on save), merged into
/// `CaptionPresetLibrary.builtIn`.
public final class CaptionLookRegistry: @unchecked Sendable {
    public static let shared = CaptionLookRegistry()
    private let lock = NSLock()
    private var looks: [String: CaptionLook] = [:]
    private var kit: StyleKit?
    private var legacyFont = false
    private var cached = CaptionPresetLibrary.base
    private var _version = 0

    public var library: CaptionPresetLibrary { lock.lock(); defer { lock.unlock() }; return cached }

    /// Bumped by every `register`/`unregister` (a cache key for per-project libraries).
    public var version: Int { lock.lock(); defer { lock.unlock() }; return _version }

    /// The library for one project: built-in + the registered looks, resolved through `kit` (not the process-wide kit).
    /// Two open projects with different kits each pass their own, so neither clashes with the other.
    /// `legacyFont`: the project predates the Inter built-ins (`Project.usesLegacyBuiltInFont`).
    public func library(for kit: StyleKit?, legacyFont: Bool = false) -> CaptionPresetLibrary {
        lock.lock(); defer { lock.unlock() }
        return Self.build(looks: looks, kit: kit, legacyFont: legacyFont)
    }

    /// The library `project`'s captions render with: its kit and its generation of built-in styles.
    public func library(for project: Project) -> CaptionPresetLibrary {
        library(for: project.styleKit, legacyFont: project.usesLegacyBuiltInFont)
    }

    /// Registers (or replaces) the look under `id`; returns the (style, animation) refs captions should carry.
    @discardableResult
    public func register(_ look: CaptionLook, id: String) -> (styleRef: String, animationRef: String) {
        lock.lock(); defer { lock.unlock() }
        looks[id] = look
        _version += 1
        rebuild()
        return (CaptionLook.styleID(for: id), CaptionLook.animationID(for: id))
    }

    public func unregister(id: String) {
        lock.lock(); defer { lock.unlock() }
        looks[id] = nil
        _version += 1
        rebuild()
    }

    /// W8.3: the style kit of the project being edited (the session sets it on open and on every kit change). Captions
    /// and saved looks resolve their tokens through it. Returns whether the kit changed.
    @discardableResult
    public func setStyleKit(_ kit: StyleKit?, legacyFont: Bool = false) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard kit != self.kit || legacyFont != self.legacyFont else { return false }
        self.kit = kit
        self.legacyFont = legacyFont
        rebuild()
        return true
    }

    private static func build(looks: [String: CaptionLook], kit: StyleKit?, legacyFont: Bool) -> CaptionPresetLibrary {
        var lib = CaptionPresetLibrary.base(legacyFont: legacyFont)
        for (id, look) in looks { lib = lib.adding(look, id: id) }
        return lib.applying(kit)
    }

    private func rebuild() { cached = Self.build(looks: looks, kit: kit, legacyFont: legacyFont) }
}
