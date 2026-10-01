import Foundation

public enum ThreePointMode: Sendable { case insert, overwrite }

/// Edit helpers for cutting: lift by id, overwrite, three-point edit, add edit, Q/W, extend edit.
extension Timeline {
    // MARK: Lift by id

    /// Deletes clips and their linked partners and leaves gaps (nothing shifts). Unknown ids throw
    /// `.clipNotFound`; any member on a locked track refuses the whole edit.
    public mutating func lift(_ ids: [Clip.ID]) throws {
        var remove: [(track: Int, id: Clip.ID)] = []
        for id in ids {
            let group = try linkedGroup(id)
            if group.contains(where: { tracks[$0.track].isLocked }) { throw EditError.trackLocked }
            for m in group { remove.append((m.track, m.clip.id)) }
        }
        for r in remove { tracks[r.track].remove(r.id) }
    }

    // MARK: Overwrite

    /// Overwrite edit, mirror of `insert`: placements keep their start offsets relative to the earliest
    /// one, which lands at `at`; whatever they cover is cut or removed, nothing shifts.
    public mutating func overwrite(_ placements: [(clip: Clip, track: Track.ID)], at t: Time) throws {
        guard let first = placements.map(\.clip.start).min() else { throw EditError.emptyClip }
        var work = tracks
        var relinks: [UUID: UUID] = [:]
        for p in placements {
            guard let i = work.firstIndex(where: { $0.id == p.track }) else { throw EditError.clipNotFound }
            if work[i].isLocked { throw EditError.trackLocked }
            guard p.clip.kind == work[i].kind else { throw EditError.wrongTrackKind }
            var c = p.clip; c.start = t + (p.clip.start - first)
            try work[i].overwrite(c, relinks: &relinks)
        }
        tracks = work
    }

    // MARK: Three-point edit

    /// Places `source` of `media` on the target tracks at `t`. One clip per target track (kind follows
    /// the track). When targets include video and audio tracks, all new clips share one fresh link;
    /// a single kind gives unlinked clips. `.insert` ripples like `insert` (sync lock honoured),
    /// `.overwrite` replaces what is covered. `source` must be non-empty, start at or after 0 and end
    /// within `mediaDuration` when given, otherwise `.emptyClip`. `initialScale` (video clips only) is the
    /// Scale property of the new clips (see `SequenceFormat.fitScale`: Scale is relative to source pixels). No targets: `.clipNotFound`.
    public mutating func threePointEdit(source: TimeRange, media: UUID, name: String = "",
                                        mediaDuration: Time? = nil, isStill: Bool = false, initialScale: Double = 1, targets: [Track.ID], at t: Time,
                                        mode: ThreePointMode) throws {
        guard !source.isEmpty, source.start >= .zero else { throw EditError.emptyClip }
        if let md = mediaDuration, source.end > md { throw EditError.emptyClip }
        guard !targets.isEmpty else { throw EditError.clipNotFound }
        var kinds = Set<TrackKind>()
        var placements: [(clip: Clip, track: Track.ID)] = []
        for id in targets {
            guard let tr = track(id) else { throw EditError.clipNotFound }
            kinds.insert(tr.kind)
        }
        let link: UUID? = kinds.count > 1 ? UUID() : nil
        for id in targets {
            let tr = track(id)!
            var clip = Clip(name: name, media: media, kind: tr.kind, source: source, start: .zero,
                            link: link, mediaDuration: mediaDuration, isStill: isStill)
            if tr.kind == .video, abs(initialScale - 1) > 1e-12 { clip.animation.scale = AnimatedProperty(Vec2(initialScale, initialScale)) }
            placements.append((clip, id))
        }
        switch mode {
        case .insert: try insert(placements, at: t)
        case .overwrite: try overwrite(placements, at: t)
        }
    }

    // MARK: Add edit

    private func selectedIndices(_ ids: [Track.ID]?) throws -> [Int] {
        guard let ids else { return tracks.indices.filter { !tracks[$0].isLocked } }
        var out: [Int] = []
        for id in ids {
            guard let i = tracks.firstIndex(where: { $0.id == id }) else { throw EditError.clipNotFound }
            if tracks[i].isLocked { throw EditError.trackLocked }
            if !out.contains(i) { out.append(i) }
        }
        return out
    }

    /// Add edit (Cmd+K): cuts every clip under `t` on the given tracks (`nil` = all unlocked tracks;
    /// an explicitly named locked track throws). Edges and gaps are untouched. The left half keeps the
    /// id; the right halves of one linked group share a fresh link, so each side stays linked.
    /// Returns the ids of the new right halves.
    @discardableResult
    public mutating func addEdit(at t: Time, tracks ids: [Track.ID]?) throws -> [Clip.ID] {
        let targets = try selectedIndices(ids)
        var work = tracks
        var newLinks: [UUID: UUID] = [:]
        var created: [Clip.ID] = []
        for i in targets {
            guard let c = work[i].clips.first(where: { $0.start < t && $0.timeline.contains(t) }) else { continue }
            try work[i].split(at: t)
            guard var right = work[i].clips.first(where: { $0.start == t && $0.id != c.id && $0.media == c.media }) else { continue }
            if let l = c.link {
                let n = newLinks[l] ?? UUID()
                newLinks[l] = n
                right.link = n
                work[i].replace(right)
            }
            created.append(right.id)
        }
        tracks = work
        return created
    }

    // MARK: Mark Clip (X)

    /// Range to mark for "Mark Clip": the union of the clips under `t` on the given tracks (`nil` = all tracks).
    /// `nil` when no clip is under `t`.
    public func markClipRange(at t: Time, tracks ids: [Track.ID]?) -> TimeRange? {
        var result: TimeRange?
        for tr in tracks where ids?.contains(tr.id) ?? true {
            guard let c = tr.clips.first(where: { $0.timeline.contains(t) }) else { continue }
            let r = c.timeline
            result = result.map { TimeRange(start: min($0.start, r.start), end: max($0.end, r.end)) } ?? r
        }
        return result
    }

    // MARK: Q / W

    /// Q (`.head`) / W (`.tail`): ripple-trims the clip under `t` on each given track (`nil` = all
    /// unlocked tracks) so that edge lands on `t`; later clips on ripple tracks shift. Head: the clip
    /// keeps its start, the part before `t` is cut (Premiere). Tracks without a clip under `t` are
    /// skipped; none at all throws `.clipNotFound`. Locked named track: `.trackLocked`.
    /// (a tail trim needs `t` after the clip start). Atomic. Returns the edge movement of the
    /// first trimmed clip (negative = shortened earlier part).
    @discardableResult
    public mutating func rippleTrimToPlayhead(_ edge: ClipEdge, at t: Time, tracks ids: [Track.ID]?) throws -> Time {
        let targets = try selectedIndices(ids)
        var picks: [Clip.ID] = []
        for i in targets {
            let hit = tracks[i].clips.first { c in
                edge == .head ? c.timeline.contains(t) : (c.start < t && t <= c.timeline.end)
            }
            if let hit { picks.append(hit.id) }
        }
        guard !picks.isEmpty else { throw EditError.clipNotFound }
        var work = self
        var first: Time?
        var done = Set<Clip.ID>()
        for id in picks {
            if done.contains(id) { continue }
            guard let m = work.find(id) else { continue }
            for g in try work.linkedGroup(id) { done.insert(g.clip.id) }
            let delta = edge == .head ? t - m.clip.start : t - m.clip.timeline.end
            let moved = try work.rippleTrim(id, edge: edge, by: delta)
            if first == nil { first = moved }
        }
        self = work
        return first ?? .zero
    }

    // MARK: Extend edit

    /// E: moves the selected clip edge to `t`. If the edge touches a neighbour on the same track
    /// (an edit point) it rolls: both sides move, either direction, limited by media and by not
    /// emptying a clip. Otherwise the clip only grows (no-op when `t` lies inside the clip),
    /// limited by the neighbour, the media and time 0; nothing ripples. Linked partners follow.
    /// Returns how far the edge actually moved.
    @discardableResult
    public mutating func extendEdit(_ id: Clip.ID, edge: ClipEdge, to t: Time) throws -> Time {
        guard let m = find(id) else { throw EditError.clipNotFound }
        let c = m.clip
        let others = tracks[m.track].clips
        switch edge {
        case .tail:
            if others.contains(where: { $0.start == c.timeline.end }) {
                return try roll(id, by: t - c.timeline.end)
            }
            let d = t - c.timeline.end
            return d > .zero ? try trim(id, edge: .tail, by: d) : .zero
        case .head:
            if let left = others.first(where: { $0.timeline.end == c.start }) {
                let moved = try roll(left.id, by: t - c.start)
                return moved
            }
            let d = t - c.start
            return d < .zero ? try trim(id, edge: .head, by: d) : .zero
        }
    }
}
