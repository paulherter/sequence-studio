import Foundation
import SQCore

/// The text style a saved title template carries (its first text layer), so a template can be given to an existing text
/// ("select text, click the template, the text takes that style") without placing the template's clip.
/// One system: the template stays a `TitleTemplate`; this only reads its first text layer.
public struct TemplateTextStyle: Sendable, Hashable {
    public var style: TextStyle
    /// The layer's in and out animation (both sides, as authored).
    public var animations: AnimationSet?

    public init(style: TextStyle, animations: AnimationSet?) { self.style = style; self.animations = animations }

    /// The first text layer of `template`: lowest track first, then earliest start; a text layer of a graphics clip
    /// counts like a text clip. Nil when the template has no readable text layer.
    public init?(template: TitleTemplate) {
        var refs: [(Int, Time, Int, GeneratorRef)] = []
        for (ti, track) in template.content.tracks.enumerated() {
            for clip in track.clips {
                if let g = clip.generator, g.kind == GeneratorRef.text { refs.append((ti, clip.start, 0, g)) }
                for (li, layer) in (clip.graphics?.layers ?? []).enumerated() {
                    if case let .text(ref) = layer.content { refs.append((ti, clip.start, li + 1, ref)) }
                }
            }
        }
        refs.sort { ($0.0, $0.1, $0.2) < ($1.0, $1.1, $1.2) }
        for r in refs {
            if let (t, a) = try? TextGenerator.decode(r.3) { self.init(style: t.style, animations: a); return }
        }
        return nil
    }

    /// `template` with this style: text and box stay, the Look token is cleared (the text no longer carries a Look).
    /// A side the template does not animate keeps the text's own animation, like a
    /// Text Motion.
    public func giving(to template: TextTemplate, animations current: AnimationSet?) -> (template: TextTemplate, animations: AnimationSet?) {
        var t = template
        t.style = style
        t.lookID = nil
        let anims: AnimationSet? = animations.map {
            AnimationSet(in: $0.animationIn ?? current?.animationIn, out: $0.animationOut ?? current?.animationOut)
        } ?? current
        return (t, anims)
    }
}
