import Foundation

// Fast Cut verbs for gestures that touch several clips at once or copy them (docs/ARCHITECTURE.md "Fast Cut
// operations", table 5.6): close a gap on an attached lane, Option-drag / Cmd+Option-drag copies, several main-track
// clips dragged at once. They keep the Fast Cut invariants of Timeline+MagneticOps.swift: V1 never gets a hole, attached
// clips never cover anything.

/// One copied clip of an Option-drag (`Timeline.magneticCopy`): the dragged clip, where it goes, where its linked
/// partners go (missing = their own track) and the identities of the copies.
public struct MagneticCopy: Sendable, Hashable {
    public var clip: Clip.ID
    /// Destination of `clip`; nil = its own track.
    public var track: Track.ID?
    public var partners: [Clip.ID: Track.ID]
    public var spec: CopySpec

    public init(clip: Clip.ID, track: Track.ID? = nil, partners: [Clip.ID: Track.ID] = [:], spec: CopySpec) {
        self.clip = clip; self.track = track; self.partners = partners; self.spec = spec
    }
}

extension TimelineClipboard {
    /// The clipboard without Fast Cut attachments (a paste into a Normal sequence: Normal never stores them).
    public func strippingAttachments() -> TimelineClipboard {
        var out = self
        for i in out.entries.indices { out.entries[i].clip.attachment = nil }
        return out
    }
}

extension Timeline {
    /// `mainTrackDropPoint` with every edge of `moving` left out; at most the end of V1 without them (no hole).
    func mainTrackDropPoint(_ t: Time, movingAll ids: Set<Clip.ID>) -> Time {
        guard let mi = mainTrackIndex else { return t }
        let rest = tracks[mi].clips.filter { !ids.contains($0.id) }
        let edges = rest.flatMap { [$0.start, $0.timeline.end] }
        return edges.min { a, b in
            let x = a < t ? t - a : a - t, y = b < t ? t - b : b - t
            return x != y ? x < y : a < b
        } ?? .zero
    }

    // MARK: Gap on an attached lane

    /// Close Gap on a track other than V1: the clips of that track after the gap move left by its length, each with its
    /// linked partners off V1 (`shiftOffMain`); V1, its camera audio and every other track stay. Then the attachments are
    /// re-derived. On V1: `deleteSpacer`. Normal: `closeGap`. Returns the time closed.
    @discardableResult
    public mutating func closeLaneGap(on track: Track.ID, at t: Time) throws -> Time {
        guard isFastCut, let main = mainTrackID else { return try closeGap(on: track, at: t) }
        if track == main { return try deleteSpacer(at: t) }
        guard let r = gap(on: track, at: t) else { return .zero }
        var work = self
        try work.shiftOffMain(from: r.end, by: .zero - r.duration, tracks: [track], excluding: [])
        work.deriveAttachments()
        self = work
        return r.duration
    }

    // MARK: Copies

    /// Option-drag / Cmd+Option-drag copy by `delta`. Copies whose video lands on V1 (a main-track clip copied along
    /// V1, an attached clip copied onto V1) are inserted as one contiguous run at the V1 edit nearest to the first one
    /// (at most V1's end), V1 rippling with its attached clips; copies of attached clips riding on a copied main clip
    /// come along with it. Every other copy lands like an attached clip: on its track when free, else the nearest free
    /// track of its kind, never covering anything, attached to the main clip under it. The originals stay. Normal: the
    /// overwrite copy (`move(copy:)`). Returns the ids of the copies.
    @discardableResult
    public mutating func magneticCopy(_ items: [MagneticCopy], by delta: Time) throws -> [Clip.ID] {
        guard isFastCut, let main = mainTrackID else {
            var work = self
            var made: [Clip.ID] = []
            for it in items {
                let group = try work.linkedGroup(it.clip)
                try work.move(it.clip, to: group[0].clip.start + delta, track: it.track, retarget: it.partners, copy: it.spec)
                made += group.map { it.spec.ids[$0.clip.id] ?? $0.clip.id }
            }
            self = work
            return made
        }
        var base = self
        base.deriveAttachments()
        typealias Placement = (clip: Clip, track: Track.ID)
        struct MainCopy { var lead: Clip; var original: Clip.ID; var members: [Placement] }
        var mains: [MainCopy] = []
        var loose: [(host: Clip.ID?, members: [Placement])] = []
        var made: [Clip.ID] = []
        for it in items {
            let group = try base.linkedGroup(it.clip)
            let copies: [Placement] = group.map { m in
                let home = base.tracks[m.track].id
                var c = m.clip
                c.id = it.spec.ids[m.clip.id] ?? UUID()
                if c.link != nil { c.link = it.spec.link }
                c.bundle = nil                                   // a copy never joins the original's bundle
                return (c, m.clip.id == it.clip ? it.track ?? home : it.partners[m.clip.id] ?? home)
            }
            made += copies.map(\.clip.id)
            if let i = copies.firstIndex(where: { $0.clip.kind == .video && $0.track == main }) {
                let members = copies.map { p -> Placement in var c = p.clip; c.attachment = nil; return (c, p.track) }
                mains.append(MainCopy(lead: members[i].clip, original: group[i].clip.id, members: members))
            } else {
                loose.append((group[0].clip.attachment?.host, copies))
            }
        }
        // The V1 copies as one run, in timeline order; attached copies of a copied main clip ride with its copy.
        mains.sort { $0.lead.start < $1.lead.start }
        var shift: [Clip.ID: Time] = [:]                       // original main clip -> how far its copy moves
        var cursor = mains.first?.lead.start ?? .zero
        for m in mains {
            shift[m.original] = cursor - m.lead.start
            cursor += m.lead.timeline.duration
        }
        var inRun: [Placement] = mains.flatMap { m in
            m.members.map { p in var c = p.clip; c.start += shift[m.original]!; return (c, p.track) }
        }
        var work = base
        var alone: [Placement] = []
        for l in loose {
            if let h = l.host, let s = shift[h] {
                inRun += l.members.map { p in var c = p.clip; c.start += s; return (c, p.track) }
                continue
            }
            var d = delta
            for p in l.members { d = max(d, .zero - p.clip.start) }
            alone += l.members.map { p in var c = p.clip; c.start += d; return (c, p.track) }
        }
        for p in alone.sorted(by: { $0.clip.start < $1.clip.start }) { try work.placeAttached(p.clip, preferring: p.track) }
        work.deriveAttachments()
        if let first = mains.first {
            let drop = min(base.mainTrackDropPoint(first.lead.start + delta, movingAll: []), work.mainTrackEnd)
            try work.magneticEdit { try $0.insertOnMain(inRun, at: drop) }
        }
        work.deriveAttachments()
        self = work
        return made
    }

    // MARK: Several main-track clips

    /// Drag of several main-track clips along V1 (Fast Cut): they leave V1 (it closes) and go in as one contiguous run,
    /// in timeline order, at the V1 edit nearest to where the first one was dragged (`by` from its start; their own
    /// edges left out, at most V1's end). Linked partners keep their offsets; attached clips travel with their hosts
    /// unless `keepAttached`. `ids` may name camera audio (its main clip moves). One clip: `magneticRearrange`.
    /// Normal: plain moves by `by`.
    public mutating func magneticRearrangeBlock(_ ids: Set<Clip.ID>, by delta: Time, keepAttached: Bool = false) throws {
        guard isFastCut, let mi = mainTrackIndex else {
            var work = self
            let order = ids.compactMap { work.find($0)?.clip }.sorted { delta > .zero ? $0.start > $1.start : $0.start < $1.start }
            for c in order { try work.move(c.id, to: c.start + delta) }
            self = work
            return
        }
        let mains = Set(ids.compactMap(mainClip(of:)))
        let clips = tracks[mi].clips.filter { mains.contains($0.id) }
        guard let first = clips.first else { throw EditError.clipNotFound }
        if clips.count == 1 { try magneticRearrange(first.id, to: first.start + delta, keepAttached: keepAttached); return }
        let drop = mainTrackDropPoint(first.start + delta, movingAll: mains)
        var work = self
        try work.magneticEdit(stay: keepAttached ? .hosts(mains) : .none) { try $0.rearrangeMainBlock(clips.map(\.id), to: drop) }
        self = work
    }

    /// The main-track clips `ids` (with their linked partners) leave V1 and go in at `drop` (pre-edit time, a V1 edit not
    /// of theirs) as one run in their order, V1 opening by their total length.
    mutating func rearrangeMainBlock(_ ids: [Clip.ID], to drop: Time) throws {
        guard let mi = mainTrackIndex else { throw EditError.wrongTrackKind }
        let mains = tracks[mi].clips.filter { ids.contains($0.id) }
        var seen = Set<Clip.ID>()
        var groups: [(main: Clip, members: [(clip: Clip, track: Track.ID)])] = []
        for v in mains {
            let g = try linkedGroup(v.id).filter { seen.insert($0.clip.id).inserted }
            groups.append((v, g.map { ($0.clip, tracks[$0.track].id) }))
        }
        var work = self
        try work.rippleDeleteMain(Set(mains.map(\.id)))
        let before = mains.filter { $0.timeline.end <= drop }.reduce(Time.zero) { $0 + $1.timeline.duration }
        let at = min(max(drop - before, .zero), work.mainTrackEnd)
        let total = mains.reduce(Time.zero) { $0 + $1.timeline.duration }
        try work.openMainHole(at: at, by: total)
        var cursor = at
        var placements: [(clip: Clip, track: Track.ID)] = []
        for g in groups {
            let s = cursor - g.main.start
            for m in g.members { var c = m.clip; c.start += s; placements.append((c, m.track)) }
            cursor += g.main.timeline.duration
        }
        try work.placeInMainHole(placements)
        self = work
    }

    /// Drag of main-track clips onto another track: V1 closes (Delete), the clips and their linked partners move by
    /// `delta` with the main-track ones on `target`, never covering anything, and become attached. Their attached clips
    /// travel by the same distance unless `keepAttached` (then they stay on their frame). Normal: plain moves.
    public mutating func dragOffMainTrack(_ ids: Set<Clip.ID>, to target: Track.ID, by delta: Time,
                                          keepAttached: Bool = false) throws {
        guard isFastCut, let mi = mainTrackIndex else {
            var work = self
            let order = ids.compactMap { work.find($0)?.clip }.sorted { delta > .zero ? $0.start > $1.start : $0.start < $1.start }
            for c in order { try work.move(c.id, to: c.start + delta, track: target) }
            self = work
            return
        }
        let mains = tracks[mi].clips.filter { ids.contains($0.id) }.map(\.id)
        guard !mains.isEmpty, let tr = track(target), tr.id != mainTrackID, tr.kind == .video else { throw EditError.wrongTrackKind }
        if tr.isLocked { throw EditError.trackLocked }
        var base = self
        base.deriveAttachments()
        var seen = Set<Clip.ID>()
        var group: [Member] = []
        for id in mains { group += try base.linkedGroup(id).filter { seen.insert($0.clip.id).inserted } }
        let followers = keepAttached ? [] : base.attachedClips(of: Set(mains)).filter { !seen.contains($0) }
        let carried = group.map(\.clip) + followers.compactMap { base.find($0)?.clip }
        var d = delta
        for c in carried { d = max(d, .zero - c.start) }
        let homes = Dictionary(uniqueKeysWithValues: (group.map { ($0.clip.id, base.tracks[$0.track].id) })
            + followers.compactMap { f in base.find(f).map { (f, base.tracks[$0.track].id) } })
        var stash: [Transition] = []
        var work = base
        try work.magneticEdit(involving: Set(followers), stay: keepAttached ? .hosts(Set(mains)) : .none) { tl in
            stash = tl.liftOut(Set(followers))
            try tl.rippleDeleteMain(Set(mains))
        }
        let onMain = Set(mains)
        for var c in carried {
            c.start += d
            c.attachment = nil
            try work.placeAttached(c, preferring: onMain.contains(c.id) ? target : homes[c.id] ?? target)
        }
        work.restoreMagnetic(stash)
        work.pruneTransitions()
        work.deriveAttachments()
        self = work
    }

    // MARK: Trim to playhead, speed, rate stretch

    /// Q / W with a mode (`trimToPlayhead`). Fast Cut: `.ripple` is `magneticRippleTrimToPlayhead`; `.roll` runs with
    /// every attached clip on its frame; `.plain` (Opt+Q / Opt+W) trims the attached clips under `t` alone (nothing else
    /// moves) and ripple-trims V1, because V1 never gets a hole. Attachments are re-derived. Normal: `trimToPlayhead`.
    @discardableResult
    public mutating func magneticTrimToPlayhead(_ edge: ClipEdge, at t: Time, mode: PlayheadTrimMode,
                                                keepAttached: Bool = false) throws -> Time {
        guard isFastCut, let mi = mainTrackIndex else { return try trimToPlayhead(edge, at: t, tracks: nil, mode: mode) }
        var work = self
        let moved: Time
        switch mode {
        case .ripple:
            moved = try work.magneticRippleTrimToPlayhead(edge, at: t, keepAttached: keepAttached).moved
        case .roll:
            moved = try work.magneticEdit(stay: .all) { try $0.trimToPlayhead(edge, at: t, tracks: nil, mode: .roll) }
        case .plain:
            func strictlyUnder(_ c: Clip) -> Bool { c.start < t && t < c.timeline.end }
            let under = tracks.indices.filter { $0 != mi && !tracks[$0].isLocked }.flatMap { i in
                tracks[i].clips.filter { strictlyUnder($0) && isAttachable($0.id) }.map { (i, $0.id) }
            }
            let onMain = tracks[mi].clips.contains(where: strictlyUnder)
            guard !under.isEmpty || onMain else { return try trimToPlayhead(edge, at: t, tracks: nil, mode: .plain) }
            var m = Time.zero
            if !under.isEmpty {
                let ids = Set(under.map(\.1)), lanes = Set(under.map(\.0)).sorted().map { tracks[$0].id }
                m = try work.magneticEdit(involving: ids, local: true) { try $0.trimToPlayhead(edge, at: t, tracks: lanes, mode: .plain) }
            }
            if onMain { m = try work.magneticRippleTrimToPlayhead(edge, at: t, keepAttached: keepAttached).moved }
            moved = m
        }
        self = work
        return moved
    }

    /// Speed/Duration and Reverse. Fast Cut: main-track clips (and camera audio) always ripple V1, whatever the Ripple
    /// setting (V1 never gets a hole or an overlap), and their attached clips go with them; attached clips are retimed
    /// alone, never rippling anything. Normal: `apply(_:to:)`.
    public mutating func magneticApply(_ change: SpeedChange, to ids: [Clip.ID]) throws {
        guard isFastCut else { try apply(change, to: ids); return }
        let mains = ids.filter(isMainMaterial), others = ids.filter { !isMainMaterial($0) }
        var work = self
        if !mains.isEmpty {
            var c = change
            c.ripple = true
            try work.magneticEdit { tl in
                try tl.apply(c, to: mains)
                // A linked partner that rounds to another length makes `apply` close by the smaller change only.
                try tl.closeMainHoles()
            }
        }
        if !others.isEmpty {
            var c = change
            c.ripple = false
            try work.magneticEdit(involving: Set(others), local: true) { try $0.apply(c, to: others) }
        }
        self = work
    }

    /// Rate Stretch tool. Fast Cut, a main-track clip (or its camera audio): its start stays, the length changes and V1
    /// ripples from its end by the change (either edge), attached clips following their hosts. An attached clip is
    /// stretched alone on its track. Normal: `rateStretch`. Returns how far the dragged edge moved.
    @discardableResult
    public mutating func magneticRateStretch(_ id: Clip.ID, edge: ClipEdge, by delta: Time) throws -> Time {
        guard isFastCut, let mi = mainTrackIndex else { return try rateStretch(id, edge: edge, by: delta) }
        var work = self
        let moved: Time
        if let main = mainClip(of: id), let v = tracks[mi].clip(main) {
            let change = edge == .tail ? delta : .zero - delta
            moved = try work.magneticEdit { tl in
                let oldEnd = v.timeline.end
                let room = max(change, .zero)
                if room > .zero { try tl.rippleMain(from: oldEnd, by: room) }
                try tl.rateStretch(id, edge: .tail, by: change)
                guard let mi2 = tl.mainTrackIndex, let n = tl.tracks[mi2].clip(main) else { throw EditError.clipNotFound }
                let fix = n.timeline.end - (oldEnd + room)
                if fix != .zero { try tl.rippleMain(from: oldEnd + room, by: fix) }
                let applied = n.timeline.end - oldEnd
                return edge == .tail ? applied : .zero - applied
            }
        } else {
            moved = try work.magneticEdit(involving: [id], local: true) { try $0.rateStretch(id, edge: edge, by: delta) }
        }
        self = work
        return moved
    }

    /// Closes every hole between main-track clips by rippling the later clips (and their partners) left.
    mutating func closeMainHoles() throws {
        guard let mi = mainTrackIndex else { return }
        for _ in 0..<(tracks[mi].clips.count + 1) {
            let sorted = tracks[mi].clips.sorted { $0.start < $1.start }
            guard let i = sorted.indices.dropLast().first(where: { sorted[$0].timeline.end < sorted[$0 + 1].start }) else { return }
            let gap = sorted[i + 1].start - sorted[i].timeline.end
            try rippleMain(from: sorted[i + 1].start, by: .zero - gap)
        }
    }

    // MARK: Speed ramps

    /// Speed ramp edit (`editSpeedKeys`). Fast Cut, a main-track clip (or its camera audio): V1 ripples from the clip's
    /// end by the length change (later clips take their linked partners along), so a ramp never leaves a gap or pushes
    /// into a neighbor; attached clips follow their hosts. An attached clip is retimed alone. Normal: `editSpeedKeys`.
    /// Returns the change of the clip's timeline duration.
    @discardableResult
    public mutating func magneticEditSpeedKeys(_ id: Clip.ID, keepingKeys: Bool = false, refuseShortening: Bool = false,
                                               _ edit: (SpeedKeys) -> SpeedKeys?) throws -> Time {
        guard isFastCut, mainTrackIndex != nil else { return try editSpeedKeys(id, keepingKeys: keepingKeys, refuseShortening: refuseShortening, edit) }
        var work = self
        let change: Time
        if let main = mainClip(of: id), let v = tracks[mainTrackIndex!].clip(main) {
            change = try work.magneticEdit { tl in
                let oldEnd = v.timeline.end
                // Room first (the edit may grow the clip), then close what is left over.
                let room = Time(3600, 1)
                try tl.rippleMain(from: oldEnd, by: room)
                let result = try tl.editSpeedKeys(id, keepingKeys: keepingKeys, refuseShortening: refuseShortening, edit)
                guard let mi2 = tl.mainTrackIndex, let n = tl.tracks[mi2].clip(main) else { throw EditError.clipNotFound }
                let fix = n.timeline.end - (oldEnd + room)
                if fix != .zero { try tl.rippleMain(from: oldEnd + room, by: fix) }
                return result
            }
        } else {
            change = try work.magneticEdit(involving: [id], local: true) {
                try $0.editSpeedKeys(id, keepingKeys: keepingKeys, refuseShortening: refuseShortening, edit)
            }
        }
        self = work
        return change
    }

    // MARK: Frame hold

    /// Insert Frame Hold Segment. Fast Cut: a main-track clip (or its camera audio) splits and the held copy goes in
    /// with V1 rippling by its length (no hole, attached clips stay with their hosts); an attached clip is refused
    /// (`.wrongTrackKind`: inserting would ripple the main track under it). Normal: `insertFrameHold`.
    @discardableResult
    public mutating func magneticInsertFrameHold(of clipID: Clip.ID? = nil, at time: Time, duration: Time) throws -> Clip.ID {
        guard isFastCut, mainTrackIndex != nil else { return try insertFrameHold(of: clipID, at: time, duration: duration) }
        if let clipID, !isMainMaterial(clipID) { throw EditError.wrongTrackKind }
        return try magneticEdit { try $0.insertFrameHold(of: clipID, at: time, duration: duration) }
    }

    /// Add Frame Hold. Fast Cut: the clip's length and everything around it stay; attached clips keep their frame.
    @discardableResult
    public mutating func magneticAddFrameHold(of clipID: Clip.ID? = nil, at time: Time) throws -> Clip.ID {
        guard isFastCut, mainTrackIndex != nil else { return try addFrameHold(of: clipID, at: time) }
        if let clipID, !isMainMaterial(clipID) {
            return try magneticEdit(involving: [clipID], local: true) { try $0.addFrameHold(of: clipID, at: time) }
        }
        return try magneticEdit { try $0.addFrameHold(of: clipID, at: time) }
    }

    // MARK: Opt+Up / Opt+Down

    /// Opt+Up / Opt+Down. Normal: `moveToLane`. Fast Cut: main-track clips only go up (`liftOffMainTrack`, a spacer
    /// stays); attached video clips on the video lane right above V1 going down are put on the main track
    /// (`putOnMainTrack`, their linked partners stay where they are); every other clip changes lane and re-attaches.
    /// Returns false, changing nothing, when no clip can move that way.
    @discardableResult
    public mutating func magneticMoveToLane(_ ids: Set<Clip.ID>, up: Bool) throws -> Bool {
        guard isFastCut, let mi = mainTrackIndex else { return try moveToLane(ids, up: up) }
        if ids.contains(where: isOnMainTrack) {
            guard up else { return false }
            try liftOffMainTrack(ids)
            return true
        }
        let videoLanes = tracks.indices.filter { tracks[$0].kind == .video }
        let above = videoLanes.firstIndex(of: mi).flatMap { videoLanes.indices.contains($0 + 1) ? videoLanes[$0 + 1] : nil }
        let down = up ? [] : ids.compactMap { find($0) }.filter { $0.track == above && $0.clip.kind == .video }.map(\.clip)
        guard !down.isEmpty else {
            return try magneticEdit(involving: ids, stay: .all) { try $0.moveToLane(ids, up: up) }
        }
        let links = Set(down.compactMap(\.link))
        let rest = ids.filter { id in
            guard let c = find(id)?.clip else { return false }
            return !down.contains { $0.id == id } && !(c.link.map(links.contains) ?? false)
        }
        var work = self
        try work.putOnMainTrack(Set(down.map(\.id)))
        if !rest.isEmpty {
            guard try work.magneticEdit(involving: rest, stay: .all, { try $0.moveToLane(rest, up: up) }) else { return false }
        }
        self = work
        return true
    }
}
