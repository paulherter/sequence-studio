import Foundation

/// Clips copied from a timeline (Cmd+C / Cmd+X). Positions are relative to the earliest copied clip and tracks are
/// stored as a lane (index among the tracks of the same kind, 0 = V1 / A1), so a paste can land on other tracks.
public struct TimelineClipboard: Sendable, Equatable, Codable {
    public struct Entry: Sendable, Equatable, Codable {
        public var clip: Clip
        /// Start relative to the earliest copied clip.
        public var offset: Time
        public var lane: Int
        public init(clip: Clip, offset: Time, lane: Int) { self.clip = clip; self.offset = offset; self.lane = lane }
    }
    public var entries: [Entry]
    /// Transitions whose clips are all part of the copy (a cut between two copied clips, the fades of a copied clip).
    public var transitions: [Transition] = []
    /// C6: source video lane of each track a copied Picture mask reads (keyed by the track id's string), so a paste into a
    /// sequence without that track keeps the matte at the same lane offset (`Clip.remapPictureTrack`). nil = none.
    public var pictureTrackLanes: [String: Int]?
    public init(entries: [Entry], transitions: [Transition] = [], pictureTrackLanes: [String: Int]? = nil) {
        self.entries = entries; self.transitions = transitions; self.pictureTrackLanes = pictureTrackLanes
    }
    public var isEmpty: Bool { entries.isEmpty }
    /// Length from the earliest start to the latest end.
    public var duration: Time { entries.map { $0.offset + $0.clip.timeline.duration }.max() ?? .zero }
    /// Lowest lane per kind (the lane a paste target is aligned to).
    public func lowestLane(_ kind: TrackKind) -> Int? { entries.filter { $0.clip.kind == kind }.map(\.lane).min() }
}

extension Timeline {
    private func laneTracks(_ kind: TrackKind) -> [Track] { tracks.filter { $0.kind == kind } }

    // MARK: Clipboard

    /// Copy of `ids` for the clipboard; nil when none exists.
    public func clipboard(copying ids: Set<Clip.ID>) -> TimelineClipboard? {
        var entries: [TimelineClipboard.Entry] = []
        for k in [TrackKind.video, .audio] {
            for (lane, t) in laneTracks(k).enumerated() {
                for c in t.clips where ids.contains(c.id) { entries.append(.init(clip: c, offset: c.start, lane: lane)) }
            }
        }
        guard let first = entries.map(\.offset).min() else { return nil }
        for i in entries.indices { entries[i].offset = entries[i].offset - first }
        let copied = Set(entries.map(\.clip.id))
        let kept = tracks.flatMap(\.transitions).filter { tr in
            [tr.outgoing, tr.incoming].compactMap { $0 }.allSatisfy(copied.contains)
        }
        return TimelineClipboard(entries: entries, transitions: kept, pictureTrackLanes: pictureTrackLanes(for: entries.map(\.clip)))
    }

    /// Lane a paste of `kind` lands on by default: the lane the clips were copied from (Premiere 22.5+: Cmd+V pastes
    /// onto the source tracks, whatever is targeted). `targetLanes` is the "Paste to Targeted Track" rule.
    public func pasteLane(for kind: TrackKind, in cb: TimelineClipboard) -> Int? { cb.lowestLane(kind) }

    /// "Paste to Targeted Track": per kind in the clipboard, the lowest targeted track of that kind, else the lane the
    /// clips came from. The copy keeps its lane offsets above that track.
    public func targetLanes(for cb: TimelineClipboard) -> [TrackKind: Int] {
        var out: [TrackKind: Int] = [:]
        for k in [TrackKind.video, .audio] {
            guard let low = cb.lowestLane(k) else { continue }
            out[k] = laneTracks(k).firstIndex(where: \.isTargeted) ?? low
        }
        return out
    }

    /// Paste to Targeted Track: `paste` onto `targetLanes` (overwrite or insert).
    @discardableResult
    public mutating func pasteToTargets(_ cb: TimelineClipboard, at t: Time, insert: Bool = false) throws -> [Clip.ID] {
        try paste(cb, at: t, lanes: targetLanes(for: cb), insert: insert)
    }

    /// Latest timeline end of `ids` (where the playhead goes after a paste); nil when none exists.
    public func end(of ids: [Clip.ID]) -> Time? {
        let set = Set(ids)
        return tracks.lazy.flatMap(\.clips).filter { set.contains($0.id) }.map(\.timeline.end).max()
    }

    /// Pastes at `t`: overwrite (default) or insert (Cmd+Shift+V, ripples all ripple tracks). `lanes` overrides the
    /// target lane per kind (the lane the lowest copied clip of that kind lands on); `nil` uses `pasteLane`.
    /// Copies get new IDs; a link survives only between copies. Returns the new clip IDs.
    @discardableResult
    public mutating func paste(_ cb: TimelineClipboard, at t: Time, lanes target: [TrackKind: Int]? = nil,
                               insert: Bool = false) throws -> [Clip.ID] {
        guard !cb.isEmpty else { throw EditError.emptyClip }
        // Up to the next frame, never back: a paste right after an off-frame clip end (Duplicate) must not cut into it.
        let t = max(t.ceiled(to: frameDuration), .zero)
        var shift: [TrackKind: Int] = [:]
        for k in [TrackKind.video, .audio] {
            guard let low = cb.lowestLane(k), let to = target?[k] ?? pasteLane(for: k, in: cb) else { continue }
            shift[k] = to - low
        }
        var linkMap: [UUID: UUID] = [:], bundleMap: [UUID: UUID] = [:]
        var counts: [UUID: Int] = [:], bundleCounts: [UUID: Int] = [:]
        for e in cb.entries { if let l = e.clip.link { counts[l, default: 0] += 1 } }
        for e in cb.entries { if let b = e.clip.bundle { bundleCounts[b, default: 0] += 1 } }
        var placements: [(clip: Clip, track: Track.ID)] = []
        let pictureLanes = cb.pictureLanes
        var newID: [Clip.ID: Clip.ID] = [:]
        // Lanes that do not exist are created (Premiere adds tracks), so clips never stack on one track.
        var work = self
        for k in [TrackKind.video, .audio] {
            let top = cb.entries.filter { $0.clip.kind == k }.map { max($0.lane + (shift[k] ?? 0), 0) }.max() ?? -1
            while work.laneTracks(k).count <= top {
                let at = work.tracks.lastIndex { $0.kind == k }.map { $0 + 1 } ?? work.tracks.count
                work.tracks.insert(Track(kind: k), at: at)
            }
        }
        for e in cb.entries {
            let list = work.laneTracks(e.clip.kind)
            guard !list.isEmpty else { throw EditError.wrongTrackKind }
            let lane = min(max(e.lane + (shift[e.clip.kind] ?? 0), 0), list.count - 1)
            var c = e.clip
            let fresh = UUID()
            newID[e.clip.id] = fresh
            c.id = fresh
            c.start = e.offset                       // relative; placed below
            // Overrides only make sense for this sequence's variants (pasting from another sequence drops the rest).
            if !c.variantOverrides.isEmpty {
                let known = Set(variants.map(\.id))
                c.variantOverrides = c.variantOverrides.filter { known.contains($0.key) }
            }
            if let l = c.link {
                if counts[l, default: 0] > 1 {
                    let n = linkMap[l] ?? UUID()
                    linkMap[l] = n
                    c.link = n
                } else { c.link = nil }
            }
            // A bundle survives only between copies, under a new id (copies never join the original bundle).
            if let b = c.bundle {
                if bundleCounts[b, default: 0] > 1 {
                    let n = bundleMap[b] ?? UUID()
                    bundleMap[b] = n
                    c.bundle = n
                } else { c.bundle = nil }
            }
            if c.kind == .video {
                c = c.remappingPictureTracks(sourceLane: e.lane, sourceLanes: pictureLanes, targetLane: lane,
                                             targetVideoTracks: list.map(\.id))
            }
            placements.append((c, list[lane].id))
        }
        // Fast Cut attachments follow their host's copy; one whose host was not copied is dropped (re-derived later).
        for i in placements.indices where placements[i].clip.attachment != nil { placements[i].clip.remapAttachment(newID) }
        if insert {
            var edited = work
            try edited.insert(placements, at: t)     // `insert` keeps the relative offsets
            self = edited
        } else {
            var relinks: [UUID: UUID] = [:]
            for p in placements {
                guard let i = work.tracks.firstIndex(where: { $0.id == p.track }) else { throw EditError.clipNotFound }
                if work.tracks[i].isLocked { throw EditError.trackLocked }
                var c = p.clip
                c.start = t + p.clip.start
                try work.tracks[i].overwrite(c, relinks: &relinks)
            }
            work.tracks.clearMainTrackAttachments()
            tracks = work.tracks
        }
        // The copied transitions follow their clips (new IDs); anything an overwrite cut apart is pruned again.
        for old in cb.transitions {
            var tr = old
            tr.id = UUID()
            tr.outgoing = old.outgoing.flatMap { newID[$0] }
            tr.incoming = old.incoming.flatMap { newID[$0] }
            guard (old.outgoing == nil) == (tr.outgoing == nil), (old.incoming == nil) == (tr.incoming == nil),
                  let owner = tracks.firstIndex(where: { $0.clip(tr.outgoing ?? tr.incoming ?? UUID()) != nil }) else { continue }
            tracks[owner].transitions.append(tr)
        }
        pruneTransitions()
        return placements.map(\.clip.id)
    }

    // MARK: Gaps

    /// The empty stretch of `track` under `t`: from the previous clip's end (or 0) to the next clip's start.
    /// nil when a clip is there, or when no clip follows (empty space after the last clip is not a gap).
    public func gap(on track: Track.ID, at t: Time) -> TimeRange? {
        guard let tr = self.track(track), !tr.clips.contains(where: { $0.timeline.contains(t) }),
              let next = tr.clips.first(where: { $0.start > t }) else { return nil }
        let prevEnd = tr.clips.filter { $0.timeline.end <= t }.map { $0.timeline.end }.max() ?? .zero
        let r = TimeRange(start: prevEnd, end: next.start)
        return r.isEmpty ? nil : r
    }

    /// Ripple-deletes the gap under `t` on `track` (Premiere: select the gap, Delete). Shifts the track and every
    /// sync-locked track left, as far as nothing collides. Returns the time closed.
    @discardableResult
    public mutating func closeGap(on track: Track.ID, at t: Time) throws -> Time {
        guard let r = gap(on: track, at: t) else { return .zero }
        return try extract(r, tracks: [track])
    }

    // MARK: Link / unlink

    /// Links the clips into one group (Cmd+L). Needs two or more clips; locked tracks refuse.
    public mutating func link(_ ids: Set<Clip.ID>) throws {
        let members = ids.compactMap { find($0) }
        guard members.count >= 2 else { throw EditError.clipNotFound }
        if members.contains(where: { tracks[$0.track].isLocked }) { throw EditError.trackLocked }
        let l = UUID()
        for m in members {
            var c = m.clip; c.link = l
            tracks[m.track].replace(c)
        }
        dropOrphanLinks()
        deriveFastCutAttachments()
    }

    /// Fast Cut: a changed link changes who is attached to whom (a clip linked to a main clip is no attachment, a clip
    /// that lost its main partner attaches by position), so the stored attachments are re-derived.
    mutating func deriveFastCutAttachments() {
        if editMode == .magnetic, mainTrackIndex != nil { deriveAttachments() }
    }

    /// Clears `link` on clips whose link group has fewer than two members.
    public mutating func dropOrphanLinks() {
        var counts: [UUID: Int] = [:]
        for t in tracks { for c in t.clips { if let l = c.link { counts[l, default: 0] += 1 } } }
        for i in tracks.indices {
            for c in tracks[i].clips where c.link.map({ counts[$0, default: 0] < 2 }) == true {
                var n = c; n.link = nil
                tracks[i].replace(n)
            }
        }
    }

    /// Unlinks the selected clips from their partners. A partner left alone loses its link too.
    public mutating func unlink(_ ids: Set<Clip.ID>) throws {
        let members = ids.compactMap { find($0) }
        if members.contains(where: { tracks[$0.track].isLocked }) { throw EditError.trackLocked }
        let affected = Set(members.compactMap(\.clip.link))
        for m in members {
            var c = m.clip; c.link = nil
            tracks[m.track].replace(c)
        }
        for l in affected {
            let rest = tracks.flatMap(\.clips).filter { $0.link == l }
            guard rest.count == 1, let m = find(rest[0].id) else { continue }
            var c = m.clip; c.link = nil
            tracks[m.track].replace(c)
        }
        deriveFastCutAttachments()
    }

    // MARK: Nudge

    /// Moves the clips (and their linked partners) by `delta` on their tracks (Premiere: nudge clip selection).
    /// The whole group moves as one: it never collides with itself, covered neighbors are cut (overwrite).
    /// Clamped so nothing starts before 0. Returns the applied delta.
    @discardableResult
    public mutating func nudge(_ ids: Set<Clip.ID>, by delta: Time) throws -> Time {
        var group: [Member] = []
        var seen = Set<Clip.ID>()
        for id in ids {
            for m in try linkedGroup(id) where seen.insert(m.clip.id).inserted { group.append(m) }
        }
        guard !group.isEmpty else { throw EditError.clipNotFound }
        if group.contains(where: { tracks[$0.track].isLocked }) { throw EditError.trackLocked }
        var d = delta
        for m in group { d = max(d, .zero - m.clip.start) }
        guard d != .zero else { return .zero }
        var work = tracks
        for m in group { work[m.track].remove(m.clip.id) }
        var relinks: [UUID: UUID] = [:]
        for m in group.sorted(by: { $0.clip.start < $1.clip.start }) {
            var c = m.clip; c.start += d
            try work[m.track].overwrite(c, relinks: &relinks)
        }
        tracks = work
        return d
    }
}
