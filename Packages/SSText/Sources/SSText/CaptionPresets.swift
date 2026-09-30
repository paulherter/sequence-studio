import Foundation
import SSCore

/// Resolves the opaque `styleRef` / `animationRef` strings (see SSTranscribe `CaptionPreset`).
/// Unknown or nil refs fall back to the library default.
public struct CaptionPresetLibrary: Sendable {
    public let styles: [String: TextStyle]
    public let animations: [String: KeyframeTemplate]
    public let defaultStyleID: String
    public let defaultAnimationID: String

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

    public static let builtIn: CaptionPresetLibrary = {
        let classic = TextStyle(fontName: "Helvetica", size: 56, weight: .semibold, color: .white,
                                shadow: TextShadow(color: RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.6), offsetX: 0, offsetY: 2, blur: 6),
                                alignment: .center, lineSpacing: 4)
        let box = TextStyle(fontName: "Helvetica", size: 52, weight: .bold, color: .white,
                            background: TextBackground(color: RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.75),
                                                       padding: BoxPadding(horizontal: 20, vertical: 10), cornerRadius: 12),
                            alignment: .center, lineSpacing: 4)
        let outline = TextStyle(fontName: "Helvetica", size: 60, weight: .heavy, color: .white,
                                stroke: TextStroke(color: .black, width: 6), alignment: .center, lineSpacing: 2)
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
        return CaptionPresetLibrary(
            styles: ["default": classic, "classic": classic, "bold-box": box, "outline": outline],
            animations: ["none": .none, "fade": fade, "fade-out": fadeOut, "pop-in": popIn],
            defaultStyleID: "default", defaultAnimationID: "none")
    }()
}
