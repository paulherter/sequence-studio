import Foundation
import SQCore
import SQText

/// The maintainer's video title (docs/WORKFLOW-AUDIT.md, step 9): two lines, each its own text clip animated on its own, plus an
/// emoji as a third text clip. The animations are element transitions (Move from the left / right with a fade, Pop on the
/// emoji), so they are swapped or tuned like any transition and only the text is ever retyped.
public enum TitleBuilder {
    public static let placeholderTexts = ["Line One", "Line Two", "🔥"]
    public static let defaultDuration = Time(3, 1)

    public struct Part {
        public var template: TextTemplate
        public var position: Vec2
        public var transition: TransitionKind
        /// Move direction in degrees (270 = in from the left, 90 = from the right); nil for Pop.
        public var direction: Double?
    }

    /// Lines in the upper third, line 2 under line 1, the emoji above line 1. Sizes follow the frame's short side.
    public static func parts(format: SequenceFormat) -> [Part] {
        let short = Double(min(format.displayWidth, format.height)), h = Double(format.height)
        var style = CaptionPresetLibrary.builtIn.style(for: "title")
        style.size = (short * 0.08).rounded()
        style.weight = .heavy
        var emoji = style
        emoji.size = (short * 0.12).rounded()
        emoji.shadow = nil
        let y1 = (-h * 0.22).rounded()
        let t = placeholderTexts
        return [
            Part(template: TextTemplate(name: "Title Line 1", text: t[0], style: style), position: Vec2(0, y1),
                 transition: .move, direction: 270),
            Part(template: TextTemplate(name: "Title Line 2", text: t[1], style: style), position: Vec2(0, y1 + (style.size * 1.25).rounded()),
                 transition: .move, direction: 90),
            Part(template: TextTemplate(name: "Title Emoji", text: t[2], style: emoji), position: Vec2(0, y1 - (emoji.size * 1.3).rounded()),
                 transition: .pop, direction: nil),
        ]
    }
}

extension EditorSession {
    /// UserDefaults key of the Look a text last received (`scope:id`); Add Title starts from it.
    static let lastTextLookKey = "sq.lastTextLook"

    /// The Look a text was last given (nil when none yet, or it was deleted since).
    public func lastUsedTextLook(defaults: UserDefaults = .standard, store: LookStore = .shared) -> LookRef? {
        guard let raw = defaults.string(forKey: Self.lastTextLookKey), let colon = raw.firstIndex(of: ":"),
              let scope = LookScope(rawValue: String(raw[..<colon])) else { return nil }
        let ref = LookRef(scope: scope, id: String(raw[raw.index(after: colon)...]))
        return look(ref, store: store) == nil ? nil : ref
    }

    func rememberTextLook(_ ref: LookRef, defaults: UserDefaults = .standard) {
        defaults.set("\(ref.scope.rawValue):\(ref.id)", forKey: Self.lastTextLookKey)
    }

    /// Sequence > Add Title: ONE Graphic clip at the playhead (DECISIONS 2026-10-11) with the title's text layers (two
    /// lines and an emoji), styled and animated by the last-used Look. It sits on the lowest free video track above
    /// whatever plays there (a new track on top when needed). One undo step; the clip is selected with line 1 as the
    /// selected layer, so typing replaces it. Returns the clip's ID in an array; empty when refused (`lastError` says why).
    @discardableResult
    public func addTitle(at time: Time? = nil, duration: Time = TitleBuilder.defaultDuration,
                         lookDefaults: UserDefaults = .standard, store: LookStore = .shared) -> [Clip.ID] {
        guard let t = activeTimeline else { setError("Open a sequence first."); return [] }
        let look = lastUsedTextLook(defaults: lookDefaults, store: store).flatMap { ref in self.look(ref, store: store).map { (ref, $0) } }
        var layers: [GraphicsLayer] = []
        do {
            for part in TitleBuilder.parts(format: t.format) {
                var template = part.template, anims: AnimationSet?
                if let (ref, l) = look {
                    // The emoji keeps its own size and no shadow; the Look supplies the lines' style.
                    let given = Self.givingLook(l, token: ref.token, to: template, animations: nil)
                    anims = given.animations
                    if part.template.name != "Title Emoji" { template = given.template }
                    else { template.lookID = given.template.lookID }
                }
                var layer = GraphicsLayer.text(try TextGenerator.makeRef(template: template, animations: anims), name: template.text)
                layer.animation.position = AnimatedProperty(part.position)
                layers.append(layer)
            }
        } catch { setError(Self.message(for: error)); return [] }
        let first = layers.first?.id
        guard let id = addGraphicsClip(at: time, duration: duration, layers: layers, neverOverwrite: true) else { return [] }
        if let first { graphicLayerSelection = GraphicLayerSelection(clip: id, layers: [first]) }
        return [id]
    }
}
