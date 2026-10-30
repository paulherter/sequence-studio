import Foundation

// Fast Cut verbs (docs/research/FCP-MAGNETIC-TIMELINE.md table 5.6, docs/ARCHITECTURE.md "Fast Cut operations").
// Each verb runs through `magneticEdit` (Timeline+Magnetic.swift) in Fast Cut and is its Normal counterpart otherwise.
// Every verb works on a copy: a throw changes nothing, and one call is one undo step for the caller.
//
// Fast Cut invariants every verb keeps: the main track (V1) never gets a hole except through the spacer verbs (Replace
// with Spacer, Insert Spacer, Lift off Main Track, Clear Range); attached clips never overwrite or get overwritten (a
// collision sends one to the nearest free track); linked groups keep their internal offsets (J/L cuts).

extension Timeline {
    // MARK: Queries

    /// True in a Fast Cut sequence that has a main track (the first video track).
    public var isFastCut: Bool { editMode == .magnetic && mainTrackIndex != nil }

    /// True when `id` is on the main track.
    public func isOnMainTrack(_ id: Clip.ID) -> Bool {
        guard let mi = mainTrackIndex else { return false }
        return tracks[mi].clip(id) != nil
    }

    /// True when `id` belongs to the main track: on it, or linked to a clip on it (camera audio).
    public func isMainMaterial(_ id: Clip.ID) -> Bool { find(id) != nil && mainTrackIndex != nil && !isAttachable(id) }

    /// The main-track clip of `id`: itself on the main track, its linked main clip for camera audio, nil otherwise.
    public func mainClip(of id: Clip.ID) -> Clip.ID? {
        guard let mi = mainTrackIndex, let c = find(id)?.clip else { return nil }
        if tracks[mi].clip(id) != nil { return id }
        guard let l = c.link else { return nil }
        return tracks[mi].clips.first { $0.link == l }?.id
    }

    /// The clips attached to `hosts` (attachments derived from the positions first), linked partners included.
    public func attachedClips(of hosts: Set<Clip.ID>) -> [Clip.ID] {
        var d = self
        d.deriveAttachments()
        return d.tracks.flatMap(\.clips).filter { $0.attachment.map { hosts.contains($0.host) } ?? false }.map(\.id)
    }

    /// Where a main-track clip dropped at `t` goes: the nearest edit of the main track (`moving`'s own edges left out),
    /// so a rearrange never cuts a clip in two. `t` itself when there is none.
    public func mainTrackDropPoint(_ t: Time, moving id: Clip.ID? = nil) -> Time {
        guard let mi = mainTrackIndex else { return t }
        let edges = tracks[mi].clips.filter { $0.id != id }.flatMap { [$0.start, $0.timeline.end] }
        return edges.min { a, b in
            let x = a < t ? t - a : a - t, y = b < t ? t - b : b - t
            return x != y ? x < y : a < b
        } ?? t
    }

    /// End of the main track (its last clip's end), zero when empty or missing.
    public var mainTrackEnd: Time { mainTrackIndex.map { tracks[$0].end } ?? .zero }

    // MARK: Building blocks

    /// Opens a hole of `d` at `t` on the main track: the main clip under `t` (with its linked partners running through
    /// `t`) is cut, every main clip from `t` on moves right with its linked partners (`rippleMain`). Captions open too.
    /// Normal: V1 and every sync-locked track are cut at `t` and open from there.
    mutating func openMainHole(at t: Time, by d: Time) throws {
        guard let mi = mainTrackIndex, d > .zero else { return }
        if tracks[mi].isLocked { throw EditError.trackLocked }
        guard isFastCut else {
            var work = tracks
            var relinks: [UUID: UUID] = [:]
            for i in work.indices where i == mi || work[i].followsRipple {
                try work[i].split(at: t, relinks: &relinks)
                work[i].shift(from: t, by: d)
            }
            guard work.allSatisfy(\.isConsistent) else { throw EditError.collision }
            tracks = work
            openCaptionGap(at: t, by: d)
            return
        }
        var work = self
        try work.splitMain(at: t)
        try work.rippleMain(from: t, by: d)
        self = work
    }

    /// Fast Cut placement of material that lands in a hole just opened on the main track: main-track clips overwrite
    /// (the hole is theirs), the others go on their track when free, else the nearest free track of their kind.
    mutating func placeInMainHole(_ placements: [(clip: Clip, track: Track.ID)]) throws {
        guard let main = mainTrackID else { throw EditError.wrongTrackKind }
        for p in placements.sorted(by: { $0.clip.start < $1.clip.start }) {
            if p.clip.start < .zero { throw EditError.collision }
            if p.track == main {
                guard let i = tracks.firstIndex(where: { $0.id == main }) else { throw EditError.clipNotFound }
                try tracks[i].overwrite(p.clip)
            } else {
                try placeAttached(p.clip, preferring: p.track)
            }
        }
        tracks.clearMainTrackAttachments()
    }

    /// Fast Cut insert of `placements` at `t` (their relative offsets kept; the main-track ones start at `t`): V1 opens
    /// by the main-track material's length, the rest never cuts anything (`placeInMainHole`).
    mutating func insertOnMain(_ placements: [(clip: Clip, track: Track.ID)], at t: Time) throws {
        guard let main = mainTrackID else { throw EditError.wrongTrackKind }
        let onMain = placements.filter { $0.track == main }.map(\.clip)
        guard let lo = onMain.map(\.start).min(), let hi = onMain.map({ $0.timeline.end }).max() else { throw EditError.wrongTrackKind }
        try openMainHole(at: t, by: hi - lo)
        try placeInMainHole(placements.map { p in var c = p.clip; c.start = t + (c.start - lo); return (c, p.track) })
    }

    /// Fast Cut rearrange: `id` (a main-track clip) and its linked partners leave V1 (it closes by the clip's length) and
    /// go in at `drop` (pre-edit time, a V1 edit), V1 opening by the same length; partners keep their offsets (J/L).
    mutating func rearrangeMain(_ id: Clip.ID, to drop: Time) throws {
        guard let mi = mainTrackIndex, let v = tracks[mi].clip(id) else { throw EditError.clipNotFound }
        let group = try linkedGroup(id)
        let homes = group.map { tracks[$0.track].id }
        var work = self
        try work.rippleDeleteMain([id])
        let at = drop >= v.timeline.end ? drop - v.timeline.duration : min(drop, v.start)
        try work.openMainHole(at: at, by: v.timeline.duration)
        try work.placeInMainHole(zip(group, homes).map { m, home in var c = m.clip; c.start = at + (c.start - v.start); return (c, home) })
        self = work
    }

    /// Fast Cut ripple: the main-track clips starting at or after `pivot` move by `d`, each with its linked partners on
    /// the other tracks wherever those start (a J cut's early audio goes along), so V1 closes or opens by exactly `d`
    /// and no pair is pulled apart. Throws `.trackLocked` when a clip to move is on a locked track, `.collision` when the
    /// result overlaps. Captions, markers and In/Out follow. Returns the moved ids.
    @discardableResult
    mutating func rippleMain(from pivot: Time, by d: Time) throws -> Set<Clip.ID> {
        guard let mi = mainTrackIndex, d != .zero else { return [] }
        let movers = tracks[mi].clips.filter { $0.start >= pivot }
        guard !movers.isEmpty else { return [] }
        let links = Set(movers.compactMap(\.link))
        // A link with main clips on both sides of the pivot (rare): only its partners from the pivot on move.
        let split = links.intersection(tracks[mi].clips.filter { $0.start < pivot }.compactMap(\.link))
        func follows(_ c: Clip) -> Bool {
            guard let l = c.link, links.contains(l) else { return false }
            return !split.contains(l) || c.start >= pivot
        }
        var moved = Set(movers.map(\.id))
        var work = tracks
        for i in work.indices {
            var changed = false
            let clips = work[i].clips.map { c -> Clip in
                guard i == mi ? c.start >= pivot : follows(c) else { return c }
                changed = true
                moved.insert(c.id)
                var n = c
                n.start += d
                return n
            }
            if changed {
                if work[i].isLocked { throw EditError.trackLocked }
                if clips.contains(where: { $0.start < .zero }) { throw EditError.collision }
                work[i].setClips(clips)
            }
        }
        guard work.allSatisfy(\.isConsistent) else { throw EditError.collision }
        tracks = work
        if d < .zero { closeCaptionSpan(TimeRange(start: pivot + d, duration: .zero - d)) } else { openCaptionGap(at: pivot, by: d) }
        return moved
    }

    /// Shifts the clips at or after `pivot` on the given tracks (off V1, not in `moved`) by `d`, each with its linked
    /// partners on the other tracks off V1, so no pair is pulled apart; a link whose V1 partner did not move stays.
    /// Throws `.trackLocked` when a clip to move is on a locked track, `.collision` when the result overlaps.
    mutating func shiftOffMain(from pivot: Time, by d: Time, tracks ids: [Track.ID], excluding moved: Set<Clip.ID>) throws {
        guard let mi = mainTrackIndex, d != .zero else { return }
        let stayingLinks = Set(tracks[mi].clips.filter { !moved.contains($0.id) }.compactMap(\.link))
        var links = Set<UUID>(), single = Set<Clip.ID>()
        for (i, t) in tracks.enumerated() where i != mi && ids.contains(t.id) {
            for c in t.clips where c.start >= pivot && !moved.contains(c.id) {
                if let l = c.link { if !stayingLinks.contains(l) { links.insert(l) } } else { single.insert(c.id) }
            }
        }
        guard !links.isEmpty || !single.isEmpty else { return }
        var work = tracks
        for i in work.indices where i != mi {
            var changed = false
            let clips = work[i].clips.map { c -> Clip in
                guard !moved.contains(c.id), single.contains(c.id) || c.link.map(links.contains) == true else { return c }
                changed = true
                var n = c
                n.start += d
                return n
            }
            if changed {
                if work[i].isLocked { throw EditError.trackLocked }
                if clips.contains(where: { $0.start < .zero }) { throw EditError.collision }
                work[i].setClips(clips)
            }
        }
        guard work.allSatisfy(\.isConsistent) else { throw EditError.collision }
        tracks = work
    }

    /// Fast Cut ripple delete of main-track clips: each goes with its linked partners and V1 closes by the main clip's
    /// own length (not the group's span: J/L cuts and trimmed audio never leave a hole), later clips taking their
    /// partners along (`rippleMain`). Right to left. Returns the time closed.
    @discardableResult
    mutating func rippleDeleteMain(_ ids: Set<Clip.ID>) throws -> Time {
        guard let mi = mainTrackIndex else { throw EditError.wrongTrackKind }
        var work = self
        var closed = Time.zero
        for c in tracks[mi].clips.filter({ ids.contains($0.id) }).sorted(by: { $0.start > $1.start }) {
            let group = try work.linkedGroup(c.id)
            if group.contains(where: { work.tracks[$0.track].isLocked }) { throw EditError.trackLocked }
            for m in group { work.tracks[m.track].remove(m.clip.id) }
            try work.rippleMain(from: c.timeline.end, by: .zero - c.timeline.duration)
            closed += c.timeline.duration
        }
        work.pruneTransitions()
        self = work
        return closed
    }

    /// Fast Cut ripple trim of a main-track clip (head + = shorter, tail + = longer; the clip's start stays). V1 ripples
    /// from the clip's end by the change (`rippleMain`: later main clips take their partners along, earlier pairs stay).
    /// A head trim trims every linked partner (content stays in sync, starts stay, so J/L offsets hold); a tail trim
    /// only the partners ending with the clip (a J/L tail stays). Clamped by the media and, when lengthening, by the
    /// next clip that does not move on a partner's track. Returns how far the edge moved.
    mutating func rippleTrimMain(_ id: Clip.ID, edge: ClipEdge, by delta: Time) throws -> Time {
        guard let mi = mainTrackIndex, let v = tracks[mi].clip(id) else { throw EditError.clipNotFound }
        let group = try linkedGroup(id)
        if group.contains(where: { tracks[$0.track].isLocked }) { throw EditError.trackLocked }
        let trimmed = group.filter { edge == .head || $0.clip.timeline.end == v.timeline.end }
        let ids = Set(trimmed.map(\.clip.id))
        var g = edge == .tail ? delta : .zero - delta       // change of duration
        for m in trimmed {
            g = m.clip.clampingShortening(g, frame: frameDuration)
            if g <= .zero - m.clip.duration { throw EditError.emptyClip }
            if let room = edge == .tail ? m.clip.tailRoom?.flooredToFrame(frameDuration) : m.clip.headHandle?.flooredToFrame(frameDuration), g > room { g = max(room, .zero) }
        }
        let pivot = v.timeline.end
        if g > .zero {
            var probe = self
            let movers = try probe.rippleMain(from: pivot, by: g)
            for m in trimmed where m.track != mi {
                let end = m.clip.timeline.end
                let next = tracks[m.track].clips.filter { !ids.contains($0.id) && !movers.contains($0.id) && $0.start >= end }
                if let n = next.map(\.start).min(), g > n - end { g = n - end }
            }
        }
        if g == .zero { return .zero }
        var work = self
        if g > .zero { try work.rippleMain(from: pivot, by: g) }
        for m in trimmed {
            var c = m.clip
            if edge == .head { c.extendHead(by: g) } else { c.extendTail(by: g) }
            work.tracks[m.track].replace(c)
        }
        if g < .zero { try work.rippleMain(from: pivot, by: g) }
        guard work.tracks.allSatisfy(\.isConsistent) else { throw EditError.collision }
        self = work
        return edge == .tail ? g : .zero - g
    }

    /// Cuts the main clip strictly under `t` and those of its linked partners that run through `t` (the right halves
    /// share a fresh link). Nothing when `t` is on an edit.
    mutating func splitMain(at t: Time) throws {
        guard let mi = mainTrackIndex, let under = tracks[mi].clips.first(where: { $0.start < t && $0.timeline.contains(t) }) else { return }
        let group = try linkedGroup(under.id)
        if group.contains(where: { tracks[$0.track].isLocked }) { throw EditError.trackLocked }
        var relinks: [UUID: UUID] = [:]
        var work = tracks
        for m in group where m.clip.start < t && m.clip.timeline.contains(t) { try work[m.track].split(at: t, relinks: &relinks) }
        tracks = work
    }

    /// Places a new clip off the main track without covering anything: the lowest free unlocked track of its kind (for
    /// audio not the first audio track, which carries the main track's sound), else a new track.
    mutating func placeNew(_ c: Clip) throws {
        let mi = mainTrackIndex
        let firstAudio = tracks.firstIndex { $0.kind == .audio }
        let range = c.timeline
        let free = tracks.indices.filter { i in
            tracks[i].kind == c.kind && i != mi && !tracks[i].isLocked && (c.kind == .video || i != firstAudio)
                && !tracks[i].clips.contains { $0.timeline.overlaps(range) }
        }
        if let i = free.min() { try tracks[i].overwrite(c); return }
        addTrack(kind: c.kind)
        try tracks[tracks.count - 1].overwrite(c)
    }

    /// Source clips as placements: video on the main track, audio on the first audio track (made when missing).
    private mutating func sourcePlacements(_ clips: [Clip]) throws -> [(clip: Clip, track: Track.ID)] {
        guard let main = mainTrackID else { throw EditError.wrongTrackKind }
        return clips.map { c in
            var c = c
            c.attachment = nil
            switch c.kind {
            case .video: return (c, main)
            case .audio: return (c, tracks.first { $0.kind == .audio }?.id ?? addTrack(kind: .audio))
            }
        }
    }

    private func requireUnlockedMain() throws {
        if let mi = mainTrackIndex, tracks[mi].isLocked { throw EditError.trackLocked }
    }

    // MARK: Source edits

    /// Append to Main Track (E): after the last main-track clip. Audio-only sources attach at `playhead` instead.
    /// Normal: an insert at the end of V1. Returns the new clip ids.
    @discardableResult
    public mutating func appendToMainTrack(_ clips: [Clip], playhead: Time) throws -> [Clip.ID] {
        if isFastCut, !clips.contains(where: { $0.kind == .video }) { return try attach(clips, at: playhead) }
        return try insertOnMainTrack(clips, at: mainTrackEnd)
    }

    /// Normal source edit placements: video on the lowest targeted video track, audio on the lowest targeted audio
    /// track (the first track of the kind when none is targeted; made when missing), like a Normal insert / overwrite.
    private mutating func targetedPlacements(_ clips: [Clip]) -> [(clip: Clip, track: Track.ID)] {
        clips.map { c in
            let track = tracks.first { $0.kind == c.kind && $0.isTargeted }?.id ?? tracks.first { $0.kind == c.kind }?.id
                ?? addTrack(kind: c.kind)
            return (c, track)
        }
    }

    /// Insert (W): the clips go onto the main track at `t` (cut there, everything later ripples; attached clips stay
    /// with their content). Video on V1, audio on the first audio track, linked as given. Fast Cut: `t` past the end of
    /// V1 is its end (no hole); audio-only sources attach. Normal: `insert` on the targeted tracks. Returns the new ids.
    @discardableResult
    public mutating func insertOnMainTrack(_ clips: [Clip], at t: Time) throws -> [Clip.ID] {
        guard !clips.isEmpty else { throw EditError.emptyClip }
        guard isFastCut else {
            var work = self
            let p = work.targetedPlacements(clips)
            try work.insert(p, at: t)
            self = work
            return clips.map(\.id)
        }
        guard clips.contains(where: { $0.kind == .video }) else { return try attach(clips, at: t) }
        var work = self
        let at = isFastCut ? min(max(t, .zero), mainTrackEnd) : t
        let p = try work.sourcePlacements(clips)
        try work.magneticEdit { try $0.insertOnMain(p, at: at) }
        self = work
        return p.map(\.clip.id)
    }

    /// Overwrite (D): the clips cover the main track from `t`; nothing ripples, attached clips stay on their frame and
    /// re-attach to whatever is under them now. Fast Cut: `t` past the end of V1 is its end; audio-only sources attach.
    /// Normal: `overwrite` on the targeted tracks.
    @discardableResult
    public mutating func overwriteOnMainTrack(_ clips: [Clip], at t: Time) throws -> [Clip.ID] {
        guard !clips.isEmpty else { throw EditError.emptyClip }
        guard isFastCut else {
            var work = self
            let p = work.targetedPlacements(clips)
            try work.overwrite(p, at: t)
            self = work
            return clips.map(\.id)
        }
        guard clips.contains(where: { $0.kind == .video }) else { return try attach(clips, at: t) }
        var work = self
        let at = isFastCut ? min(max(t, .zero), mainTrackEnd) : t
        let p = try work.sourcePlacements(clips)
        try work.magneticEdit(stay: .all) { try $0.overwrite(p, at: at) }
        self = work
        return p.map(\.clip.id)
    }

    /// Attach (Q, "Place on Top"): the clips go above (video) / below (audio, never on the first audio track) the main
    /// track at `t`, on the lowest free track (a new one when none is free), attached at their first frame to the main
    /// clip under `t`. `backtimed` (Shift+Q): they end at `t` and attach at their last frame. Keeps the clips' links and
    /// relative offsets. Normal: the same placement without attachments. Returns the new clip ids.
    @discardableResult
    public mutating func attach(_ clips: [Clip], at t: Time, backtimed: Bool = false) throws -> [Clip.ID] {
        guard let first = clips.map(\.start).min() else { throw EditError.emptyClip }
        let length = clips.map { ($0.start - first) + $0.timeline.duration }.max()!
        guard length > .zero else { throw EditError.emptyClip }
        var work = self
        if work.isFastCut { work.deriveAttachments() }
        let placed = try Self.placeRun(clips.map { ($0, ()) }, first: first, length: length, at: t, backtimed: backtimed, frame: frameDuration)
        let host = work.isFastCut ? work.attachHost(at: placed.pointTime) : nil
        for var c in placed.clips.map(\.0).sorted(by: { $0.start < $1.start }) {
            c.attachment = host.map { ClipAttachment(host: $0, point: placed.pointTime - c.start) }
            try work.placeNew(c)
        }
        if work.isFastCut { work.deriveAttachments() }
        self = work
        return placed.clips.map(\.0.id)
    }

    /// Positions a run of clips (offsets relative to `first`, `length` long). Forward: it starts at `t`. `backtimed`: `t`
    /// is where it ENDS; with no room before the sequence start the head is cut so it starts at 0 and still ends at `t`
    /// (the back-time rule of `Timeline.sourceEditPlan`). `pointTime` is the attach time: the first frame, backtimed the
    /// last frame.
    static func placeRun<T>(_ items: [(Clip, T)], first: Time, length: Time, at t: Time, backtimed: Bool,
                            frame: Time) throws -> (clips: [(Clip, T)], pointTime: Time) {
        guard t >= .zero else { throw EditError.collision }
        if !backtimed {
            return (items.map { var c = $0.0; c.start = t + (c.start - first); return (c, $0.1) }, t)
        }
        guard t > .zero else { throw EditError.emptyClip }
        let runStart = t - length
        var out: [(Clip, T)] = []
        for (c0, tag) in items {
            var c = c0
            c.start = runStart + (c0.start - first)
            if runStart < .zero {
                guard let cut = c.cropped(to: TimeRange(start: .zero, end: t)) else { continue }
                c = cut
            }
            out.append((c, tag))
        }
        guard !out.isEmpty else { throw EditError.emptyClip }
        return (out, max(t - frame, max(runStart, .zero)))
    }

    /// A source edit in Fast Cut (three-point edit from the Source monitor or the Project panel, a placed sequence): with
    /// the main track among the targets the clips go onto it (`insertOnMainTrack` / `overwriteOnMainTrack`: V1 never gets
    /// a hole, attached clips follow or stay); otherwise they attach on the targeted tracks (`attachOnTracks`: Place on
    /// Top, a source patched above V1). Returns the end of the placed clips.
    @discardableResult
    mutating func fastCutSourceEdit(_ placements: [(clip: Clip, track: Track.ID)], at t: Time, mode: ThreePointMode,
                                    backtimed: Bool = false) throws -> Time {
        let clips = placements.map(\.clip)
        let ids: [Clip.ID]
        if let main = mainTrackID, placements.contains(where: { $0.track == main }) {
            ids = mode == .insert ? try insertOnMainTrack(clips, at: t) : try overwriteOnMainTrack(clips, at: t)
        } else {
            ids = try attachOnTracks(placements, at: t, backtimed: backtimed)
        }
        return ids.compactMap { find($0)?.clip.timeline.end }.max() ?? t
    }

    /// Attach on chosen tracks: the clips land at `t` (keeping their offsets), each on its track when free there, else on
    /// the nearest free track of its kind (never the main track, a new track when none is free), attached at `t` to the
    /// main clip under it. Nothing is covered and nothing moves. Fast Cut only (callers check). `backtimed` (Attach
    /// Backtimed): `t` is where the run ENDS (as in `attach`), the head is cut when there is no room before 0, and it
    /// attaches at its last frame. Returns the clip ids.
    @discardableResult
    public mutating func attachOnTracks(_ placements: [(clip: Clip, track: Track.ID)], at t: Time,
                                        backtimed: Bool = false) throws -> [Clip.ID] {
        guard let first = placements.map(\.clip.start).min() else { throw EditError.emptyClip }
        guard t >= .zero else { throw EditError.collision }
        var work = self
        work.deriveAttachments()
        if placements.contains(where: { work.track($0.track)?.isLocked == true }) { throw EditError.trackLocked }
        let length = placements.map { ($0.clip.start - first) + $0.clip.timeline.duration }.max() ?? .zero
        let run = try Self.placeRun(placements.map { ($0.clip, $0.track) }, first: first, length: length, at: t,
                                    backtimed: backtimed, frame: frameDuration)
        let host = work.attachHost(at: run.pointTime)
        for (var c, track) in run.clips.sorted(by: { $0.0.start < $1.0.start }) {
            c.attachment = host.map { ClipAttachment(host: $0, point: run.pointTime - c.start) }
            try work.placeAttached(c, preferring: track)
        }
        work.deriveAttachments()
        self = work
        return run.clips.map(\.0.id)
    }

    /// Replace (drop onto a main clip): `id` (a main-track clip) plays the first video of `clips` instead and keeps its
    /// id, so its attached clips stay attached. `keepLength` (Replace from Start): the new clip is as long as the old one
    /// (shorter sources keep their own length); else (Replace) it has the source length and everything later ripples.
    /// The old clip's linked partners go; audio of `clips` goes on the first audio track, linked with the video.
    public mutating func replaceOnMainTrack(_ id: Clip.ID, with clips: [Clip], keepLength: Bool) throws {
        guard let old = find(id)?.clip, old.kind == .video else { throw EditError.clipNotFound }
        guard let v = clips.first(where: { $0.kind == .video }), let first = clips.map(\.start).min() else {
            throw EditError.wrongTrackKind
        }
        let length = keepLength ? min(old.timeline.duration, v.timeline.duration) : v.timeline.duration
        let link: UUID? = clips.count > 1 ? UUID() : nil
        var fresh: [Clip] = []
        for c in clips {
            guard var n = c.cropped(to: TimeRange(start: c.start, end: min(c.timeline.end, c.start + length))) else { continue }
            if c.id == v.id { n.id = old.id } else { n.id = c.id }
            n.start = old.start + (c.start - first)
            n.link = link
            n.attachment = nil
            fresh.append(n)
        }
        let delta = length - old.timeline.duration
        var work = self
        try work.magneticEdit { tl in
            let group = try tl.linkedGroup(id)
            if group.contains(where: { tl.tracks[$0.track].isLocked }) { throw EditError.trackLocked }
            let oldTracks = Dictionary(uniqueKeysWithValues: group.map { ($0.clip.kind, tl.tracks[$0.track].id) })
            for m in group { tl.tracks[m.track].remove(m.clip.id) }
            if delta != .zero, tl.isFastCut {
                try tl.rippleMain(from: old.timeline.end, by: delta)
            } else if delta != .zero {
                for i in tl.tracks.indices where tl.tracks[i].id == oldTracks[.video] || tl.tracks[i].followsRipple {
                    tl.tracks[i].shift(from: old.timeline.end, by: delta)
                }
                if delta > .zero { tl.openCaptionGap(at: old.timeline.end, by: delta) }
                else { tl.closeCaptionSpan(TimeRange(start: old.timeline.end + delta, duration: .zero - delta)) }
            }
            for c in fresh {
                let track = oldTracks[c.kind] ?? (c.kind == .video ? tl.mainTrackID : tl.tracks.first { $0.kind == .audio }?.id)
                    ?? tl.addTrack(kind: c.kind)
                guard let i = tl.tracks.firstIndex(where: { $0.id == track }) else { throw EditError.clipNotFound }
                if tl.tracks[i].isLocked { throw EditError.trackLocked }
                try tl.tracks[i].overwrite(c)
            }
            tl.pruneTransitions()
            guard tl.tracks.allSatisfy(\.isConsistent) else { throw EditError.collision }
        }
        self = work
    }

    // MARK: Delete

    /// Delete: a main-track clip ripple-deletes (V1 closes) and its attached clips go with it, unless `keepAttached`
    /// (hold `): then they stay on their frame and re-attach to the clip now under it. An attached clip is removed and
    /// nothing moves. Normal: lift (leaves gaps), as the Delete key always did.
    public mutating func magneticDelete(_ ids: Set<Clip.ID>, keepAttached: Bool = false) throws {
        guard isFastCut else { try lift(Array(ids)); return }
        let main = ids.filter(isMainMaterial)
        let attached = ids.subtracting(main)
        let hosts = Set(main.compactMap(mainClip(of:)))
        var work = self
        try work.magneticEdit(involving: attached, stay: keepAttached ? .hosts(hosts) : .none, orphans: .delete) { tl in
            if !attached.isEmpty { try tl.lift(Array(attached)) }
            if !hosts.isEmpty { try tl.rippleDeleteMain(hosts) }
        }
        self = work
    }

    /// Replace with Spacer (Shift+Delete): main-track clips leave a hole; attached clips stay on their frame (now
    /// attached to the clip before the hole). Attached clips among `ids` are removed. Normal: lift.
    public mutating func replaceWithSpacer(_ ids: Set<Clip.ID>) throws {
        var work = self
        try work.magneticEdit(involving: ids, stay: .all) { try $0.lift(Array(ids)) }
        self = work
    }

    /// Delete on a spacer / Close Gap at the playhead: closes the hole of the main track under `t` (nothing when `t` is
    /// on a clip or after the last one). Clips attached in the hole are deleted unless `keepAttached`. Normal:
    /// `closeGap` on V1. Returns the time closed.
    @discardableResult
    public mutating func deleteSpacer(at t: Time, keepAttached: Bool = false) throws -> Time {
        guard let main = mainTrackID, let r = gap(on: main, at: t) else { return .zero }
        guard isFastCut else { return try closeGap(on: main, at: t) }
        var d = self
        d.deriveAttachments()
        var doomed: [Clip.ID] = []
        if !keepAttached {
            for tr in d.tracks where !tr.isLocked {
                for c in tr.clips { if let a = c.attachment, r.contains(c.start + a.point) { doomed.append(c.id) } }
            }
        }
        var work = d
        let closed = try work.magneticEdit(involving: Set(doomed), stay: keepAttached ? .range(r) : .none) { tl in
            if !doomed.isEmpty { try tl.lift(doomed) }
            // Every main clip after the hole moves with its linked partners, so a J cut reaching into the hole stays.
            try tl.rippleMain(from: r.end, by: .zero - r.duration)
            return r.duration
        }
        self = work
        return closed
    }

    /// Insert Spacer (Ctrl+W): a hole of `duration` at `t` on the main track; everything later ripples with its attached
    /// clips. Normal: the same hole on V1 and the sync-locked tracks.
    public mutating func insertSpacer(at t: Time, duration: Time) throws {
        guard duration > .zero else { throw EditError.emptyClip }
        var work = self
        let at = isFastCut ? min(max(t, .zero), mainTrackEnd) : t
        try work.magneticEdit { try $0.openMainHole(at: at, by: duration) }
        self = work
    }

    // MARK: Trim

    /// Ripple trim (drag an edge, Select tool): a main-track clip ripples V1 and everything attached later; its own
    /// attached clips keep their content frame. An attached clip is trimmed alone (`trim`): nothing else moves.
    @discardableResult
    public mutating func magneticRippleTrim(_ id: Clip.ID, edge: ClipEdge, by delta: Time) throws -> Time {
        var work = self
        let moved: Time
        if isFastCut, isOnMainTrack(id) {
            moved = try work.magneticEdit { try $0.rippleTrimMain(id, edge: edge, by: delta) }
        } else if !isFastCut || isMainMaterial(id) {
            moved = try work.magneticEdit { try $0.rippleTrim(id, edge: edge, by: delta) }
        } else {
            moved = try work.magneticEdit(involving: [id], local: true) { try $0.trim(id, edge: edge, by: delta) }
        }
        self = work
        return moved
    }

    /// Q / E style ripple trim to the playhead (`rippleTrimToPlayheadOutcome`). Fast Cut: the main track only (attached
    /// clips follow); `keepAttached` keeps the trimmed clip's attached clips on their frame. Normal: `tracks`.
    @discardableResult
    public mutating func magneticRippleTrimToPlayhead(_ edge: ClipEdge, at t: Time, tracks ids: [Track.ID]? = nil,
                                                      keepAttached: Bool = false) throws -> (moved: Time, outcome: EditOutcome) {
        guard isFastCut, let main = mainTrackID, let mi = mainTrackIndex else {
            return try rippleTrimToPlayheadOutcome(edge, at: t, tracks: ids)
        }
        let under = tracks[mi].clips.first { $0.timeline.contains(t) }?.id
        var work = self
        let r = try work.magneticEdit(stay: keepAttached ? .hosts(Set([under].compactMap { $0 })) : .none) {
            try $0.rippleTrimToPlayheadOutcome(edge, at: t, tracks: [main])
        }
        self = work
        return r
    }

    /// Roll: the cut moves, nothing ripples; attached clips stay on their frame (and may change host).
    @discardableResult
    public mutating func magneticRoll(_ id: Clip.ID, by delta: Time) throws -> Time {
        var work = self
        let local = !isMainMaterial(id)
        let d = try work.magneticEdit(involving: local ? [id] : [], local: local, stay: .all) { try $0.roll(id, by: delta) }
        self = work
        return d
    }

    /// Slip (decision 2026-10-07): the content moves inside the clip; attached clips stay where they are.
    @discardableResult
    public mutating func magneticSlip(_ id: Clip.ID, by delta: Time, keyframes: SlipKeyframes = .followContent) throws -> Time {
        var work = self
        let local = !isMainMaterial(id)
        let d = try work.magneticEdit(involving: local ? [id] : [], local: local, stay: .all) {
            try $0.slip(id, by: delta, keyframes: keyframes)
        }
        self = work
        return d
    }

    /// Slide: a main-track clip moves between its neighbors (they trim); its attached clips move with it, the
    /// neighbors' attached clips keep their content frame. An attached clip slides on its own track (its neighbors
    /// there trim). Fast Cut: the first main-track clip cannot slide right (V1 never gets a hole at its head).
    @discardableResult
    public mutating func magneticSlide(_ id: Clip.ID, by delta: Time) throws -> Time {
        guard isFastCut else { return try slide(id, by: delta) }
        var work = self
        let d: Time
        if let main = mainClip(of: id), isMainMaterial(id) {
            d = try work.magneticEdit { try $0.slideMainRuns([main], by: delta) }
        } else {
            d = try work.magneticEdit(involving: [id], local: true) { try $0.slide(id, by: delta) }
        }
        self = work
        return d
    }

    /// Nudge (, / .): main-track clips slide by `delta`, each run of adjacent selected main clips as one block (the
    /// clips around it trim; attached clips go along; never a hole at the head of V1). Attached clips that did not go
    /// along with a selected host move on their own track (`nudge`, it cuts what it covers there). Normal: `nudge`.
    public mutating func magneticNudge(_ ids: Set<Clip.ID>, by delta: Time) throws {
        guard isFastCut else { try nudge(ids, by: delta); return }
        let mains = Set(ids.filter(isMainMaterial).compactMap(mainClip(of:)))
        let carried = Set(attachedClips(of: mains))
        let alone = Set(ids.filter { !isMainMaterial($0) && !carried.contains($0) })
        var work = self
        if !mains.isEmpty { _ = try work.magneticEdit { try $0.slideMainRuns(mains, by: delta) } }
        if !alone.isEmpty { _ = try work.magneticEdit(involving: alone, local: true) { try $0.nudge(alone, by: delta) } }
        self = work
    }

    /// Slides the main-track clips `ids` by `delta`: each run of adjacent ones moves as one block with its linked
    /// partners (`slideBlock`), later runs first when moving right. Returns the delta applied to the last run.
    mutating func slideMainRuns(_ ids: Set<Clip.ID>, by delta: Time) throws -> Time {
        guard let mi = mainTrackIndex else { throw EditError.wrongTrackKind }
        var runs: [[Clip.ID]] = []
        var prevEnd: Time?                                 // end of the previous selected clip
        for c in tracks[mi].clips where ids.contains(c.id) {
            if prevEnd == c.start, !runs.isEmpty { runs[runs.count - 1].append(c.id) } else { runs.append([c.id]) }
            prevEnd = c.timeline.end
        }
        var d = Time.zero
        for run in (delta > .zero ? runs.reversed() : runs) { d = try slideBlock(run, by: delta, holdMainHead: true) }
        return d
    }

    /// Slide of several clips as one block: per track, the block's members (the clips and their linked partners) move
    /// by `delta` with their content; the clip ending at the block's start gets its tail moved, the clip starting at
    /// its end its head (a neighbor across a gap is not edited, the gap changes). Clamped like `slide` (neighbors keep
    /// a frame, media handles, gaps, time 0). `holdMainHead`: a block on the main track with no clip right before it
    /// cannot move right (no hole at the head of V1). Returns the applied delta.
    mutating func slideBlock(_ ids: [Clip.ID], by delta: Time, holdMainHead: Bool) throws -> Time {
        var members: [Member] = []
        var seen = Set<Clip.ID>()
        for id in ids { for m in try linkedGroup(id) where seen.insert(m.clip.id).inserted { members.append(m) } }
        guard !members.isEmpty else { throw EditError.clipNotFound }
        if members.contains(where: { tracks[$0.track].isLocked }) { throw EditError.trackLocked }
        let frame = frameDuration
        let mi = mainTrackIndex
        let byTrack = Dictionary(grouping: members, by: \.track)
        func around(_ ti: Int, _ mine: [Member]) -> (lo: Time, hi: Time, prev: Clip?, next: Clip?) {
            let lo = mine.map(\.clip.start).min()!, hi = mine.map { $0.clip.timeline.end }.max()!
            let others = tracks[ti].clips.filter { !seen.contains($0.id) }
            return (lo, hi, others.last { $0.timeline.end <= lo }, others.first { $0.start >= hi })
        }
        var d = delta
        for (ti, mine) in byTrack {
            let (lo, hi, prev, next) = around(ti, mine)
            if d < .zero {
                if let p = prev, p.timeline.end == lo { d = max(d, .zero - max(p.duration - frame, .zero)) }
                else { d = max(d, .zero - (lo - (prev?.timeline.end ?? .zero))) }
                if let n = next, n.start == hi, let h = n.headHandle?.flooredToFrame(frameDuration) { d = max(d, .zero - h) }
            } else if d > .zero {
                if holdMainHead, ti == mi, !(prev.map { $0.timeline.end == lo } ?? false) { d = .zero }
                if let n = next, n.start == hi { d = min(d, max(n.duration - frame, .zero)) }
                else if let n = next { d = min(d, n.start - hi) }
                if let p = prev, p.timeline.end == lo, let room = p.tailRoom?.flooredToFrame(frameDuration) { d = min(d, room) }
            }
        }
        if d == .zero { return .zero }
        var work = tracks
        for (ti, mine) in byTrack {
            let (lo, hi, prev, next) = around(ti, mine)
            if var p = prev, p.timeline.end == lo { p.extendTail(by: d); work[ti].replace(p) }
            if var n = next, n.start == hi { n.start += d; n.extendHead(by: .zero - d); work[ti].replace(n) }
            for m in mine { var c = m.clip; c.start += d; work[ti].replace(c) }
        }
        guard work.allSatisfy(\.isConsistent) else { throw EditError.collision }
        tracks = work
        return d
    }

    // MARK: Cut and join

    /// Cmd+K. Fast Cut, nothing selected: the main clip under `t` and its linked audio only (attached clips go with
    /// the half that holds their point). With a selection: the selected clips. The right half of a cut attached clip
    /// attaches at its own first frame. Normal: `addEdit(at:selection:)`. Returns the new right halves.
    @discardableResult
    public mutating func magneticAddEdit(at t: Time, selection: Set<Clip.ID>) throws -> [Clip.ID] {
        guard isFastCut, let mi = mainTrackIndex else { return try addEdit(at: t, selection: selection) }
        var work = self
        let made: [Clip.ID]
        if selection.isEmpty {
            guard let under = tracks[mi].clips.first(where: { $0.start < t && $0.timeline.contains(t) }) else { return [] }
            var ids = [tracks[mi].id]
            if let l = under.link {
                for tr in tracks where tr.id != tracks[mi].id && tr.clips.contains(where: { $0.link == l }) { ids.append(tr.id) }
            }
            made = try work.magneticEdit { tl in try tl.addEdit(at: t, tracks: ids) }
        } else {
            made = try work.magneticEdit(involving: selection) { tl in
                let made = try tl.addEdit(at: t, selection: selection)
                tl.dropAttachments(of: made)
                return made
            }
        }
        self = work
        return made
    }

    /// Cmd+Shift+K: every unlocked track, attached clips included (their right halves attach at their first frame).
    @discardableResult
    public mutating func magneticAddEditAll(at t: Time) throws -> [Clip.ID] {
        guard isFastCut else { return try addEdit(at: t, tracks: nil) }
        var under = Set<Clip.ID>()
        for tr in tracks where !tr.isLocked { for c in tr.clips where c.start < t && c.timeline.contains(t) { under.insert(c.id) } }
        var work = self
        let made = try work.magneticEdit(involving: under) { tl in
            let made = try tl.addEdit(at: t, tracks: nil)
            tl.dropAttachments(of: made)
            return made
        }
        self = work
        return made
    }

    private mutating func dropAttachments(of ids: [Clip.ID]) {
        for id in ids {
            guard let m = find(id), m.clip.attachment != nil else { continue }
            var c = m.clip
            c.attachment = nil
            tracks[m.track].replace(c)
        }
    }

    /// Join Through Edits: the joined clip keeps the left id; clips attached to the right half re-attach to it.
    @discardableResult
    public mutating func magneticJoin(selection: Set<Clip.ID>? = nil) throws -> Int {
        var work = self
        // A join moves nothing, so every clip it may touch is worked on directly (nothing is lifted out).
        let all = selection ?? Set(tracks.flatMap { $0.clips.map(\.id) })
        let n = try work.magneticEdit(involving: all) { try $0.joinThroughEdits(selection: selection) }
        self = work
        return n
    }

    // MARK: Moving

    /// Drag a main-track clip along V1: it moves to the nearest V1 edit to `t` (pre-edit time, `mainTrackDropPoint`),
    /// V1 closes behind it and opens in front; its attached clips travel with it unless `keepAttached`. An attached clip
    /// is moved (`moveAttached`). Normal: `move` (the plain overwrite drag; Cmd-drag insert is the caller's `moveInsert`).
    public mutating func magneticRearrange(_ id: Clip.ID, to t: Time, keepAttached: Bool = false) throws {
        guard isFastCut else { _ = try move(id, to: t); return }
        guard let main = mainClip(of: id) else { try moveAttached(id, to: t); return }
        let drop = mainTrackDropPoint(t, moving: main)
        var work = self
        try work.magneticEdit(stay: keepAttached ? .hosts([main]) : .none) { try $0.rearrangeMain(main, to: drop) }
        self = work
    }

    /// Move Left / Move Right: the main-track clip of `id` (itself or its linked camera audio) swaps places with its
    /// neighbor on V1, `step` > 0 to the right, < 0 to the left (one place; the sign decides). Linked partners and attached
    /// clips travel with their own host, so both swapped clips keep their attached clips. Nothing happens at either end of
    /// V1, for an attached clip, or in Normal. Spacers stay where they are.
    public mutating func magneticMove(_ id: Clip.ID, step: Int) throws {
        guard isFastCut, step != 0, let mi = mainTrackIndex, let main = mainClip(of: id) else { return }
        let clips = tracks[mi].clips
        guard let i = clips.firstIndex(where: { $0.id == main }) else { throw EditError.clipNotFound }
        let j = i + (step > 0 ? 1 : -1)
        guard clips.indices.contains(j) else { return }
        try magneticRearrange(main, to: step > 0 ? clips[j].timeline.end : clips[j].start)
    }

    /// Drag an attached clip (with its linked partners): it moves by `start - its start`, the dragged clip onto `track`
    /// when given, and never covers anything (a busy track sends it to the nearest free one). It re-attaches to the
    /// main clip under its attach point. Nothing else moves. The main track as `track` throws `.wrongTrackKind` (that is `dragOntoMainTrack`).
    /// Normal: `move`.
    public mutating func moveAttached(_ id: Clip.ID, to start: Time, track target: Track.ID? = nil) throws {
        guard isFastCut else { try move(id, to: start, track: target); return }
        // Onto the main track is its own verb (dragOntoMainTrack / putOnMainTrack): refused here.
        if let target, target == mainTrackID { throw EditError.wrongTrackKind }
        var work = self
        work.deriveAttachments()
        guard work.isAttachable(id) else { throw EditError.wrongTrackKind }
        let group = try work.linkedGroup(id)
        if group.contains(where: { work.tracks[$0.track].isLocked }) { throw EditError.trackLocked }
        if let target, let t = work.track(target) {
            if t.kind != group[0].clip.kind { throw EditError.wrongTrackKind }
            if t.isLocked { throw EditError.trackLocked }
        }
        var d = start - group[0].clip.start
        for m in group { d = max(d, .zero - m.clip.start) }
        let homes = group.map { work.tracks[$0.track].id }
        let stash = work.liftOut(Set(group.map(\.clip.id)))
        for (m, home) in zip(group, homes) {
            var c = m.clip
            c.start += d
            try work.placeAttached(c, preferring: m.clip.id == id ? target ?? home : home)
        }
        work.restoreMagnetic(stash)
        work.deriveAttachments()
        self = work
    }

    /// Lift off Main Track (Opt+Cmd+Up): the main-track clips among `ids` go to the lowest free video track above at
    /// the same time (never covering anything); a spacer stays on V1, attached clips stay on their frame. The lifted
    /// clips (with their linked audio) become attached. Normal: `moveToLane(up:)`.
    public mutating func liftOffMainTrack(_ ids: Set<Clip.ID>) throws {
        guard isFastCut, let mi = mainTrackIndex else { _ = try moveToLane(ids, up: true); return }
        let mains = Set(ids.filter { tracks[mi].clip($0) != nil })
        guard !mains.isEmpty else { return }
        try requireUnlockedMain()
        var work = self
        var taken: [Clip] = []
        var stash: [Transition] = []
        try work.magneticEdit(stay: .all) { tl in
            taken = tl.tracks[mi].clips.filter { mains.contains($0.id) }
            stash = tl.liftOut(mains)
        }
        for var c in taken {
            c.attachment = nil
            try work.placeNew(c)
        }
        work.restoreMagnetic(stash)
        work.pruneTransitions()
        work.deriveAttachments()
        self = work
    }

    /// Drag a main-track clip onto another track: V1 closes (Delete), the clip and its linked partners land at `start`
    /// (final time) with the dragged clip on `track`, never covering anything, and become attached. Its attached clips
    /// travel with it by the same distance unless `keepAttached` (then they stay on their frame). Normal: `move`.
    public mutating func dragOffMainTrack(_ id: Clip.ID, to target: Track.ID, at start: Time, keepAttached: Bool = false) throws {
        guard isFastCut else { try move(id, to: start, track: target); return }
        guard isOnMainTrack(id), let clip = find(id)?.clip else { throw EditError.wrongTrackKind }
        try dragOffMainTrack([id], to: target, by: start - clip.start, keepAttached: keepAttached)
    }

    /// Drag a clip from another track onto the main track: inserted at the nearest V1 edit to `t` (V1 ripples, with
    /// the attached clips); `overwrite` (Cmd while dropping): covers V1 from `t`, nothing ripples. Its linked partners
    /// keep their tracks and offsets. Only video goes onto V1. Normal: `move` onto V1.
    public mutating func dragOntoMainTrack(_ id: Clip.ID, at t: Time, overwrite: Bool = false) throws {
        guard let main = mainTrackID else { throw EditError.wrongTrackKind }
        guard isFastCut else { try move(id, to: t, track: main); return }
        guard let clip = find(id)?.clip, clip.kind == .video, !isOnMainTrack(id) else { throw EditError.wrongTrackKind }
        let group = try linkedGroup(id)
        if group.contains(where: { tracks[$0.track].isLocked }) { throw EditError.trackLocked }
        let ids = Set(group.map(\.clip.id))
        let first = group.map(\.clip.start).min()!
        let lead = clip.start - first
        let placements: [(clip: Clip, track: Track.ID)] = group.map { m in
            var c = m.clip
            c.attachment = nil
            return (c, m.clip.id == id ? main : tracks[m.track].id)
        }
        var work = self
        if overwrite {
            try work.magneticEdit(involving: ids, stay: .all) { tl in
                _ = tl.liftOut(ids)
                // Past V1's end the clip appends exactly at the end (never a hole before it). Its partners keep their
                // offsets, so a partner that would start before 0 refuses the edit (`.collision`) instead of shifting the clip.
                let end = tl.mainTrackEnd
                let from = t > end ? end - lead : max(t - lead, .zero)
                try tl.overwrite(placements, at: from)
            }
        } else {
            let drop = mainTrackDropPoint(t)
            try work.magneticEdit(involving: ids) { tl in
                _ = tl.liftOut(ids)
                try tl.insertOnMain(placements, at: drop)      // V1 opens by the clip's own length (no J/L hole)
            }
        }
        self = work
    }

    /// Put on Main Track (Opt+Cmd+Down): each attached video clip among `ids` overwrites V1 at its own position.
    public mutating func putOnMainTrack(_ ids: Set<Clip.ID>) throws {
        var work = self
        let picks = ids.compactMap { work.find($0)?.clip }.filter { $0.kind == .video && !work.isOnMainTrack($0.id) }
            .sorted { $0.start < $1.start }
        for c in picks { try work.dragOntoMainTrack(c.id, at: c.start, overwrite: true) }
        self = work
    }

    // MARK: Attach point

    /// Set Attach Point (Cmd+Opt+click): the clip (with its linked partners off V1) attaches at `t` (clamped into the
    /// clip, its last frame at most) to the main clip under `t`. A main-track clip throws `.wrongTrackKind`.
    public mutating func setAttachPoint(_ id: Clip.ID, at t: Time) throws {
        var work = self
        work.deriveAttachments()
        guard let mi = work.mainTrackIndex, work.isAttachable(id), let c = work.find(id)?.clip else {
            throw EditError.wrongTrackKind
        }
        let members = work.tracks.indices.filter { $0 != mi }.flatMap { i in
            work.tracks[i].clips.filter { $0.id == id || (c.link != nil && $0.link == c.link) }.map { (i, $0) }
        }
        if members.contains(where: { work.tracks[$0.0].isLocked }) { throw EditError.trackLocked }
        let lo = members.map(\.1.start).min()!, hi = members.map { $0.1.timeline.end }.max()!
        let at = min(max(t, lo), max(hi - frameDuration, lo))
        guard let host = work.attachHost(at: at) else { throw EditError.clipNotFound }
        for (i, m) in members {
            var n = m
            n.attachment = ClipAttachment(host: host, point: at - m.start)
            work.tracks[i].replace(n)
        }
        self = work
    }

    // MARK: Clipboard, duplicate, nest

    /// Copy: in Fast Cut, copied main-track clips take their linked partners and their attached clips along (they
    /// travel with their host). Normal: `clipboard(copying:)`.
    public func magneticClipboard(copying ids: Set<Clip.ID>) -> TimelineClipboard? {
        guard isFastCut else { return clipboard(copying: ids) }
        var d = self
        d.deriveAttachments()
        var all = ids
        for id in ids { if let g = try? d.linkedGroup(id) { all.formUnion(g.map(\.clip.id)) } }
        let hosts = Set(all.filter(d.isOnMainTrack))
        all.formUnion(d.attachedClips(of: hosts))
        return d.clipboard(copying: all)
    }

    /// Paste. Fast Cut: copied main-track clips are inserted on V1 at `t` (at most its end; V1 ripples, the copies'
    /// attached clips come along attached to the copies and yield to clips already there). A clipboard without main
    /// clips, or `attached` (Opt+V), lands at `t` off the main track, never covering anything. Normal: `paste` (overwrite),
    /// without the copied attachments (Normal never stores them).
    @discardableResult
    public mutating func magneticPaste(_ cb: TimelineClipboard, at t: Time, attached: Bool = false) throws -> [Clip.ID] {
        guard isFastCut else { return try paste(cb.strippingAttachments(), at: t) }
        let cb = attached ? cb : Self.packedMainEntries(cb)
        let mainEntries = cb.entries.filter { $0.clip.kind == .video && $0.lane == 0 }
        guard !attached, let m0 = mainEntries.map(\.offset).min(),
              let m1 = mainEntries.map({ $0.offset + $0.clip.timeline.duration }).max() else {
            return try pasteAttached(cb, at: t)
        }
        let at = min(max(t.ceiled(to: frameDuration), .zero), mainTrackEnd)
        guard at - m0 >= .zero else { throw EditError.collision }
        var work = self
        let made = try work.magneticEdit { tl in
            try tl.openMainHole(at: at, by: m1 - m0)
            return try tl.paste(cb, at: at - m0)
        }
        self = work
        return made
    }

    /// The clipboard with its main-track copies (V1, lane 0) closed up into one contiguous run (FCP: a paste never opens
    /// a hole on the main track; decision 2026-10-07). Every other copy moves with the main copy it belongs to: its
    /// linked main clip, else its attachment host, else the main copy before it; so attached copies keep their point.
    static func packedMainEntries(_ cb: TimelineClipboard) -> TimelineClipboard {
        let mains = cb.entries.indices.filter { cb.entries[$0].clip.kind == .video && cb.entries[$0].lane == 0 }
            .sorted { cb.entries[$0].offset < cb.entries[$1].offset }
        guard let first = mains.first else { return cb }
        var shift: [Clip.ID: Time] = [:], byLink: [UUID: Time] = [:]
        var cursor = cb.entries[first].offset
        var starts: [(offset: Time, shift: Time)] = []
        for i in mains {
            let e = cb.entries[i]
            let s = cursor - e.offset
            shift[e.clip.id] = s
            if let l = e.clip.link { byLink[l] = s }
            starts.append((e.offset, s))
            cursor += e.clip.timeline.duration
        }
        guard shift.values.contains(where: { $0 != .zero }) else { return cb }
        var out = cb
        for i in out.entries.indices {
            let e = out.entries[i]
            let s = shift[e.clip.id] ?? e.clip.link.flatMap { byLink[$0] } ?? e.clip.attachment.flatMap { shift[$0.host] }
                ?? starts.last { $0.offset <= e.offset }?.shift ?? .zero
            out.entries[i].offset = e.offset + s
        }
        return out
    }

    /// Pastes `cb` at `t` with every copy placed like an attached clip: its lane when free, else the nearest free track
    /// of its kind, never the main track; then attached to the main clip under it.
    private mutating func pasteAttached(_ cb: TimelineClipboard, at t: Time) throws -> [Clip.ID] {
        var scratch = self
        scratch.editMode = .normal
        for i in scratch.tracks.indices {
            for c in scratch.tracks[i].clips { scratch.tracks[i].remove(c.id) }
            scratch.tracks[i].transitions = []
            scratch.tracks[i].isLocked = false
        }
        let made = try scratch.paste(cb, at: t)
        var work = self
        work.deriveAttachments()
        let set = Set(made)
        let stash = scratch.tracks.flatMap(\.transitions).filter { tr in
            [tr.outgoing, tr.incoming].compactMap { $0 }.allSatisfy(set.contains)
        }
        let copies = made.compactMap { scratch.find($0) }.sorted { $0.clip.start < $1.clip.start }
        for m in copies { try work.placeAttached(m.clip, preferring: scratch.tracks[m.track].id) }
        work.restoreMagnetic(stash)
        work.deriveAttachments()
        self = work
        return made
    }

    /// Duplicate: main-track clips are pasted (inserted) right after the selection's last main clip with their attached
    /// clips; attached clips alone land after the selection, attached. Normal: `duplicate`.
    @discardableResult
    public mutating func magneticDuplicate(_ ids: Set<Clip.ID>) throws -> [Clip.ID] {
        guard isFastCut else { return try duplicate(ids) }
        guard let cb = magneticClipboard(copying: ids) else { throw EditError.clipNotFound }
        let mains = ids.compactMap(mainClip(of:))
        if mains.isEmpty {
            let end = ids.compactMap { find($0)?.clip.timeline.end }.max() ?? .zero
            return try pasteAttached(cb, at: end)
        }
        let end = mains.compactMap { find($0)?.clip.timeline.end }.max() ?? .zero
        return try magneticPaste(cb, at: end)
    }

    // MARK: Ranges

    /// Delete Range / Cut Out with the main track targeted: V1 (and the tracks of its linked audio there) closes; clips
    /// on the other targeted tracks are cut and close too; attached clips follow their hosts (inside the range: kept,
    /// on their host's last frame before the cut). Without the main track: a lift (attached clips never ripple).
    @discardableResult
    public mutating func magneticExtract(_ range: TimeRange, tracks ids: [Track.ID]) throws -> (closed: Time, outcome: EditOutcome) {
        guard isFastCut, let main = mainTrackID else { return try extractOutcome(range, tracks: ids) }
        guard ids.contains(main) else {
            var work = self
            // The untargeted main track never gets a hole: the partner rule leaves it alone.
            try work.lift(range, tracks: ids, sparing: [main], pruning: true)
            work.deriveAttachments()
            self = work
            return (.zero, .applied)
        }
        let targets = withMainPartnerTracks(ids, range)
        let direct = Set(tracks.filter { targets.contains($0.id) && $0.id != main }.flatMap { $0.clips.map(\.id) })
        var work = self
        // The range is cut out of the targeted tracks, then V1 closes by its whole length (main clips take their linked
        // partners along, `rippleMain`) and the other targeted tracks close by the same amount.
        let r = try work.magneticEdit(involving: direct) { tl -> (closed: Time, outcome: EditOutcome) in
            try tl.lift(range, tracks: targets, sparing: [], pruning: false)
            let moved = try tl.rippleMain(from: range.end, by: .zero - range.duration)
            try tl.shiftOffMain(from: range.end, by: .zero - range.duration, tracks: targets, excluding: moved)
            if moved.isEmpty { tl.closeCaptionSpan(range) }
            return (range.duration, .applied)
        }
        self = work
        return r
    }

    /// Clear Range with the main track targeted: a spacer for that range on V1 (and its linked audio); attached clips
    /// stay on their frame. Without the main track, or Normal: `lift`.
    public mutating func magneticClearRange(_ range: TimeRange, tracks ids: [Track.ID]) throws {
        guard isFastCut, let main = mainTrackID else { try lift(range, tracks: ids); return }
        guard ids.contains(main) else {
            var work = self
            // The untargeted main track never gets a hole: the partner rule leaves it alone.
            try work.lift(range, tracks: ids, sparing: [main], pruning: true)
            work.deriveAttachments()
            self = work
            return
        }
        let targets = withMainPartnerTracks(ids, range)
        let direct = Set(tracks.filter { targets.contains($0.id) && $0.id != main }.flatMap { $0.clips.map(\.id) })
        var work = self
        try work.magneticEdit(involving: direct, stay: .all) { try $0.lift(range, tracks: targets) }
        self = work
    }

    /// `ids` plus the unlocked tracks holding linked audio of main clips under `range`, so V1 and its sound stay in sync.
    private func withMainPartnerTracks(_ ids: [Track.ID], _ range: TimeRange) -> [Track.ID] {
        guard let mi = mainTrackIndex else { return ids }
        let links = Set(tracks[mi].clips.filter { $0.timeline.overlaps(range) }.compactMap(\.link))
        var out = ids
        for (i, tr) in tracks.enumerated() where i != mi && !tr.isLocked && !out.contains(tr.id) {
            if tr.clips.contains(where: { $0.link.map(links.contains) ?? false && $0.timeline.overlaps(range) }) { out.append(tr.id) }
        }
        return out
    }
}

extension Project {
    /// Nest (Combine) in Fast Cut: selected main-track clips take their linked partners and the attached clips that lie
    /// entirely inside the selection's span into the nest; the nested clip sits on V1 and keeps the other clips attached.
    /// Normal: `nest`.
    @discardableResult
    public mutating func magneticNest(clips ids: [Clip.ID], in timelineID: Timeline.ID, name: String? = nil) throws -> Timeline.ID {
        guard let ti = timelines.firstIndex(where: { $0.id == timelineID }) else { throw EditError.timelineNotFound }
        guard timelines[ti].isFastCut else { return try nest(clips: ids, in: timelineID, name: name) }
        var p = self
        var tl = p.timelines[ti]
        tl.deriveAttachments()
        var sel = Set(ids)
        for id in ids { if let g = try? tl.linkedGroup(id) { sel.formUnion(g.map(\.clip.id)) } }
        let mains = sel.filter(tl.isOnMainTrack)
        let mainClips = mains.compactMap { tl.find($0)?.clip }
        if let s = mainClips.map(\.start).min(), let e = mainClips.map({ $0.timeline.end }).max() {
            var byGroup: [UUID: [Clip]] = [:]
            for id in tl.attachedClips(of: Set(mains)) {
                guard let c = tl.find(id)?.clip else { continue }
                byGroup[c.link ?? c.id, default: []].append(c)
            }
            for (_, g) in byGroup where g.allSatisfy({ $0.start >= s && $0.timeline.end <= e }) {
                sel.formUnion(g.map(\.id))
            }
        }
        p.timelines[ti] = tl
        let seq = try p.nest(clips: Array(sel), in: timelineID, name: name)
        p.timelines[ti].deriveAttachments()
        self = p
        return seq
    }
}
