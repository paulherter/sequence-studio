import Foundation

/// "Selection follows playhead": which clips the playhead is over on the targeted tracks, and how long that answer
/// stays valid (so a playing playhead only re-asks at a clip boundary).
public struct PlayheadFollow: Sendable, Equatable {
    /// Clips under the playhead, one per targeted track at most. Linked partners are added by the caller.
    public var ids: Set<Clip.ID>
    /// The answer holds for every time in `validFrom ..< validUntil` (nil = no later boundary on any targeted track).
    public var validFrom: Time
    public var validUntil: Time?

    public func covers(_ t: Time) -> Bool { t >= validFrom && (validUntil.map { t < $0 } ?? true) }
}

extension Timeline {
    /// The clip under `t` on every targeted track (untargeted tracks never take part, as in Premiere). Nothing
    /// targeted or empty space gives an empty set.
    public func followedClips(at t: Time) -> PlayheadFollow {
        var ids: Set<Clip.ID> = []
        var from = Time.zero
        var until: Time?
        func narrow(_ lo: Time?, _ hi: Time?) {
            if let lo, lo > from { from = lo }
            if let hi, until == nil || hi < until! { until = hi }
        }
        for track in tracks where track.isTargeted {
            var hit: Clip?
            var prevEnd: Time?
            var nextStart: Time?
            for c in track.clips {
                let r = c.timeline
                if r.start <= t, t < r.end { hit = c; break }
                if r.end <= t { if prevEnd == nil || r.end > prevEnd! { prevEnd = r.end } }
                else if r.start > t { if nextStart == nil || r.start < nextStart! { nextStart = r.start } }
            }
            if let hit { ids.insert(hit.id); narrow(hit.timeline.start, hit.timeline.end) }
            else { narrow(prevEnd, nextStart) }
        }
        return PlayheadFollow(ids: ids, validFrom: from, validUntil: until)
    }
}
