import Foundation

/// Split points: where linked clips (A/V partners) start or end at different times, as after a J or L cut.
extension Timeline {
    /// Linked groups with at least two clips, as their timeline ranges.
    private func linkedGroups() -> [[TimeRange]] {
        var byLink: [UUID: [TimeRange]] = [:]
        for c in tracks.flatMap(\.clips) { if let l = c.link { byLink[l, default: []].append(c.timeline) } }
        return byLink.values.filter { $0.count > 1 }
    }

    /// Sorted times at which linked partners do not line up (their differing starts and ends).
    public func splitPoints() -> [Time] {
        var pts = Set<Time>()
        for g in linkedGroups() {
            let starts = Set(g.map(\.start)), ends = Set(g.map(\.end))
            if starts.count > 1 { pts.formUnion(starts) }
            if ends.count > 1 { pts.formUnion(ends) }
        }
        return pts.sorted()
    }

    public func nextSplitPoint(after t: Time) -> Time? { splitPoints().first { $0 > t } }
    public func previousSplitPoint(before t: Time) -> Time? { splitPoints().last { $0 < t } }

    /// In/Out for Mark Overhang: the lead (earliest to latest start) or trail (earliest to latest end) of the linked
    /// group under `t` (or holding a clip of `selection`). Picks the one containing `t`, else lead before trail.
    public func markOverhangRange(at t: Time, selection: Set<Clip.ID> = []) -> TimeRange? {
        var linksOfInterest = Set<UUID>()
        let clips = tracks.flatMap(\.clips)
        for c in clips where c.link != nil && (selection.contains(c.id) || (selection.isEmpty && c.timeline.contains(t))) {
            linksOfInterest.insert(c.link!)
        }
        var cands: [TimeRange] = []
        for l in linksOfInterest {
            let g = clips.filter { $0.link == l }.map(\.timeline)
            guard g.count > 1, let s0 = g.map(\.start).min(), let s1 = g.map(\.start).max(),
                  let e0 = g.map(\.end).min(), let e1 = g.map(\.end).max() else { continue }
            if s1 > s0 { cands.append(TimeRange(start: s0, end: s1)) }
            if e1 > e0 { cands.append(TimeRange(start: e0, end: e1)) }
        }
        return cands.first { $0.contains(t) } ?? cands.min { $0.start < $1.start }
    }
}
