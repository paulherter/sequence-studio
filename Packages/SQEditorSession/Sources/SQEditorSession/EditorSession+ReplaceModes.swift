import Foundation
import SQCore

extension EditorSession {
    /// Fast Cut replace (Clip > Replace at Playhead / from Start / from End / with Retime): the main-track clip `clipID`
    /// plays `mediaID` (its In..Out marks, whole media when unmarked) in one of the four `ReplaceMode`s. The clip keeps
    /// its id, place and length, so nothing ripples. `sourceAnchor` is the media time that sits on the playhead (the
    /// Source monitor position; `.atPlayhead` only, the In mark when nil). Media shorter than the clip is not refused:
    /// the clip gets shorter and the status line says so. One undo step; false = refused (reported).
    @discardableResult
    public func replaceOnMainTrack(_ clipID: Clip.ID, withMedia mediaID: MediaRef.ID, mode: ReplaceMode, sourceAnchor: Time? = nil) -> Bool {
        guard let t = activeTimeline, t.isFastCut else { setError("Replace modes work in a Fast Cut sequence."); return false }
        guard let ref = project.media(mediaID) else { setError("That item is not in the project."); return false }
        guard ref.info?.isStill != true else { setError("A still image has no length to fit: use Replace Clip from Project."); return false }
        guard let total = ref.info?.duration ?? ref.duration else { setError("That item has no known length yet."); return false }
        guard let range = Timeline.sourceEditRange(marks: project.sourceMarks(for: ref.id), total: total) else {
            setError("Nothing to edit: the In and Out points leave no range."); return false
        }
        let fit = ref.info?.video.map { t.format.fitScale(width: $0.displayWidth, height: $0.displayHeight) } ?? 1
        var clips: [Clip] = []
        if ref.info?.video != nil || ref.info == nil {
            var v = Clip(name: ref.name, media: ref.id, kind: .video, source: range, start: .zero, mediaDuration: total)
            if abs(fit - 1) > 1e-12 { v.animation.scale = AnimatedProperty(Vec2(fit, fit)) }
            clips.append(v)
        }
        if ref.info?.audio != nil { clips.append(Clip(name: ref.name, media: ref.id, kind: .audio, source: range, start: .zero, mediaDuration: total)) }
        var outcome: ReplaceOutcome?
        let at = playhead, anchor = sourceAnchor ?? range.start
        guard attempt(mode.title, { tl in
            outcome = try tl.replaceOnMainTrack(clipID, with: clips, mode: mode, playhead: at, sourceAnchor: anchor)
        }) else { return false }
        if let w = outcome?.warning { setError(w) }
        return true
    }
}
