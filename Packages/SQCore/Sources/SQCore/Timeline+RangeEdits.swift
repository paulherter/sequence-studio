import Foundation

/// Range edits (lift / extract), slide and insert-move.
extension Timeline {
    // MARK: Lift / Extract

    func targetIndices(_ ids: [Track.ID]) throws -> [Int] {
        var out: [Int] = []
        for id in ids {
            guard let i = tracks.firstIndex(where: { $0.id == id }) else { throw EditError.clipNotFound }
            if tracks[i].isLocked { throw EditError.trackLocked }
            if !out.contains(i) { out.append(i) }
        }
        return out
    }

    /// The cut `lift` and `extract` share: clears `range` on the tracks at `targets`, then keeps linked groups whole.
    /// A clip cut in two gave its right piece a new link. Its untargeted partners (unlocked tracks) belong to that piece
    /// as well: those overlapping the range are cut with it, so no half stays behind; later ones (on any unlocked
    /// track) just take the new link. Everything else on an untargeted track stays uncut; locked tracks are never
    /// touched. Returns `targets` plus the tracks holding a partner that belongs to a right piece (they move with it
    /// when the range closes). Tracks in `sparing` are left out of the partner rule (Fast Cut: an untargeted main track
    /// never gets a hole; its clip stays whole and keeps the link of the left piece).
    static func clearRange(_ range: TimeRange, in work: inout [Track], targets: [Int], sparing: Set<Int> = []) -> Set<Int> {
        var relinks: [UUID: UUID] = [:]
        for i in targets { work[i].clear(range, relinks: &relinks) }
        var involved = Set(targets)
        guard !relinks.isEmpty else { return involved }
        for j in work.indices where !targets.contains(j) && !work[j].isLocked && !sparing.contains(j) {
            let partners = work[j].clips.filter { $0.link.map { relinks[$0] != nil } == true }
            guard !partners.isEmpty else { continue }
            let ids = Set(partners.map(\.id))
            var only = work[j]
            only.setClips(partners)
            only.clear(range, relinks: &relinks)
            // `clear` moved tail transitions to the right pieces on the copy: keep them.
            work[j].transitions = only.transitions
            work[j].setClips(work[j].clips.filter { !ids.contains($0.id) } + only.clips)
            if only.clips.contains(where: { $0.start >= range.end }) { involved.insert(j) }
        }
        // Later partners (also on targeted and spared tracks: relinking cuts no hole) take the new link of the right
        // piece they belong to.
        for j in work.indices where !work[j].isLocked {
            var hit = false
            let relinked = work[j].clips.map { c -> Clip in
                var c = c
                if c.start >= range.end, let l = c.link, let n = relinks[l] { c.link = n; hit = true }
                return c
            }
            guard hit else { continue }
            work[j].setClips(relinked)
            involved.insert(j)
        }
        return involved
    }

    /// Lift: removes `range` (the In/Out span) from the targeted tracks and leaves a gap. Straddling
    /// clips are cut, clips inside are removed. Nothing shifts. The unlocked, untargeted linked partners of a clip
    /// cut in two are cut with it (`clearRange`, the rule `extract` uses); other untargeted clips are untouched.
    /// A transition between two clips the cut pulled apart is dropped (there is no cut left to dissolve over).
    /// A locked targeted track refuses the whole edit.
    public mutating func lift(_ range: TimeRange, tracks ids: [Track.ID]) throws {
        try lift(range, tracks: ids, sparing: [], pruning: true)
    }

    /// `lift` with the partner rule kept off the tracks in `sparing` (see `clearRange`). `pruning: false` keeps the
    /// transitions for a caller that closes the range afterwards and prunes then.
    mutating func lift(_ range: TimeRange, tracks ids: [Track.ID], sparing: Set<Track.ID>, pruning: Bool) throws {
        guard !range.isEmpty else { return }
        let targets = try targetIndices(ids)
        var work = tracks
        let spared = Set(work.indices.filter { sparing.contains(work[$0].id) && !targets.contains($0) })
        _ = Self.clearRange(range, in: &work, targets: targets, sparing: spared)
        if pruning {
            let fd = format.frameDuration
            for i in work.indices where work[i] != tracks[i] { work[i].pruneTransitions(frameDuration: fd) }
        }
        // Cut times off every frame grid can round (see `Time.init(reducing:_:)`): pieces that no longer fit are refused.
        guard work.allSatisfy(\.isConsistent) else { throw EditError.collision }
        tracks = work
    }

    /// Extract: like `lift`, then closes the gap on the targeted tracks and every unlocked sync-locked
    /// track (locked tracks never move). The gap closes only as far as no track collides.
    /// Returns the time actually closed.
    @discardableResult
    public mutating func extract(_ range: TimeRange, tracks ids: [Track.ID]) throws -> Time {
        try extractDetailed(range, tracks: ids).closed
    }

    /// `extract`, also naming the clamp: the track with the least room and how much of the range stayed open.
    mutating func extractDetailed(_ range: TimeRange, tracks ids: [Track.ID]) throws -> (closed: Time, clamp: RippleClamp?) {
        guard !range.isEmpty else { return (.zero, nil) }
        let targets = try targetIndices(ids)
        var work = tracks
        var involved = Self.clearRange(range, in: &work, targets: targets)
        for i in work.indices where work[i].followsRipple { involved.insert(i) }
        // Untargeted tracks are not cut: a split-edit partner straddling the edit point there moves with its pair.
        let pivot = Self.followingStraddlers(work, Dictionary(uniqueKeysWithValues: involved.map { ($0, range.end) }), excluding: [])
        var d = range.duration
        var limiting: Int?
        for i in involved.sorted() {
            if let room = work[i].leftRoom(pivot: pivot[i]!, excluding: []), room < d { d = room; limiting = i }
        }
        for i in involved { work[i].shift(from: pivot[i]!, by: .zero - d) }
        guard work.allSatisfy(\.isConsistent) else { throw EditError.collision }
        tracks = work
        closeCaptionSpan(TimeRange(start: range.end - d, duration: d))
        return (d, limiting.map { RippleClamp(track: $0, shortfall: range.duration - d) })
    }

    // MARK: Slide

    /// Slides a clip along its track by `delta`. Source range and duration stay; an adjacent previous
    /// clip gets its tail moved, an adjacent next clip its head (a neighbor across a gap is not edited,
    /// the gap just shrinks or grows). Linked partners slide too. Clamped by neighbor handles (a
    /// neighbor never gets shorter than one frame), media ends, gaps and timeline start 0; the most
    /// restrictive member of the group wins. Returns the applied delta.
    @discardableResult
    public mutating func slide(_ id: Clip.ID, by delta: Time) throws -> Time {
        let group = try linkedGroup(id)
        if group.contains(where: { tracks[$0.track].isLocked }) { throw EditError.trackLocked }
        let ids = Set(group.map(\.clip.id))
        let frame = frameDuration
        var d = delta
        for m in group {
            let c = m.clip
            let others = tracks[m.track].clips.filter { !ids.contains($0.id) }
            let prev = others.last { $0.timeline.end <= c.start }
            let next = others.first { $0.start >= c.timeline.end }
            if d < .zero {
                if let p = prev, p.timeline.end == c.start {
                    d = max(d, .zero - max(p.duration - frame, .zero))
                } else {
                    d = max(d, .zero - (c.start - (prev?.timeline.end ?? .zero)))
                }
                if let n = next, n.start == c.timeline.end, let h = n.headHandle?.flooredToFrame(frameDuration) { d = max(d, .zero - h) }
            } else if d > .zero {
                if let n = next, n.start == c.timeline.end {
                    d = min(d, max(n.duration - frame, .zero))
                } else if let n = next {
                    d = min(d, n.start - c.timeline.end)
                }
                if let p = prev, p.timeline.end == c.start, let room = p.tailRoom?.flooredToFrame(frameDuration) {
                    d = min(d, room)
                }
            }
        }
        if d == .zero { return .zero }
        var work = tracks
        for m in group {
            let c = m.clip
            let others = tracks[m.track].clips.filter { !ids.contains($0.id) }
            if var p = others.last(where: { $0.timeline.end <= c.start }), p.timeline.end == c.start {
                p.extendTail(by: d)
                work[m.track].replace(p)
            }
            if var n = others.first(where: { $0.start >= c.timeline.end }), n.start == c.timeline.end {
                n.start += d; n.extendHead(by: .zero - d)
                work[m.track].replace(n)
            }
            var moved = c
            moved.start += d
            work[m.track].replace(moved)
        }
        guard work.allSatisfy(\.isConsistent) else { throw EditError.collision }
        tracks = work
        return d
    }

    // MARK: Insert-move

    /// Insert-move (Cmd-drag): takes the clip (and linked partners) out, closing the source gap like a
    /// ripple delete, and inserts it at `start`, pushing later clips on the destination and all
    /// sync-locked tracks right (a clip under the drop point is split). `start` is in the timeline as
    /// it was before the edit; it is translated for the closed gap. Linked partners keep their start/end offset (J/L cuts): the
    /// earliest-starting member lands at `start`, the others at `start` plus their original offset.
    /// The clip (as dragged) may change track (same kind). Locked tracks refuse.
    public mutating func moveInsert(_ id: Clip.ID, to start: Time, track target: Track.ID? = nil) throws {
        let group = try linkedGroup(id)
        if group.contains(where: { tracks[$0.track].isLocked }) { throw EditError.trackLocked }
        let primary = group[0].clip
        var destinations = group.map { tracks[$0.track].id }
        if let target {
            guard let ti = tracks.firstIndex(where: { $0.id == target }) else { throw EditError.clipNotFound }
            guard tracks[ti].kind == primary.kind else { throw EditError.wrongTrackKind }
            if tracks[ti].isLocked { throw EditError.trackLocked }
            destinations[0] = target
        }
        var work = self
        let closed = try work.rippleDeleteOne(id).closed
        var t = max(start, .zero)
        let range = TimeRange(start: group.map { $0.clip.start }.min()!,
                              end: group.map { $0.clip.timeline.end }.max()!)
        if t >= range.end { t = max(t - closed, .zero) }
        else if t > range.start { t = range.start }
        let placements = zip(group, destinations).map { (clip: $0.clip, track: $1) }
        try work.insert(placements, at: t)
        self = work
    }
}
