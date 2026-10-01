import Foundation

/// Group / Ungroup (Cmd+G / Shift+Cmd+G). A group is a set of clips sharing `Clip.group`. Every edit that already
/// expands a clip to its link partners (`linkedGroup`) now expands to the group as well, so a group selects, moves,
/// nudges, deletes, speeds and copies as one unit and coexists with A/V links (the closure covers both). Trims act on the
/// group's outer edges only (`outerEdgeMembers`). Option-click addresses one member: pass `individual: true`.
extension Timeline {
    /// Groups the clips (plus every clip already grouped with one of them: groups merge, they do not nest). Needs two or
    /// more clips; a locked track refuses. Returns the new group ID.
    @discardableResult
    public mutating func group(_ ids: Set<Clip.ID>) throws -> UUID {
        let picked = ids.compactMap { find($0) }
        guard picked.count >= 2 else { throw EditError.clipNotFound }
        let oldGroups = Set(picked.compactMap(\.clip.group))
        var members = picked
        if !oldGroups.isEmpty {
            let have = Set(picked.map(\.clip.id))
            for (i, t) in tracks.enumerated() {
                for c in t.clips where !have.contains(c.id) && c.group.map(oldGroups.contains) == true {
                    members.append(Member(track: i, clip: c))
                }
            }
        }
        if members.contains(where: { tracks[$0.track].isLocked }) { throw EditError.trackLocked }
        let g = UUID()
        for m in members {
            var c = m.clip; c.group = g
            tracks[m.track].replace(c)
        }
        return g
    }

    /// Ungroups the whole group of every selected clip (Premiere ungroups what is selected). Clips that are not grouped
    /// are ignored; a locked track refuses. A/V links are untouched. Returns the clips that lost their group.
    @discardableResult
    public mutating func ungroup(_ ids: Set<Clip.ID>) throws -> Set<Clip.ID> {
        let groups = Set(ids.compactMap { find($0)?.clip.group })
        guard !groups.isEmpty else { return [] }
        var affected: [Member] = []
        for (i, t) in tracks.enumerated() {
            for c in t.clips where c.group.map(groups.contains) == true { affected.append(Member(track: i, clip: c)) }
        }
        if affected.contains(where: { tracks[$0.track].isLocked }) { throw EditError.trackLocked }
        for m in affected {
            var c = m.clip; c.group = nil
            tracks[m.track].replace(c)
        }
        return Set(affected.map(\.clip.id))
    }

    /// Clears `group` on clips alone in their group (after deletes). Never changes anything else.
    public mutating func dropOrphanGroups() {
        var counts: [UUID: Int] = [:]
        for t in tracks { for c in t.clips { if let g = c.group { counts[g, default: 0] += 1 } } }
        for i in tracks.indices {
            for c in tracks[i].clips where c.group.map({ counts[$0, default: 0] < 2 }) == true {
                var n = c; n.group = nil
                tracks[i].replace(n)
            }
        }
    }

    /// The clips a click selects: the clips plus their group and link partners; just the clips themselves with `individual`
    /// (Option-click). Unknown IDs are dropped.
    public func expandedSelection(_ ids: Set<Clip.ID>, individual: Bool = false) -> Set<Clip.ID> {
        var out = Set<Clip.ID>()
        for id in ids {
            guard let g = try? linkedGroup(id, individual: individual) else { continue }
            for m in g { out.insert(m.clip.id) }
        }
        return out
    }

    /// The members of one group, in track then time order; empty for an unknown ID.
    public func groupMembers(_ group: UUID) -> [Clip.ID] {
        tracks.flatMap(\.clips).filter { $0.group == group }.map(\.id)
    }

    /// Members that take part in a trim of `edge`: everything that is not grouped, and the grouped clips whose edge lies on
    /// the group's outer boundary (earliest start for the head, latest end for the tail). `all.first` is the clicked clip;
    /// callers do nothing when it is not in the result (an inner edge of a group cannot be trimmed).
    func outerEdgeMembers(_ all: [Member], edge: ClipEdge) -> [Member] {
        let grouped = all.filter { $0.clip.group != nil }
        guard !grouped.isEmpty else { return all }
        func at(_ m: Member) -> Time { edge == .head ? m.clip.start : m.clip.timeline.end }
        let outer = edge == .head ? grouped.map(at).min()! : grouped.map(at).max()!
        return all.filter { $0.clip.group == nil || at($0) == outer }
    }
}
