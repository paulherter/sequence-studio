import Foundation

/// Range edits (lift / extract), slide and insert-move.
extension Timeline {
    // MARK: Lift / Extract

    private func targetIndices(_ ids: [Track.ID]) throws -> [Int] {
        var out: [Int] = []
        for id in ids {
            guard let i = tracks.firstIndex(where: { $0.id == id }) else { throw EditError.clipNotFound }
            if tracks[i].isLocked { throw EditError.trackLocked }
            if !out.contains(i) { out.append(i) }
        }
        return out
    }

    /// Lift: removes `range` (the In/Out span) from the targeted tracks and leaves a gap. Straddling
    /// clips are cut, clips inside are removed. Nothing shifts. Linked clips are cut on every targeted
    /// track (target both tracks of a linked pair); untargeted tracks are untouched.
    /// A locked targeted track refuses the whole edit.
    public mutating func lift(_ range: TimeRange, tracks ids: [Track.ID]) throws {
        guard !range.isEmpty else { return }
        let targets = try targetIndices(ids)
        for i in targets { tracks[i].clear(range) }
    }

    /// Extract: like `lift`, then closes the gap on the targeted tracks and every unlocked sync-locked
    /// track (locked tracks never move). The gap closes only as far as no track collides.
    /// Returns the time actually closed.
    @discardableResult
    public mutating func extract(_ range: TimeRange, tracks ids: [Track.ID]) throws -> Time {
        guard !range.isEmpty else { return .zero }
        let targets = try targetIndices(ids)
        var work = tracks
        for i in targets { work[i].clear(range) }
        var involved = Set(targets)
        for i in work.indices where work[i].followsRipple { involved.insert(i) }
        var d = range.duration
        for i in involved {
            if let room = work[i].leftRoom(pivot: range.end, excluding: []) { d = min(d, room) }
        }
        for i in involved { work[i].shift(from: range.end, by: .zero - d) }
        guard work.allSatisfy(\.isConsistent) else { throw EditError.collision }
        tracks = work
        return d
    }

    // MARK: Slide

    /// Slides a clip along its track by `delta`. Source range and duration stay; an adjacent previous
    /// clip gets its tail moved, an adjacent next clip its head (a neighbour across a gap is not edited,
    /// the gap just shrinks or grows). Linked partners slide too. Clamped by neighbour handles (a
    /// neighbour never gets shorter than one frame), media ends, gaps and timeline start 0; the most
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
                    d = max(d, .zero - (p.source.duration - frame))
                } else {
                    d = max(d, .zero - (c.start - (prev?.timeline.end ?? .zero)))
                }
                if let n = next, n.start == c.timeline.end { d = max(d, .zero - n.source.start) }
            } else if d > .zero {
                if let n = next, n.start == c.timeline.end {
                    d = min(d, n.source.duration - frame)
                } else if let n = next {
                    d = min(d, n.start - c.timeline.end)
                }
                if let p = prev, p.timeline.end == c.start, let md = p.mediaDuration {
                    d = min(d, md - p.source.end)
                }
            }
        }
        if d == .zero { return .zero }
        var work = tracks
        for m in group {
            let c = m.clip
            let others = tracks[m.track].clips.filter { !ids.contains($0.id) }
            if var p = others.last(where: { $0.timeline.end <= c.start }), p.timeline.end == c.start {
                p.source.duration += d
                work[m.track].replace(p)
            }
            if var n = others.first(where: { $0.start >= c.timeline.end }), n.start == c.timeline.end {
                n.start += d; n.source.start += d; n.source.duration -= d
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
    /// it was before the edit; it is translated for the closed gap. Partners must start together with
    /// the clip (else `.collision`); the clip may change track (same kind). Locked tracks refuse.
    public mutating func moveInsert(_ id: Clip.ID, to start: Time, track target: Track.ID? = nil) throws {
        let group = try linkedGroup(id)
        if group.contains(where: { tracks[$0.track].isLocked }) { throw EditError.trackLocked }
        let primary = group[0].clip
        guard group.allSatisfy({ $0.clip.start == primary.start }) else { throw EditError.collision }
        var destinations = group.map { tracks[$0.track].id }
        if let target {
            guard let ti = tracks.firstIndex(where: { $0.id == target }) else { throw EditError.clipNotFound }
            guard tracks[ti].kind == primary.kind else { throw EditError.wrongTrackKind }
            if tracks[ti].isLocked { throw EditError.trackLocked }
            destinations[0] = target
        }
        var work = self
        let closed = try work.rippleDeleteOne(id)
        var t = max(start, .zero)
        let range = primary.timeline
        if t >= range.end { t = max(t - closed, .zero) }
        else if t > range.start { t = range.start }
        let placements = zip(group, destinations).map { (clip: $0.clip, track: $1) }
        try work.insert(placements, at: t)
        self = work
    }
}
