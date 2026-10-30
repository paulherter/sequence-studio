import Foundation

/// How Q / W land an edge on the playhead.
public enum PlayheadTrimMode: Sendable, Hashable {
    /// Q / W: ripple, later clips close the gap.
    case ripple
    /// Shift+Q / Shift+W: the cut between two clips moves to the playhead, the sequence length stays.
    case roll
    /// Opt+Q / Opt+W: plain trim, the gap stays.
    case plain
}

extension Timeline {
    /// Q (`.head`) / W (`.tail`) with a mode. The clip under `t` on each given track (`nil` = all unlocked tracks) gets
    /// that edge moved to `t`. `.ripple` is `rippleTrimToPlayhead`. `.roll` also moves the touching neighbor's edge
    /// (tracks without a touching neighbor are skipped; `.collision` when none could roll). `.plain` leaves a gap. Atomic; linked partners follow.
    /// Returns the edge movement of the first trimmed clip (negative = shortened).
    @discardableResult
    public mutating func trimToPlayhead(_ edge: ClipEdge, at t: Time, tracks ids: [Track.ID]?,
                                        mode: PlayheadTrimMode) throws -> Time {
        if mode == .ripple { return try rippleTrimToPlayhead(edge, at: t, tracks: ids) }
        var targets: [Int] = []
        if let ids {
            for id in ids {
                guard let i = tracks.firstIndex(where: { $0.id == id }) else { throw EditError.clipNotFound }
                if tracks[i].isLocked { throw EditError.trackLocked }
                if !targets.contains(i) { targets.append(i) }
            }
        } else {
            targets = tracks.indices.filter { !tracks[$0].isLocked }
        }
        var picks: [Clip.ID] = []
        for i in targets {
            if let hit = tracks[i].clips.first(where: { c in
                edge == .head ? c.timeline.contains(t) : (c.start < t && t <= c.timeline.end)
            }) { picks.append(hit.id) }
        }
        guard !picks.isEmpty else { throw EditError.clipNotFound }
        var work = self
        var first: Time?
        var done = Set<Clip.ID>()
        var skipped = false
        for id in picks where !done.contains(id) {
            guard let m = work.find(id) else { continue }
            let group = try work.linkedGroup(id).map(\.clip.id)
            if mode == .plain { done.formUnion(group) }
            let delta = edge == .head ? t - m.clip.start : t - m.clip.timeline.end
            let moved: Time
            if mode == .plain {
                moved = try work.trim(id, edge: edge, by: delta)
            } else {
                // Rolling needs a touching neighbor and a real move; tracks without one are skipped.
                let left = work.tracks[m.track].clips.first { $0.timeline.end == m.clip.start }
                let right = work.tracks[m.track].clips.first { $0.start == m.clip.timeline.end }
                guard delta != .zero, edge == .tail ? right != nil : left != nil else { skipped = true; continue }
                moved = try work.roll(edge == .tail ? id : left!.id, by: delta)
            }
            done.formUnion(group)                      // a skipped partner (no touching neighbor) must not block its group
            if first == nil { first = moved }
        }
        if mode == .roll, first == nil { throw skipped ? EditError.collision : EditError.clipNotFound }
        self = work
        return first ?? .zero
    }
}
