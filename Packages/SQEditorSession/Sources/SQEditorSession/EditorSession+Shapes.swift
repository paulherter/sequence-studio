import Foundation
import SQCore

/// Shape clips (W5.2): rectangle, ellipse, line. Their look (size, fill, stroke, corner radius) is the Shape effect, edited
/// and keyframed in Effect Controls like any effect; the outline itself is switched in the Shape section.
extension EditorSession {
    /// Places a shape at `time` (default: playhead) on `track`, else on the topmost unlocked video track that is free
    /// there, sized to the sequence. One undo step; selects the new clip. Returns its ID; a refusal goes to `lastError`.
    @discardableResult
    public func addShapeClip(_ kind: ShapeKind, at time: Time? = nil, track: Track.ID? = nil,
                             duration: Time = Time(5, 1)) -> Clip.ID? {
        guard let t = activeTimeline, let tl = activeTimelineID else { setError("Open a sequence first."); return nil }
        let start = (time ?? playhead).snapped(to: t.frameDuration)
        let duration = max(duration.snapped(to: t.frameDuration), t.frameDuration)
        guard let chosen = Self.generatorTrack(in: t, for: TimeRange(start: start, duration: duration), preferred: track) else {
            setError("There is no video track for the shape."); return nil
        }
        var newID: Clip.ID?
        do {
            try perform("Add \(kind.title)") { p in
                newID = try p.addShapeClip(kind, in: tl, at: start, track: chosen, duration: duration)
            }
        } catch { setError(Self.message(for: error)); return nil }
        if let newID { select(clips: [newID]) }
        return newID
    }

    /// Switches a shape clip's outline (size, colors and keys stay). One undo step.
    public func setShapeKind(_ kind: ShapeKind, for id: Clip.ID) {
        guard let c = activeTimeline?.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id }),
              c.generator?.shapeKind != kind else { return }
        do { try perform("Change Shape") { try $0.setShapeKind(clipID: id, to: kind) } } catch { setError(Self.message(for: error)) }
    }
}
