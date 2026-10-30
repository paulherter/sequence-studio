import Foundation
import SQCore
import SQEditorSession

/// Type tool: which text layer lies under a click in the Program monitor. Pure (no session, no undo step): a click on
/// existing text edits it instead of making a second text.
public enum TextHitTest {
    /// Topmost visible text clip under `time` whose drawn rectangle contains `p` (sequence px from the canvas center);
    /// the last video track is the topmost, hidden tracks never hit.
    public static func topmostTextClip(at p: Vec2, in timeline: Timeline, project: Project, time: Time) -> Clip.ID? {
        for track in timeline.tracks.filter({ $0.kind == .video && $0.isVisible }).reversed() {
            for c in track.clips {
                guard let ref = c.generator, ref.kind == GeneratorRef.text,
                      let o = OverlayTarget.make(clip: c, project: project, timeline: timeline, at: time) else { continue }
                if LayerBounds.rect(size: o.size, transform: o.displayTransform).contains(CGPoint(x: p.x, y: p.y)) { return c.id }
            }
        }
        return nil
    }

    /// Topmost visible picture or text clip under `time` whose drawn rectangle contains `p` (a click in the Program
    /// monitor selects it). Audio and hidden tracks never hit; the last video track is the topmost. `accepting` narrows
    /// the clips that count (Magic: video from a file, so a title above the picture does not catch the click).
    public static func topmostVisualClip(at p: Vec2, in timeline: Timeline, project: Project, time: Time,
                                         variant: FormatVariant.ID? = nil, accepting: (Clip) -> Bool = { _ in true }) -> Clip.ID? {
        // Any video track can be hit, not only the targeted one; a hit on a targeted track wins over a higher untargeted one.
        var fallback: Clip.ID?
        for track in timeline.tracks.filter({ $0.kind == .video && $0.isVisible }).reversed() {
            // A graphics clip is picked through its layers (Graphics overlay), not as a canvas-sized box.
            for c in track.clips where c.isEnabled && !c.isGraphics && accepting(c) {
                guard let o = OverlayTarget.make(clip: c, project: project, timeline: timeline, at: time, variant: variant) else { continue }
                if LayerBounds.rect(size: o.size, transform: o.displayTransform).contains(CGPoint(x: p.x, y: p.y)) {
                    if track.isTargeted { return c.id }
                    if fallback == nil { fallback = c.id }
                    break
                }
            }
        }
        return fallback
    }

    /// Whether a hit on track `hit` beats the one already picked on track `picked` (indexes into `tracks`; nil: nothing
    /// picked yet): a targeted track wins over an untargeted one, otherwise the higher track.
    public static func hitWins(_ hit: Int, over picked: Int?, tracks: [Track]) -> Bool {
        guard let picked else { return true }
        let ht = tracks[hit].isTargeted, pt = tracks[picked].isTargeted
        return ht != pt ? ht : hit >= picked
    }
}
