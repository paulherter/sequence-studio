import CoreGraphics
import Foundation
import SQCore
import SQText

/// Type tool: which text layer lies under a click in the Program monitor. Pure (no session, no undo step): a click on
/// existing text edits it instead of making a second text.
public enum TextHitTest {
    /// Topmost visible text clip under `time` whose drawn rectangle contains `p` (sequence px from the canvas centre);
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
}
