import Foundation

// Fast Cut: Final Cut differences that need no stored item (the design notes "Fast Cut remaining differences").
// Everything here is derived from positions and attachments, so ProjectFile stays as it is.
//
// - Gap item: a hole on V1 is the host of the clips attached inside it (`mainGaps`, `isGapAttached`). The edit engine
//   keeps such clips when the clip before the hole is deleted (they follow the hole), Delete on the gap deletes them.
// - Storyline: a run of two or more touching attached clips on one non-main track (`storylines`). Create, ripple delete
//   and rearrange work inside the run and never touch the main track.
// - Position move: overwrite without rippling, leaves a hole behind.

/// A hole on the main track with the clips attached to it (v. `Timeline.mainGaps`).
public struct MainGap: Sendable, Hashable {
    public var range: TimeRange
    /// The main clip right before the hole; nil for a hole at the head of the main track.
    public var before: Clip.ID?
    /// The main clip right after the hole.
    public var after: Clip.ID
    /// Clips whose attach time lies in the hole, earliest first.
    public var attached: [Clip.ID]
}

/// A connected storyline: touching attached clips on one lane (v. `Timeline.storylines`).
public struct Storyline: Sendable, Hashable {
    public var track: Track.ID
    public var clips: [Clip.ID]
    public var range: TimeRange
}

extension Timeline {
    // MARK: Gap items

    /// Every hole of the main track (leading hole included, space after the last clip is not one) with the clips attached
    /// in it. Empty in Normal mode.
    public func mainGaps() -> [MainGap] {
        guard isFastCut, let mi = mainTrackIndex else { return [] }
        var d = self
        d.deriveAttachments()
        let main = d.tracks[mi].clips
        let attached = d.tracks.indices.filter { $0 != mi }.flatMap { d.tracks[$0].clips }
            .compactMap { c in c.attachment.map { (c, c.start + $0.point) } }
        var out: [MainGap] = []
        for (k, next) in main.enumerated() {
            let from = k == 0 ? Time.zero : main[k - 1].timeline.end
            guard next.start > from else { continue }
            let r = TimeRange(start: from, end: next.start)
            let inside = attached.filter { r.contains($0.1) }.sorted { $0.1 < $1.1 }.map(\.0.id)
            out.append(MainGap(range: r, before: k == 0 ? nil : main[k - 1].id, after: next.id, attached: inside))
        }
        return out
    }

    /// True when the clip's attach time lies in a hole of the main track (it hangs on the gap, not on a clip).
    public func isGapAttached(_ id: Clip.ID) -> Bool {
        mainGaps().contains { $0.attached.contains(id) }
    }

    // MARK: Storylines

    /// The connected storylines: two or more touching clips on one non-main track, linked partners of main clips left out.
    /// Empty in Normal mode.
    public func storylines() -> [Storyline] {
        guard isFastCut, let mi = mainTrackIndex else { return [] }
        var out: [Storyline] = []
        for (i, t) in tracks.enumerated() where i != mi {
            let clips = t.clips.filter { isAttachable($0.id) }.sorted { $0.start < $1.start }
            var run: [Clip] = []
            func flush() {
                if run.count >= 2 {
                    out.append(Storyline(track: t.id, clips: run.map(\.id),
                                         range: TimeRange(start: run[0].start, end: run[run.count - 1].timeline.end)))
                }
                run = []
            }
            for c in clips {
                if let last = run.last, last.timeline.end != c.start { flush() }
                run.append(c)
            }
            flush()
        }
        return out.sorted { $0.range.start < $1.range.start }
    }

    /// The storyline `id` belongs to; nil for a lone clip, a main clip or a clip that does not exist.
    public func storyline(containing id: Clip.ID) -> Storyline? {
        storylines().first { $0.clips.contains(id) }
    }

    /// Create Storyline (Cmd+G): two or more attached clips of one kind go onto the lane of the earliest one, on their own
    /// frames (a hole between them stays a hole: positions are the truth). Throws `.clipNotFound` for fewer than two
    /// attachable clips, `.wrongTrackKind` for mixed kinds or outside Fast Cut, `.trackLocked`, `.collision` when
    /// something else already sits there.
    public mutating func createStoryline(_ ids: Set<Clip.ID>) throws {
        guard isFastCut else { throw EditError.wrongTrackKind }
        let members = ids.compactMap { find($0) }
        guard members.count >= 2, members.allSatisfy({ isAttachable($0.clip.id) }) else { throw EditError.clipNotFound }
        guard Set(members.map(\.clip.kind)).count == 1 else { throw EditError.wrongTrackKind }
        let home = members.min { $0.clip.start < $1.clip.start }!.track
        var work = self
        try work.relocate(moves: members.map { ($0.clip.id, .zero, home) }, removing: [], withPartners: false)
        work.deriveAttachments()
        self = work
    }

    /// Ripple delete inside a storyline (the connected clips after it close up; the main track and everything outside
    /// the run stay). The clip's linked group leaves with it. Throws `.clipNotFound` when `id` is in no storyline.
    public mutating func storylineRippleDelete(_ id: Clip.ID) throws {
        guard isFastCut else { throw EditError.wrongTrackKind }
        guard let line = storyline(containing: id), let c = find(id)?.clip else { throw EditError.clipNotFound }
        let later = line.clips.drop { $0 != id }.dropFirst()
        var work = self
        let gone = Set((try? linkedGroup(id))?.map(\.clip.id) ?? [id])
        try work.relocate(moves: later.map { ($0, .zero - c.timeline.duration, nil) }, removing: gone, withPartners: true)
        work.deriveAttachments()
        self = work
    }

    /// Rearrange inside a storyline: the clip goes to the storyline edit nearest to `t`, the others close up around it.
    public mutating func storylineRearrange(_ id: Clip.ID, to t: Time) throws {
        guard isFastCut else { throw EditError.wrongTrackKind }
        guard let line = storyline(containing: id), let c = find(id)?.clip else { throw EditError.clipNotFound }
        let others = line.clips.filter { $0 != id }.compactMap { find($0)?.clip }
        // Edit positions of the run without the moved clip, laid back to back from the run start.
        var edges = [line.range.start]
        for o in others { edges.append(edges[edges.count - 1] + o.timeline.duration) }
        let slot = edges.indices.min { a, b in
            let x = edges[a] < t ? t - edges[a] : edges[a] - t, y = edges[b] < t ? t - edges[b] : edges[b] - t
            return x != y ? x < y : a < b
        } ?? 0
        var order = others
        order.insert(c, at: slot)
        var cursor = line.range.start
        var moves: [(Clip.ID, Time, Int?)] = []
        for o in order {
            if o.start != cursor { moves.append((o.id, cursor - o.start, nil)) }
            cursor += o.timeline.duration
        }
        guard !moves.isEmpty else { return }
        var work = self
        try work.relocate(moves: moves, removing: [], withPartners: true)
        work.deriveAttachments()
        self = work
    }

    // MARK: Position move

    /// Position move (FCP's Position tool): the clip (with its linked partners) lands at `t` overwriting what is there and
    /// leaves a hole behind; nothing ripples, attached clips stay on their frames. The main track never gets a hole after
    /// its last clip: `t` is clamped to the end of the others. Normal: the plain overwrite move.
    public mutating func positionMove(_ id: Clip.ID, to t: Time, track: Track.ID? = nil) throws {
        guard isFastCut else { _ = try move(id, to: t, track: track); return }
        guard find(id) != nil, let mi = mainTrackIndex else { throw EditError.clipNotFound }
        var at = max(t, .zero)
        if isMainMaterial(id), track == nil || track == tracks[mi].id {
            let end = tracks[mi].clips.filter { $0.id != id }.map { $0.timeline.end }.max() ?? .zero
            at = min(at, end)
        }
        var work = self
        try work.magneticEdit(involving: [id], stay: .all) { _ = try $0.move(id, to: at, track: track) }
        self = work
    }

    // MARK: Relocation

    /// Moves clips by a delta (and optionally to another track index) without covering anything: they are lifted out,
    /// `removing` is dropped, and each is put back, throwing `.collision` when a clip that stayed is in the way and
    /// `.trackLocked` for a locked lane. `withPartners`: linked partners of a moved clip shift by the same delta on
    /// their own tracks. Transitions leaning on lifted clips come back where both sides are still adjacent.
    fileprivate mutating func relocate(moves: [(id: Clip.ID, delta: Time, track: Int?)], removing: Set<Clip.ID>,
                                       withPartners: Bool) throws {
        struct Item { var clip: Clip; var track: Int }
        var items: [Item] = []
        var seen = Set<Clip.ID>()
        for m in moves {
            guard let found = find(m.id) else { throw EditError.clipNotFound }
            var group = [Member(track: found.track, clip: found.clip)]
            if withPartners, let g = try? linkedGroup(m.id) { group = g }
            for g in group where seen.insert(g.clip.id).inserted && !removing.contains(g.clip.id) {
                var c = g.clip
                c.start += m.delta
                guard c.start >= .zero else { throw EditError.collision }
                var ti = g.track
                if g.clip.id == m.id, let to = m.track {
                    guard tracks[to].kind == c.kind else { throw EditError.wrongTrackKind }
                    ti = to
                }
                if tracks[g.track].isLocked || tracks[ti].isLocked { throw EditError.trackLocked }
                items.append(Item(clip: c, track: ti))
            }
        }
        for id in removing { if let f = find(id), tracks[f.track].isLocked { throw EditError.trackLocked } }
        var work = self
        let stashed = work.liftOut(seen.union(removing))
        for it in items {
            let r = it.clip.timeline
            if work.tracks[it.track].clips.contains(where: { $0.timeline.overlaps(r) }) { throw EditError.collision }
            try work.tracks[it.track].overwrite(it.clip)
        }
        work.restoreMagnetic(stashed)
        guard work.tracks.allSatisfy(\.isConsistent) else { throw EditError.collision }
        self = work
    }
}
