import Foundation
import SQCore
import SQText

/// The look gallery (`CaptionStyleLooks`) on caption tracks. A gallery look is only refs into `CaptionPresetLibrary`
/// (style, animation) plus a word highlight, set on ONE caption track like every other edit of the Look tab, so each
/// track keeps its own look.
extension EditorSession {
    /// Applies `look` to the caption track `track` (default: the track the Look tab edits, `currentCaptionTrack`): style,
    /// animation and word highlight in one undo step. The captions of that track lose their own style and animation
    /// overrides so the whole track shows the look; other tracks are untouched. False without a caption track.
    @discardableResult
    public func applyCaptionStyleLook(_ look: CaptionStyleLook, track: CaptionTrack.ID? = nil) -> Bool {
        guard let tl = activeTimeline, let target = track.flatMap({ tl.captionTrack($0) }) ?? currentCaptionTrack else { return false }
        let id = target.id
        let items = Set(target.items.map(\.id))
        return attempt("Caption Look") { t in
            try t.setCaptionStyle(styleRef: look.styleRef, animationRef: look.animationRef, track: id)
            try t.setCaptionKaraoke(look.karaoke, track: id)
            try t.setCaptionItemStyle(items, styleRef: nil)
            try t.setCaptionItemAnimation(items, animationRef: nil)
        }
    }

    /// The gallery look the current caption track shows now (nil: none, or edited since).
    public var currentCaptionStyleLook: CaptionStyleLook? {
        guard let t = currentCaptionTrack else { return nil }
        return CaptionStyleLooks.matching(styleRef: t.styleRef, animationRef: t.animationRef, karaoke: t.karaoke)
    }
}
