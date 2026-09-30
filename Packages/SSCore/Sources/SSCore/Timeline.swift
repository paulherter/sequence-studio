import Foundation

public enum ClipEdge: Sendable { case head, tail }

/// A sequence of tracks. (Named `Timeline` so it does not shadow `Swift.Sequence`.)
/// Ripple edits work timeline-wide like Premiere: every track with sync lock on shifts together,
/// locked tracks never shift, and an edit that touches a locked track is refused.
public struct Timeline: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var frameDuration: Time
    public var tracks: [Track]

    public init(id: UUID = UUID(), name: String, frameDuration: Time, tracks: [Track] = []) {
        self.id = id; self.name = name; self.frameDuration = frameDuration; self.tracks = tracks
    }

    public func track(_ id: Track.ID) -> Track? { tracks.first { $0.id == id } }

    // MARK: Ripple delete

    /// Deletes clips (and their linked partners) and closes the gap on all tracks that follow ripple.
    /// Other tracks can block the gap: it closes only as far as nothing collides.
    /// Returns the total time closed, summed over the deleted clips.
    @discardableResult
    public mutating func rippleDelete(_ ids: [Clip.ID]) throws -> Time {
        var work = self
        var primaries = try ids.map { id -> Clip in
            guard let c = work.find(id)?.clip else { throw EditError.clipNotFound }
            return c
        }
        primaries.sort { $0.start > $1.start }        // right to left: earlier pivots stay valid
        var closed = Time.zero
        for p in primaries {
            guard work.find(p.id) != nil else { continue }   // already gone with a linked partner
            closed += try work.rippleDeleteOne(p.id)
        }
        self = work
        return closed
    }

    private mutating func rippleDeleteOne(_ id: Clip.ID) throws -> Time {
        let group = try linkedGroup(id)
        let range = group[0].clip.timeline
        let ids = Set(group.map(\.clip.id))
        let involved = try involvedTracks(group)
        var d = range.duration
        for i in involved {
            if let room = tracks[i].leftRoom(pivot: range.end, excluding: ids) { d = min(d, room) }
        }
        for m in group { tracks[m.track].remove(m.clip.id) }
        for i in involved { tracks[i].shift(from: range.end, by: -d) }
        return d
    }

    // MARK: Ripple trim

    /// Moves `edge` of a clip by `delta` (timeline direction: tail + = longer, head + = shorter) and
    /// shifts everything after the clip on all ripple tracks. Linked partners follow.
    /// The clip's start stays put, like Premiere. Clamped by the media, by collisions on other
    /// tracks when shortening, and refuses to empty a clip. Returns how far the edge actually moved.
    @discardableResult
    public mutating func rippleTrim(_ id: Clip.ID, edge: ClipEdge, by delta: Time) throws -> Time {
        let group = try linkedGroup(id)
        let involved = try involvedTracks(group)
        let primary = group[0].clip
        let pivot = primary.timeline.end
        let ids = Set(group.map(\.clip.id))

        var g = edge == .tail ? delta : -delta            // change of duration
        for m in group {
            let c = m.clip
            if g <= -c.source.duration { throw EditError.emptyClip }
            let room: Time? = edge == .tail ? c.mediaDuration.map { $0 - c.source.end } : c.source.start
            if let room, g > room { g = room }
        }
        if g < .zero {
            for i in involved {
                if let room = tracks[i].leftRoom(pivot: pivot, excluding: ids) { g = max(g, -room) }
            }
        }
        if g == .zero { return .zero }

        var work = tracks
        for m in group {
            var c = m.clip
            if edge == .head { c.source.start -= g }
            c.source.duration += g
            work[m.track].replace(c)
        }
        for i in involved { work[i].shift(from: pivot, by: g, excluding: ids) }
        guard work.allSatisfy(\.isConsistent) else { throw EditError.collision }
        tracks = work
        return edge == .tail ? g : -g
    }

    // MARK: Insert

    /// Insert edit: places clips (each on its target track), splits and pushes everything at or
    /// after `at` later by the longest clip on all ripple tracks. Other tracks get a gap.
    public mutating func insert(_ placements: [(clip: Clip, track: Track.ID)], at t: Time) throws {
        guard let d = placements.map(\.clip.timeline.duration).max(), d > .zero else { throw EditError.emptyClip }
        var work = tracks
        var targets = Set<Int>()
        for p in placements {
            guard let i = work.firstIndex(where: { $0.id == p.track }) else { throw EditError.clipNotFound }
            if work[i].isLocked { throw EditError.trackLocked }
            guard p.clip.kind == work[i].kind else { throw EditError.wrongTrackKind }
            targets.insert(i)
        }
        for i in work.indices where targets.contains(i) || work[i].followsRipple {
            try work[i].split(at: t)
            work[i].shift(from: t, by: d)
        }
        for p in placements {
            var c = p.clip; c.start = t
            let i = work.firstIndex { $0.id == p.track }!
            try work[i].overwrite(c)
        }
        tracks = work
    }

    // MARK: Helpers

    struct Member { var track: Int; var clip: Clip }

    func find(_ id: Clip.ID) -> Member? {
        for (i, t) in tracks.enumerated() { if let c = t.clip(id) { return Member(track: i, clip: c) } }
        return nil
    }

    /// The clip first, then every clip sharing its link.
    func linkedGroup(_ id: Clip.ID) throws -> [Member] {
        guard let m = find(id) else { throw EditError.clipNotFound }
        var out = [m]
        if let link = m.clip.link {
            for (i, t) in tracks.enumerated() {
                for c in t.clips where c.link == link && c.id != id { out.append(Member(track: i, clip: c)) }
            }
        }
        return out
    }

    /// Tracks that shift: those following ripple plus the group's own. The group's tracks must be unlocked.
    private func involvedTracks(_ group: [Member]) throws -> [Int] {
        if group.contains(where: { tracks[$0.track].isLocked }) { throw EditError.trackLocked }
        var s = Set(group.map(\.track))
        for i in tracks.indices where tracks[i].followsRipple { s.insert(i) }
        return s.sorted()
    }
}
