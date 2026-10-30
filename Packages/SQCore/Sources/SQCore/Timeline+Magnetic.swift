import Foundation

// Fast Cut engine (docs/research/FCP-MAGNETIC-TIMELINE.md, docs/ARCHITECTURE.md "Fast Cut operations"). Fast Cut is the
// stored mode (`editMode == .magnetic`) and decides who follows whom by the stored attachments (ClipAttachment.swift), not
// by sync lock. `magneticEdit` is the one engine every Fast Cut verb (Timeline+MagneticOps.swift) runs through. The old
// session-only Glue switch (2026-10-04) retired into it: there is one system.

extension Timeline {
    /// Timeline time the clip's head moved into its content (positive = head trimmed shorter). Zero for speed ramps.
    private static func magneticHeadShift(_ old: Clip, _ new: Clip) -> Time {
        guard old.speedKeys == nil, new.speedKeys == nil, old.speed == new.speed, old.reversed == new.reversed else { return .zero }
        let d = old.reversed ? old.source.end - new.source.end : new.source.start - old.source.start
        return old.speed.isNormal ? d : old.speed.unscale(d)
    }

    /// Puts an attached clip back without covering anything: its own track when free, else the nearest free unlocked track
    /// of its kind (not the main track; above first), else a new track. Its transitions are put back by `restoreMagnetic`.
    private mutating func placeMagnetic(_ c: Clip, preferring trackID: Track.ID, spine: Track.ID) throws {
        let range = c.timeline
        func free(_ i: Int) -> Bool {
            tracks[i].kind == c.kind && !tracks[i].isLocked && tracks[i].id != spine
                && !tracks[i].clips.contains { $0.timeline.overlaps(range) }
        }
        let home = tracks.firstIndex { $0.id == trackID }
        var target: Int?
        if let home, free(home) { target = home }
        else {
            let origin = home ?? tracks.count
            target = tracks.indices.filter(free).min { a, b in
                let x = abs(a - origin), y = abs(b - origin)
                return x != y ? x < y : a > b
            }
        }
        if target == nil {
            _ = addTrack(kind: c.kind)
            target = tracks.count - 1
        }
        try tracks[target!].overwrite(c)
    }

    /// Puts the transitions of attached clips back after placement. A fade (one side) follows its clip to whatever track it
    /// landed on. A transition between two clips is kept only when both stayed adjacent on one track (the same cut);
    /// when they landed on different tracks or apart, it is dropped deliberately: there is no cut to dissolve over.
    mutating func restoreMagnetic(_ stashed: [Transition]) {
        var touched = Set<Int>()
        for t in stashed {
            let sides = [t.outgoing, t.incoming].compactMap { $0 }
            guard let first = sides.first, let ti = tracks.firstIndex(where: { $0.clip(first) != nil }) else { continue }
            if let o = t.outgoing, let i = t.incoming {
                guard let co = tracks[ti].clip(o), let ci = tracks[ti].clip(i), co.timeline.end == ci.start else { continue }
            }
            tracks[ti].transitions.append(t)
            touched.insert(ti)
        }
        let fd = format.frameDuration
        for ti in touched { tracks[ti].pruneTransitions(frameDuration: fd) }
    }
}

/// What happens to attached clips whose host left the main track and has no surviving piece.
public enum MagneticOrphans: Sendable, Equatable {
    /// Deleted with their host (Delete on a main-track clip, FCP).
    case delete
    /// Stay on their timeline frame and re-attach to the clip now under it.
    case stay
    /// Move like the next surviving main-track clip, never before the end of the one before.
    case follow
}

/// Which attached clips stay on their timeline frame during an edit instead of following their host.
public enum MagneticStay: Sendable, Equatable {
    /// Every attached clip follows its host.
    case none
    /// Every attached clip stays (overwrite, roll, slip, lift: nothing moves along the main track).
    case all
    /// The clips attached to these hosts stay (the "keep attached" override: hold ` while deleting or dragging).
    case hosts(Set<Clip.ID>)
    /// The clips whose attach time lies in this range stay (Delete on a spacer with the override).
    case range(TimeRange)

    func contains(host: Clip.ID, time: Time) -> Bool {
        switch self {
        case .none: false
        case .all: true
        case .hosts(let s): s.contains(host)
        case .range(let r): r.contains(time)
        }
    }
}

extension Timeline {
    private struct AttachedGroup {
        var members: [(track: Track.ID, clip: Clip)]
        var start: Time
        var time: Time                 // attach time
        var host: Clip
        var hostIndex: Int
        var offset: Time { time - host.start }
    }

    /// Runs `edit` with the Fast Cut rules: the attached clips (not in `ids`, not on locked tracks) are taken out, the
    /// edit runs on the main track and the clips it works on (sync lock is on for every unlocked track meanwhile, so
    /// camera audio of later main clips ripples with them; the flags are kept), then every attached group goes back
    /// relative to its host: to the same content frame of the host (a head trim keeps the picture in sync), clamped to
    /// the host; in the hole after it, the same distance after its end; into the piece of the host that now holds the
    /// frame when the edit cut it. `stay` groups keep their timeline frame; a group whose host is gone follows `orphans`.
    /// Groups go back without covering anything: their own track when free, else the nearest free track of their kind
    /// (never the main track, a new track when none is free). Clips the edit made off the main track (pasted, cut halves)
    /// yield to the groups that were there. Then every attachment is re-derived from the positions (host = main clip
    /// under the attach time). Normal mode or no main track: `edit` alone. Throws what `edit` throws; nothing changes then.
    /// `local`: the edit works on the involved clips' own tracks only (trim, roll, slip, slide, nudge of attached clips):
    /// every clip on those tracks stays in the edit as a plain clip, so the involved clips see their neighbors.
    /// A linked group with a member on a locked track keeps its place whole (its unlocked members do not ripple), so
    /// its J/L offset survives.
    @discardableResult
    public mutating func magneticEdit<T>(involving ids: Set<Clip.ID> = [], local: Bool = false, stay: MagneticStay = .none,
                                         orphans: MagneticOrphans = .follow, _ edit: (inout Timeline) throws -> T) throws -> T {
        guard editMode == .magnetic, let mi = mainTrackIndex else { return try edit(&self) }
        var base = self
        base.deriveAttachments()
        let mainID = base.tracks[mi].id
        let mainClips = base.tracks[mi].clips
        let oldMainIDs = Set(mainClips.map(\.id))
        let baseIDs = Set(base.tracks.flatMap { $0.clips.map(\.id) })
        var involved = ids
        let involvedLinks = Set(ids.compactMap { base.find($0)?.clip.link })
        for t in base.tracks { for c in t.clips where c.link.map(involvedLinks.contains) == true { involved.insert(c.id) } }

        // Tracks a local edit works on: their clips are not lifted out.
        let localTracks: Set<Int> = local
            ? Set(base.tracks.indices.filter { i in i != mi && base.tracks[i].clips.contains { involved.contains($0.id) } }) : []
        let mainLinks = Set(mainClips.compactMap(\.link))

        // Attached groups (by link), whole or not at all.
        var byKey: [UUID: [(track: Track.ID, clip: Clip)]] = [:], order: [UUID] = [], refused = Set<UUID>()
        var lockedKeys = Set<UUID>(), workedKeys = Set<UUID>()
        var linkedOff: [UUID: [(track: Track.ID, clip: Clip)]] = [:]     // linked clips off the main track, unlocked
        for (i, t) in base.tracks.enumerated() where i != mi {
            for c in t.clips {
                let key = c.link ?? c.id
                let worked = involved.contains(c.id) || localTracks.contains(i)
                if t.isLocked { lockedKeys.insert(key) }
                if worked { workedKeys.insert(key) }
                if let l = c.link, !t.isLocked, !mainLinks.contains(l) { linkedOff[l, default: []].append((t.id, c)) }
                guard c.attachment != nil else { continue }
                if t.isLocked || worked { refused.insert(key); continue }
                if byKey[key] == nil { order.append(key) }
                byKey[key, default: []].append((t.id, c))
            }
        }
        // A linked group with a member on a locked track stays whole where it is: its unlocked members are set aside
        // during the edit (so they do not ripple away from the locked ones) and go back on their frame.
        let pinned = linkedOff.filter { lockedKeys.contains($0.key) && !workedKeys.contains($0.key) }
            .values.flatMap { $0 }.sorted { $0.clip.start < $1.clip.start }
        var groups: [AttachedGroup] = []
        for key in order where !refused.contains(key) {
            guard let members = byKey[key], let a = members[0].clip.attachment,
                  let hi = mainClips.firstIndex(where: { $0.id == a.host }) else { continue }
            groups.append(AttachedGroup(members: members, start: members.map(\.clip.start).min()!,
                                        time: members[0].clip.start + a.point, host: mainClips[hi], hostIndex: hi))
        }

        var work = base
        let lifted = Set(groups.flatMap { $0.members.map(\.clip.id) } + pinned.map(\.clip.id))
        var stashed = work.liftOut(lifted)
        let syncLocks = Dictionary(uniqueKeysWithValues: work.tracks.map { ($0.id, $0.syncLock) })
        for i in work.tracks.indices { work.tracks[i].syncLock = true }
        let result = try edit(&work)
        for i in work.tracks.indices { work.tracks[i].syncLock = syncLocks[work.tracks[i].id] ?? work.tracks[i].syncLock }

        // Clips the edit made off the main track: they yield to the groups that were there.
        guard let wmi = work.tracks.firstIndex(where: { $0.id == mainID }) else { throw EditError.trackLocked }
        var newcomers: [(track: Track.ID, clip: Clip)] = []
        for (i, t) in work.tracks.enumerated() where i != wmi {
            for c in t.clips where !baseIDs.contains(c.id) && work.isAttachable(c.id) { newcomers.append((t.id, c)) }
        }
        stashed += work.liftOut(Set(newcomers.map(\.clip.id)))

        let newMain = work.tracks[wmi].clips
        func now(_ id: Clip.ID) -> Clip? { newMain.first { $0.id == id } }
        let frame = frameDuration
        let sourcesBefore = Dictionary(uniqueKeysWithValues: mainClips.map { ($0.id, $0.source) })

        /// The timeline time the source frame `offset` into `old` now plays at: a new piece of it (cut by the edit),
        /// else a surviving clip whose source grew over it (joined). Constant-speed, forward clips only.
        func contentPiece(of old: Clip, offset: Time) -> Time? {
            guard old.speedKeys == nil, !old.reversed, offset >= .zero else { return nil }
            let point = old.source.start + (old.speed.isNormal ? offset : old.speed.scale(offset))
            let fresh = newMain.filter { !oldMainIDs.contains($0.id) }
            let grown = newMain.filter { c in sourcesBefore[c.id].map { $0 != c.source } ?? false }
            for p in fresh + grown where p.media == old.media && p.kind == old.kind && p.sequence == old.sequence
                && p.speedKeys == nil && !p.reversed && p.speed == old.speed
                && p.source.start <= point && point < p.source.end {
                let d = point - p.source.start
                return p.start + (p.speed.isNormal ? d : p.speed.unscale(d))
            }
            return nil
        }

        func newTime(_ g: AttachedGroup) -> Time? {
            if stay.contains(host: g.host.id, time: g.time) { return g.time }
            let old = g.host
            if let new = now(old.id) {
                if g.offset < .zero { return new.start + g.offset }                                   // leading hole
                if g.offset >= old.duration { return new.timeline.end + (g.offset - old.duration) }   // hole after it
                let p = new.start + g.offset - Self.contentShift(old, new)
                if p >= new.timeline.end || p < new.start, let piece = contentPiece(of: old, offset: g.offset) { return piece }
                return min(max(p, new.start), max(new.timeline.end - frame, new.start))
            }
            if let piece = contentPiece(of: old, offset: g.offset) { return piece }
            // A clip attached to the hole before or after its host hangs on the gap, not on the host: it survives the
            // host's deletion and moves like the clips after it (`mainGaps`).
            let onGap = g.offset < .zero || g.offset >= old.duration
            switch orphans {
            case .delete where !onGap: return nil
            case .stay: return g.time
            case .delete, .follow:
                let later = mainClips[(g.hostIndex + 1)...].first { now($0.id) != nil }
                let earlier = mainClips[..<g.hostIndex].last { now($0.id) != nil }
                var delta = Time.zero
                if let later, let n = now(later.id) { delta = n.start - later.start }
                else if let earlier, let n = now(earlier.id) { delta = n.timeline.end - earlier.timeline.end }
                var p = g.time + delta
                if let earlier, let n = now(earlier.id) { p = max(p, n.timeline.end) }
                return p
            }
        }

        var placed = work
        // What does not move goes back first, so it keeps its track; then the moved groups, earliest first.
        var moves: [(group: AttachedGroup, by: Time)] = []
        for g in groups {
            guard let t = newTime(g) else { continue }
            var d = t - g.time
            if g.start + d < .zero { d = .zero - g.start }
            moves.append((g, d))
        }
        for p in pinned { try placed.placeMagnetic(p.clip, preferring: p.track, spine: mainID) }
        let ordered = moves.filter { $0.by == .zero }.sorted { $0.group.start < $1.group.start }
            + moves.filter { $0.by != .zero }.sorted { $0.group.start < $1.group.start }
        for (g, d) in ordered {
            for m in g.members {
                var c = m.clip
                c.start += d
                try placed.placeMagnetic(c, preferring: m.track, spine: mainID)
            }
        }
        for n in newcomers.sorted(by: { $0.clip.start < $1.clip.start }) {
            try placed.placeMagnetic(n.clip, preferring: n.track, spine: mainID)
        }
        placed.restoreMagnetic(stashed)
        placed.tracks.clearMainTrackAttachments()
        placed.deriveAttachments()
        guard placed.tracks.allSatisfy(\.isConsistent) else { throw EditError.collision }
        self = placed
        return result
    }

    /// Removes `ids` from their tracks and returns their transitions (those leaning only on them), for `restoreMagnetic`.
    mutating func liftOut(_ ids: Set<Clip.ID>) -> [Transition] {
        guard !ids.isEmpty else { return [] }
        var stashed: [Transition] = []
        for i in tracks.indices {
            for c in tracks[i].clips where ids.contains(c.id) { tracks[i].remove(c.id) }
            let mine = tracks[i].transitions.filter { t in
                [t.outgoing, t.incoming].compactMap { $0 }.allSatisfy(ids.contains) && (t.outgoing != nil || t.incoming != nil)
            }
            if !mine.isEmpty {
                stashed += mine
                tracks[i].transitions.removeAll { t in mine.contains { $0.id == t.id } }
            }
        }
        return stashed
    }

    /// `magneticHeadShift`, zero when the content changed (replace: other media or sequence).
    private static func contentShift(_ old: Clip, _ new: Clip) -> Time {
        guard old.media == new.media, old.sequence == new.sequence else { return .zero }
        return magneticHeadShift(old, new)
    }

    /// Places a clip without covering anything: on `preferring` when free, else the nearest free unlocked track of its
    /// kind (never the main track), else a new track. For the Fast Cut verbs that move clips off the main track.
    mutating func placeAttached(_ c: Clip, preferring trackID: Track.ID) throws {
        guard let main = mainTrackID else { throw EditError.wrongTrackKind }
        try placeMagnetic(c, preferring: trackID, spine: main)
    }
}
