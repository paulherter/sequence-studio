import Foundation

extension Timeline {
    // MARK: Insert copy (Cmd+Opt drag)

    /// Cmd+Option drag: inserts a copy of the clip (and its linked partners) at `start` and pushes later clips on the
    /// destination and every sync-locked track right by its length; a clip under the drop point is split. The original
    /// stays. Copies take the identities in `copy` (missing = fresh) and share `copy.link`. `track` retargets the
    /// dragged clip (same kind); partners keep their tracks. Locked tracks refuse.
    public mutating func insertCopy(_ id: Clip.ID, to start: Time, track target: Track.ID? = nil, copy: CopySpec) throws {
        let group = try linkedGroup(id)
        var destinations = group.map { tracks[$0.track].id }
        if let target {
            guard let ti = tracks.firstIndex(where: { $0.id == target }) else { throw EditError.clipNotFound }
            guard tracks[ti].kind == group[0].clip.kind else { throw EditError.wrongTrackKind }
            destinations[0] = target
        }
        let placements: [(clip: Clip, track: Track.ID)] = zip(group, destinations).map { m, dest in
            var c = m.clip
            c.id = copy.ids[m.clip.id] ?? UUID()
            if c.link != nil { c.link = copy.link }
            return (c, dest)
        }
        var work = self
        try work.insert(placements, at: max(start, .zero))
        self = work
    }

    // MARK: Insert move (Cmd-drag)

    /// Cmd-drag: an insert edit with the clip itself. The clip (and linked partners) is lifted from its old place, which
    /// stays as a gap, and inserted at `start`: later clips on the destination and every sync-locked track move right by
    /// its length, a clip under the drop point is split. `start` is a time of the timeline before the edit. (The version
    /// that also closes the old gap is `moveInsert`, the Cmd+Option "rearrange".) Locked tracks refuse.
    public mutating func insertMove(_ id: Clip.ID, to start: Time, track target: Track.ID? = nil) throws {
        let group = try linkedGroup(id)
        if group.contains(where: { tracks[$0.track].isLocked }) { throw EditError.trackLocked }
        var destinations = group.map { tracks[$0.track].id }
        if let target {
            guard let ti = tracks.firstIndex(where: { $0.id == target }) else { throw EditError.clipNotFound }
            guard tracks[ti].kind == group[0].clip.kind else { throw EditError.wrongTrackKind }
            destinations[0] = target
        }
        var work = self
        try work.lift(group.map(\.clip.id))
        try work.insert(zip(group, destinations).map { (clip: $0.clip, track: $1) }, at: max(start, .zero))
        self = work
    }

    // MARK: Duplicate (Shift+Cmd+/)

    /// Copies the clips right after the end of the selection, on the tracks they are on (overwrite). A link survives
    /// only between copies. Returns the new clip IDs (the new selection).
    @discardableResult
    public mutating func duplicate(_ ids: Set<Clip.ID>) throws -> [Clip.ID] {
        guard let cb = clipboard(copying: ids) else { throw EditError.clipNotFound }
        let end = tracks.flatMap(\.clips).filter { ids.contains($0.id) }.map { $0.timeline.end }.max() ?? .zero
        var lanes: [TrackKind: Int] = [:]
        for k in [TrackKind.video, .audio] { if let l = cb.lowestLane(k) { lanes[k] = l } }
        var work = self
        let made = try work.paste(cb, at: end, lanes: lanes)
        self = work
        return made
    }

    // MARK: Move one lane (Opt+Up / Opt+Down)

    /// Moves the clips one track up or down. Video: up = the next higher video track. Audio alone: up = toward the video
    /// side (a lower audio number). With video and audio both in the selection, audio mirrors the video (up = a higher
    /// number), like dragging. Destination clips under a moved clip are cut or removed (overwrite). Returns false, and
    /// changes nothing, when any clip would leave the outermost lane. A locked source or destination track throws.
    @discardableResult
    public mutating func moveToLane(_ ids: Set<Clip.ID>, up: Bool) throws -> Bool {
        let members = ids.compactMap { find($0) }
        guard !members.isEmpty else { throw EditError.clipNotFound }
        if members.contains(where: { tracks[$0.track].isLocked }) { throw EditError.trackLocked }
        let mixed = members.contains { $0.clip.kind == .video } && members.contains { $0.clip.kind == .audio }
        var plan: [(member: Member, dest: Int)] = []
        for m in members {
            let lane = tracks.indices.filter { tracks[$0].kind == m.clip.kind }
            guard let at = lane.firstIndex(of: m.track) else { continue }
            let step: Int
            switch m.clip.kind {
            case .video: step = up ? 1 : -1
            case .audio: step = mixed ? (up ? 1 : -1) : (up ? -1 : 1)
            }
            let to = at + step
            guard lane.indices.contains(to) else { return false }
            plan.append((m, lane[to]))
        }
        if plan.contains(where: { tracks[$0.dest].isLocked }) { throw EditError.trackLocked }
        var work = tracks
        for p in plan { work[p.member.track].remove(p.member.clip.id) }
        var relinks: [UUID: UUID] = [:]
        for p in plan.sorted(by: { $0.member.clip.start < $1.member.clip.start }) {
            try work[p.dest].overwrite(p.member.clip, relinks: &relinks)
        }
        guard work.allSatisfy(\.isConsistent) else { throw EditError.collision }
        tracks = work
        return true
    }
}
