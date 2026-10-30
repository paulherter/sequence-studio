import Foundation
import SQCore

/// Trim mode (TL-08 / TL-09): trims one edit point from the two-up monitor or the keyboard.
extension EditorSession {
    /// The sequence and nested sequences the engine was last given (the two-up monitor's own engines show the same).
    public var pushedSnapshot: (timeline: Timeline, sequences: [Timeline.ID: Timeline])? { pushed }

    /// Moves the edit `frames` later (negative = earlier) on `side`: one undo step per call. Returns how far the edit moved
    /// (zero when media handles, a neighbor or the sequence start blocked it; nothing is recorded then), nil when the
    /// edit was refused (locked track, missing clip: `lastError` says why).
    @discardableResult
    public func trimEdit(_ p: TrimPoint, side: TrimSide, frames n: Int) -> Time? {
        guard var probe = activeTimeline, n != 0 else { return nil }
        let delta = probe.frameDuration * Int64(n)
        let moved: Time
        do { moved = try probe.trimEdit(p, side: side, by: delta) } catch { setError(Self.message(for: error)); return nil }
        if moved == .zero { return .zero }
        let name = side == .roll ? "Move Edit" : "Ripple Trim"
        return attempt(name) { tl in _ = try tl.trimEdit(p, side: side, by: delta) } ? moved : nil
    }
}
