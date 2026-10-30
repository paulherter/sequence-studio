import Foundation

public enum MoveMode: Sendable { case overwrite }

/// What a slip does with the clip's keyframes (animation, effects, masks): follow the media or stay on the timeline.
public enum SlipKeyframes: Sendable, Hashable { case followContent, stay }

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
        var work = work
        work.clearMainTrackAttachments()
        return work
    }

    // MARK: Trim

    /// Plain trim. Head + = shorter, tail + = longer. Shortening leaves a gap; extending is clamped by
    /// the neighbor on the track, the media and timeline start 0. Linked partners get the same change;
    /// the applied amount is the most restrictive across the group. Returns how far the edge moved.
    @discardableResult
    public mutating func trim(_ id: Clip.ID, edge: ClipEdge, by delta: Time) throws -> Time {
        let group = try linkedGroup(id)
        try requireUnlocked(group)
        let ids = Set(group.map(\.clip.id))
        var g = edge == .tail ? delta : -delta            // change of duration
        for m in group {
            let c = m.clip
            g = c.clampingShortening(g, frame: frameDuration)      // intro + outro zones stay whole
            if g <= -c.duration { throw EditError.emptyClip }
            guard g > .zero else { continue }
            let others = tracks[m.track].clips.filter { !ids.contains($0.id) }
            var room: Time?
            func limit(_ r: Time) { room = room.map { min($0, r) } ?? r }
            if edge == .tail {
                if let r = c.tailRoom?.flooredToFrame(frameDuration) { limit(r) }
                if let next = others.first(where: { $0.start >= c.timeline.end }) { limit(next.start - c.timeline.end) }
            } else {
                if let h = c.headHandle?.flooredToFrame(frameDuration) { limit(h) }
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
    /// head move by `delta`. Linked partners of either clip roll their own cut if it is at the same time position; a
    /// partner that ends (left clip's group) or starts (right clip's group) on the cut with no clip on the other side
    /// (a gap) moves its own edge by the same amount, as in Extend Edit, and its gap and media limit the whole edit.
    /// Throws `.collision` when `id` has no directly adjacent clip after it.
    @discardableResult
    public mutating func roll(_ id: Clip.ID, by delta: Time) throws -> Time {
        let right = find(id).flatMap { m in tracks[m.track].clips.first { $0.start == m.clip.timeline.end }?.id }
        return try roll(cut: id, leftPartnersOf: id, rightPartnersOf: right, by: delta, extend: false, partnersFollow: true)
    }

    /// Rolls the cut after `left` (which must have a directly adjacent clip after it). Members of the link group of
    /// `leftPartnersOf` ending on the same cut roll their own cut; so do members of `rightPartnersOf`'s group starting on it.
    /// `extend` (Extend Edit): stop one frame before a side would become empty instead of throwing `.emptyClip`, and a
    /// partner on the cut with no clip on the other side (a gap) moves its own edge by the same amount, so the group stays
    /// in sync; its gap and media limit the whole edit.
    mutating func roll(cut left: Clip.ID, leftPartnersOf leftID: Clip.ID, rightPartnersOf rightID: Clip.ID?, by delta: Time,
                       extend: Bool, partnersFollow: Bool = false) throws -> Time {
        let follow = extend || partnersFollow
        guard let first = find(left) else { throw EditError.clipNotFound }
        let leftGroup = try linkedGroup(leftID)
        let rightGroup = try rightID.map { try linkedGroup($0) } ?? []
        try requireUnlocked(leftGroup + rightGroup)
        let cut = first.clip.timeline.end
        guard tracks[first.track].clips.contains(where: { $0.start == cut }) else { throw EditError.collision }
        // One pair per track: (left clip, right clip) of the cut at `cut`; partners on the cut without a neighbor (extend).
        var pairs: [(track: Int, left: Clip, right: Clip)] = []
        var tails: [(track: Int, clip: Clip)] = [], heads: [(track: Int, clip: Clip)] = []
        func taken(_ track: Int) -> Bool {
            pairs.contains { $0.track == track } || tails.contains { $0.track == track } || heads.contains { $0.track == track }
        }
        for m in leftGroup where m.clip.timeline.end == cut && !taken(m.track) {
            if let r = tracks[m.track].clips.first(where: { $0.start == cut }) { pairs.append((m.track, m.clip, r)) }
            else if follow { tails.append((m.track, m.clip)) }
        }
        for m in rightGroup where m.clip.start == cut && !taken(m.track) {
            if let l = tracks[m.track].clips.first(where: { $0.timeline.end == cut }) { pairs.append((m.track, l, m.clip)) }
            else if follow { heads.append((m.track, m.clip)) }
        }
        var d = delta
        for p in pairs {                                   // media first, then refuse (or limit) emptying
            if d > .zero, let r = p.left.tailRoom?.flooredToFrame(frameDuration) { d = min(d, r) }
            if d < .zero, let h = p.right.headHandle?.flooredToFrame(frameDuration) { d = max(d, -h) }
        }
        let fd = frameDuration
        if extend {
            // Limits only on the side `d` points to, never past zero (a clip under one frame must not reverse the edit).
            for p in pairs {
                if d < .zero { d = max(d, min(.zero, p.left.minimumDuration(frame: fd) - p.left.duration)) }
                if d > .zero { d = min(d, max(.zero, p.right.duration - p.right.minimumDuration(frame: fd))) }
            }
        }
        if follow {
            for (ti, c) in tails {
                if d > .zero {
                    if let r = c.tailRoom?.flooredToFrame(frameDuration) { d = min(d, r) }
                    if let next = tracks[ti].clips.filter({ $0.start >= c.timeline.end && $0.id != c.id }).map(\.start).min() {
                        d = min(d, next - c.timeline.end)
                    }
                }
                if d < .zero { d = max(d, min(.zero, c.minimumDuration(frame: fd) - c.duration)) }
            }
            for (ti, c) in heads {
                if d < .zero {
                    if let h = c.headHandle?.flooredToFrame(frameDuration) { d = max(d, .zero - h) }
                    let prevEnd = tracks[ti].clips.filter { $0.timeline.end <= c.start && $0.id != c.id }.map { $0.timeline.end }.max() ?? .zero
                    d = max(d, prevEnd - c.start)
                }
                if d > .zero { d = min(d, max(.zero, c.duration - c.minimumDuration(frame: fd))) }
            }
        }
        for p in pairs {
            d = p.left.clampingShortening(d, frame: fd)            // intro + outro zones stay whole
            if d > .zero, p.right.animationZoneLengths != nil {
                d = min(d, max(.zero, p.right.duration - p.right.minimumDuration(frame: fd)))
            }
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
        for (ti, c) in tails { var n = c; n.extendTail(by: d); work[ti].replace(n) }
        for (ti, c) in heads { var n = c; n.start += d; n.extendHead(by: .zero - d); work[ti].replace(n) }
        tracks = try commit(work)
        return d
    }

    // MARK: Slip

    /// Changes which part of the media shows; position and duration stay. Clamped to the media,
    /// partners follow. `delta` is timeline time: the content follows the pointer, so a positive `delta` shows later
    /// source of a forward clip and earlier source of a reversed one (the source moves by `delta * speed`).
    /// `keyframes`: `.followContent` (Slip tool) moves the clip's keys with the media so each stays on its source frame;
    /// `.stay` (Slip tool, keyframes stay) leaves them at their timeline position, over the new content.
    /// Returns the applied `delta`.
    @discardableResult
    public mutating func slip(_ id: Clip.ID, by delta: Time, keyframes: SlipKeyframes = .followContent) throws -> Time {
        let group = try linkedGroup(id)
        try requireUnlocked(group)
        var d = delta
        for m in group {
            let c = m.clip
            if c.isGenerator || c.isStill { d = .zero; continue }        // nothing to slip
            if c.speedKeys != nil { d = .zero; continue }                // remapped: the source range is the speed track
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
            if keyframes == .followContent {                  // keys are clip-local: the content moved by -d inside the clip
                c.animation = c.animation.shifted(by: .zero - d)
                c.effects = c.effects.map { $0.shifted(by: .zero - d) }
                c.shiftVariantKeys(by: .zero - d)
            }
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
                c.bundle = nil                       // a copy never joins the original's bundle
            }
            c.start += d
            try work[ti].overwrite(c, relinks: &relinks)
        }
        tracks = try commit(work)
        return d
    }
}
