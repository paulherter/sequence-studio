import Foundation

public enum MoveMode: Sendable { case overwrite }

/// Option-drag duplicate: identities of the copies (original ID to copy ID; missing = fresh) and the link the copied
/// group shares. Given by the caller so a replayed edit always yields the same IDs.
public struct CopySpec: Sendable, Hashable {
    public var ids: [Clip.ID: Clip.ID]
    public var link: UUID
    public init(ids: [Clip.ID: Clip.ID] = [:], link: UUID = UUID()) { self.ids = ids; self.link = link }
}

/// Non-ripple edits: nothing outside the edited clips (and what they cover) shifts.
extension Timeline {
    private func requireUnlocked(_ group: [Member]) throws {
        if group.contains(where: { tracks[$0.track].isLocked }) { throw EditError.trackLocked }
    }

    private func commit(_ work: [Track]) throws -> [Track] {
        guard work.allSatisfy({ $0.isConsistent }) else { throw EditError.collision }
        return work
    }

    // MARK: Trim

    /// Plain trim. Head + = shorter, tail + = longer. Shortening leaves a gap; extending is clamped by
    /// the neighbour on the track, the media and timeline start 0. Linked partners get the same change;
    /// the applied amount is the most restrictive across the group. Returns how far the edge moved.
    @discardableResult
    public mutating func trim(_ id: Clip.ID, edge: ClipEdge, by delta: Time) throws -> Time {
        let group = try linkedGroup(id)
        try requireUnlocked(group)
        let ids = Set(group.map(\.clip.id))
        var g = edge == .tail ? delta : -delta            // change of duration
        for m in group {
            let c = m.clip
            if g <= -c.duration { throw EditError.emptyClip }
            guard g > .zero else { continue }
            let others = tracks[m.track].clips.filter { !ids.contains($0.id) }
            var room: Time?
            func limit(_ r: Time) { room = room.map { min($0, r) } ?? r }
            if edge == .tail {
                if let r = c.tailRoom { limit(r) }
                if let next = others.first(where: { $0.start >= c.timeline.end }) { limit(next.start - c.timeline.end) }
            } else {
                if let h = c.headHandle { limit(h) }
                limit(c.start)
                let prevEnd = others.filter { $0.timeline.end <= c.start }.map { $0.timeline.end }.max() ?? .zero
                limit(c.start - prevEnd)
            }
            if let room, g > room { g = max(room, .zero) }
        }
        if g == .zero { return .zero }
        var work = tracks
        for m in group {
            var c = m.clip
            if edge == .head { c.start -= g; c.extendHead(by: g) } else { c.extendTail(by: g) }
            work[m.track].replace(c)
        }
        tracks = try commit(work)
        return edge == .tail ? g : -g
    }

    // MARK: Roll

    /// Moves the cut between `id` and the clip directly after it on the same track. Left tail and right
    /// head move by `delta`. Linked partners roll their own cut if it is at the same time position.
    /// Throws `.collision` when `id` has no directly adjacent clip after it.
    @discardableResult
    public mutating func roll(_ id: Clip.ID, by delta: Time) throws -> Time {
        let group = try linkedGroup(id)
        try requireUnlocked(group)
        func right(of m: Member) -> Clip? { tracks[m.track].clips.first { $0.start == m.clip.timeline.end } }
        guard right(of: group[0]) != nil else { throw EditError.collision }
        let cut = group[0].clip.timeline.end
        var pairs: [(track: Int, left: Clip, right: Clip)] = []
        for m in group where m.clip.timeline.end == cut {
            if let r = right(of: m) { pairs.append((m.track, m.clip, r)) }
        }
        var d = delta
        for p in pairs {                                   // media first, then refuse emptying
            if d > .zero, let r = p.left.tailRoom { d = min(d, r) }
            if d < .zero, let h = p.right.headHandle { d = max(d, -h) }
        }
        for p in pairs {
            if d <= -p.left.duration || d >= p.right.duration { throw EditError.emptyClip }
        }
        if d == .zero { return .zero }
        var work = tracks
        for p in pairs {
            var l = p.left, r = p.right
            l.extendTail(by: d)
            r.start += d; r.extendHead(by: .zero - d)
            work[p.track].replace(l); work[p.track].replace(r)
        }
        tracks = try commit(work)
        return d
    }

    // MARK: Slip

    /// Changes which part of the media shows; position and duration stay. Clamped to the media,
    /// partners follow. `delta` is timeline time: the content follows the pointer, so a positive `delta` shows later
    /// source of a forward clip and earlier source of a reversed one (the source moves by `delta * speed`).
    /// Returns the applied `delta`.
    @discardableResult
    public mutating func slip(_ id: Clip.ID, by delta: Time) throws -> Time {
        let group = try linkedGroup(id)
        try requireUnlocked(group)
        var d = delta
        for m in group {
            let c = m.clip
            if c.isGenerator || c.isStill { d = .zero; continue }        // nothing to slip
            let before = c.speed.unscale(c.source.start)                       // room for earlier source
            let after = c.mediaDuration.map { c.speed.unscale($0 - c.source.end) }   // room for later source
            if c.reversed {
                d = min(d, before)
                if let after { d = max(d, .zero - after) }
            } else {
                d = max(d, .zero - before)
                if let after { d = min(d, after) }
            }
        }
        if d == .zero { return .zero }
        var work = tracks
        for m in group {
            var c = m.clip
            c.source.start += c.reversed ? .zero - c.speed.scale(d) : c.speed.scale(d)
            work[m.track].replace(c)
        }
        tracks = try commit(work)
        return d
    }

    // MARK: Move

    /// Moves a clip so it starts at `start` (optionally onto another track of the same kind) and moves
    /// linked partners by the same delta on their own tracks. Covered clips at the destination are
    /// cut or removed. Clamped so nothing starts before 0. Returns the applied delta.
    @discardableResult
    public mutating func move(_ id: Clip.ID, to start: Time, track target: Track.ID? = nil,
                              retarget: [Clip.ID: Track.ID] = [:], mode: MoveMode = .overwrite,
                              copy: CopySpec? = nil) throws -> Time {
        let group = try linkedGroup(id)
        try requireUnlocked(group)
        var destinations = group.map(\.track)
        if let target {
            guard let ti = tracks.firstIndex(where: { $0.id == target }) else { throw EditError.clipNotFound }
            guard tracks[ti].kind == group[0].clip.kind else { throw EditError.wrongTrackKind }
            if tracks[ti].isLocked { throw EditError.trackLocked }
            destinations[0] = ti
        }
        // Linked partners may move to their own tracks (Premiere mirrors a video track change on the audio side).
        for (i, m) in group.enumerated() {
            guard let partnerTarget = retarget[m.clip.id] else { continue }
            guard let ti = tracks.firstIndex(where: { $0.id == partnerTarget }) else { throw EditError.clipNotFound }
            guard tracks[ti].kind == m.clip.kind else { throw EditError.wrongTrackKind }
            if tracks[ti].isLocked { throw EditError.trackLocked }
            destinations[i] = ti
        }
        var d = start - group[0].clip.start
        for m in group { d = max(d, .zero - m.clip.start) }
        if d == .zero && destinations == group.map(\.track) { return .zero }
        var work = tracks
        // Copy (Option-drag): the originals stay, the copies get new identities and one new link per group.
        if copy == nil { for m in group { work[m.track].remove(m.clip.id) } }
        var relinks: [UUID: UUID] = [:]
        for (m, ti) in zip(group, destinations) {
            var c = m.clip
            if let copy {
                c.id = copy.ids[m.clip.id] ?? UUID()
                if c.link != nil { c.link = copy.link }
            }
            c.start += d
            try work[ti].overwrite(c, relinks: &relinks)
        }
        tracks = try commit(work)
        return d
    }
}
