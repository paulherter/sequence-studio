import Foundation

// W7.6 Groups. A Group is a nested sequence used as a layer group (the maintainer's Premiere nests: "group these layers, give them a card
// look with a shadow and animate them as one"). It reuses Nest: the grouped clips move into an inner sequence of the outer format,
// and the outer timeline gets one clip (plus a linked audio clip when audio was grouped) that plays it. That clip is the group's
// own transform stage: its Motion (Position / Scale / Rotation / Anchor), Opacity, Transform / motion-preset effects and Drop Shadow
// act on the composited group picture as a whole (Evaluation renders the inner layers into one image first).
//
// What makes it a Group and not a Nest: `Timeline.group` is set (v30). Groups are named "Group NN", are not filed in the Project
// panel (`normalizeBins` skips them), keep the transitions between the grouped clips, and remember which outer track each inner
// track came from, so Ungroup puts every clip back where it was.
//
// Ungroup is lossless:
// - an untouched group comes apart into exactly the clips that went in (same ids, tracks, timing, transitions);
// - the group's Motion and Opacity (static or keyed) move onto every video clip as one `groupTransform` effect: a canvas-space stage
//   applied after the clip's own Motion, so each clip lands where it was drawn inside the group (exact for uniform group scale or
//   unrotated clips, like the transform stages; opacity multiplies, which equals the group opacity where the clips do not overlap);
// - everything that cannot move onto the clips without changing the picture (group effects such as Drop Shadow, speed, hold,
//   blend mode, transitions on the group clip, audio gain / volume / fades, variant overrides; inside: see `keepsPicture`,
//   track state that does not carry over, markers / In-Out / captions) refuses Ungroup with `.ungroupLosesLook`.
// Group sequences no clip plays any more are dropped when saving (`pruneUnusedGroups`).
// A trimmed group trims its clips to the part it showed.

/// The inside of a Group (W7.6): stored on its inner sequence.
public struct TimelineGroup: Sendable, Hashable, Codable {
    /// Inner track id -> the outer track it came from. Ungroup returns clips to these tracks while they exist; inner tracks
    /// added later (or whose outer track is gone) fall back to counting tracks up from the group clip's track.
    public var sourceTracks: [Track.ID: Track.ID]
    public init(sourceTracks: [Track.ID: Track.ID]) { self.sourceTracks = sourceTracks }
}

extension Timeline {
    /// The inside of a Group, not an ordinary sequence.
    public var isGroup: Bool { group != nil }
}

extension Project {
    /// The sequences a user can pick (Export, opening, Project panel): everything but the inside of Groups, which only
    /// the group clip that plays one reaches (Ungroup, or a double click into it).
    public var pickableTimelines: [Timeline] { timelines.filter { !$0.isGroup } }

    /// The Group a clip plays, if it plays one.
    public func groupSequence(of clip: Clip) -> Timeline? {
        guard let id = clip.sequence, let t = timeline(id), t.isGroup else { return nil }
        return t
    }

    /// Group: replaces the selected clips (and their linked partners) with one group clip (see the file comment). Transitions
    /// between grouped clips go inside; transitions from a grouped clip to one outside the group are removed (as Nest does).
    /// Throws as `nest(clips:in:name:)`. Returns the group's inner sequence.
    @discardableResult
    public mutating func group(clips ids: [Clip.ID], in timelineID: Timeline.ID) throws -> Timeline.ID {
        guard let tl = timeline(timelineID) else { throw EditError.timelineNotFound }
        guard !ids.isEmpty else { throw EditError.emptyClip }
        var selected = Set<Clip.ID>()
        for id in ids { for m in try tl.linkedGroup(id) { selected.insert(m.clip.id) } }
        // Same track choice as `nest`: every track holding a selected clip, in timeline order.
        let involved = tl.tracks.indices.filter { i in tl.tracks[i].clips.contains { selected.contains($0.id) } }
        let inside: [[Transition]] = involved.map { i in
            tl.tracks[i].transitions.filter { tr in
                let ends = [tr.outgoing, tr.incoming].compactMap { $0 }
                return !ends.isEmpty && ends.allSatisfy(selected.contains)
            }
        }
        var work = self
        let seqID = try work.nest(clips: ids, in: timelineID, name: nextGroupName())
        guard let si = work.timelines.firstIndex(where: { $0.id == seqID }),
              let oi = work.timelines.firstIndex(where: { $0.id == timelineID }) else { throw EditError.timelineNotFound }
        var map: [Track.ID: Track.ID] = [:]
        for (k, i) in involved.enumerated() where k < work.timelines[si].tracks.count {
            map[work.timelines[si].tracks[k].id] = tl.tracks[i].id
        }
        work.timelines[si].group = TimelineGroup(sourceTracks: map)
        for (k, trs) in inside.enumerated() where k < work.timelines[si].tracks.count {
            work.timelines[si].tracks[k].transitions = trs
        }
        work.rootBin.prune { $0 != .sequence(seqID) }
        work.timelines[oi].pruneTransitions()
        self = work
        return seqID
    }

    /// Ungroup: puts the clips of the group `clipID` plays (this clip and its linked partner of the same group) back on the
    /// timeline, see the file comment. Clips return to their source tracks; when one is gone, to the tracks of the same kind
    /// counted up from the group clip's track (new tracks are added on top when there are too few). A copy of a group whose
    /// clips are already on the timeline gets fresh clip ids. The inner sequence is removed once no clip plays it.
    /// Throws `.notAGroup`, `.ungroupLosesLook`, `.trackLocked`, `.collision` (a returning clip would cover another one).
    /// Returns the ids of the clips put back.
    @discardableResult
    public mutating func ungroup(clip clipID: Clip.ID, in timelineID: Timeline.ID) throws -> [Clip.ID] {
        try restoreContent(of: clipID, in: timelineID, plain: false)
    }

    /// Unnest: replaces a clip that plays an ordinary nested sequence (not a Group) with the sequence's content, under the
    /// same rules as Ungroup (the clip's Motion becomes a group-transform stage on every clip, anything that cannot carry over
    /// refuses with `.ungroupLosesLook`). The nested sequence stays in the project; the placed clips are fresh copies.
    /// A nested sequence of another frame size refuses (its pictures would reframe). Throws `.notNested` for a Group or a
    /// clip that plays no sequence.
    @discardableResult
    public mutating func unnest(clip clipID: Clip.ID, in timelineID: Timeline.ID) throws -> [Clip.ID] {
        guard let oi = timelines.firstIndex(where: { $0.id == timelineID }), timelines[oi].isFastCut else {
            return try restoreContent(of: clipID, in: timelineID, plain: true)
        }
        // Fast Cut: runs through `magneticEdit` (attached clips keep their hosts) and closes the holes the content leaves on V1
        // (a nested sequence whose own main track has gaps), so V1 stays gapless.
        var work = self
        var tl = timelines[oi]
        let restored: [Clip.ID] = try tl.magneticEdit(involving: [clipID]) { w in
            work.timelines[oi] = w
            let ids = try work.restoreContent(of: clipID, in: timelineID, plain: true)
            w = work.timelines[oi]
            try w.closeMainHoles()
            return ids
        }
        work.timelines[oi] = tl
        self = work
        return restored
    }

    private mutating func restoreContent(of clipID: Clip.ID, in timelineID: Timeline.ID, plain: Bool) throws -> [Clip.ID] {
        guard let oi = timelines.firstIndex(where: { $0.id == timelineID }) else { throw EditError.timelineNotFound }
        var tl = timelines[oi]
        guard let hit = tl.find(clipID) else { throw EditError.clipNotFound }
        guard let seqID = hit.clip.sequence, let inner = timeline(seqID) else { throw EditError.notAGroup }
        if plain {
            guard inner.group == nil, hit.clip.angle == nil else { throw EditError.notNested }
            guard inner.format.displayWidth == tl.format.displayWidth, inner.format.height == tl.format.height else {
                throw EditError.ungroupLosesLook
            }
        } else if inner.group == nil { throw EditError.notAGroup }
        let info = inner.group ?? TimelineGroup(sourceTracks: [:])
        let partners = try tl.linkedGroup(clipID).filter { $0.clip.sequence == seqID }
        if partners.contains(where: { tl.tracks[$0.track].isLocked }) { throw EditError.trackLocked }
        let partnerIDs = Set(partners.map(\.clip.id))
        for m in partners {
            guard Self.ungroupKeepsLook(m.clip) else { throw EditError.ungroupLosesLook }
            let touching = tl.tracks[m.track].transitions.contains { tr in
                [tr.outgoing, tr.incoming].contains { $0.map(partnerIDs.contains) ?? false }
            }
            if touching { throw EditError.ungroupLosesLook }
        }
        // Sequence items Ungroup has nowhere to put (markers, In/Out, captions, Sequence Volume).
        // A group's own Sequence Volume would need folding into every inner track and clip: refused like the other items.
        // Unnest keeps the sequence, so its markers, In/Out and captions stay there and are not a loss.
        if (!plain && (!inner.markers.isEmpty || inner.inOut != nil || inner.captionTracks.contains(where: { !$0.items.isEmpty })))
            || inner.masterVolumeDB != 0 || inner.isMasterVolumeKeyed {
            throw EditError.ungroupLosesLook
        }
        for m in partners { tl.tracks[m.track].remove(m.clip.id) }
        // Track ids, not indices: a track added below for one partner shifts the indices of the next.
        let partnerTracks = partners.map { tl.tracks[$0.track] }

        // Inner clips per partner, cropped to what the group shows and moved to outer time.
        var placed: [(track: Int, clips: [Clip], transitions: [Transition])] = []
        var outerTrack: [Track.ID: Track.ID] = [:]      // inner video track -> the outer track its clips land on
        for (m, partnerTrack) in zip(partners, partnerTracks) {
            let g = m.clip, kind = g.kind
            let own = tl.tracks.firstIndex { $0.id == partnerTrack.id }
            let window = g.source
            let kindTracks = tl.tracks.indices.filter { tl.tracks[$0].kind == kind }
            var cropped: [Track] = []
            for it in inner.tracks where it.kind == kind {
                var scratch = it
                if window.start > .zero { scratch.clear(TimeRange(start: .zero, end: window.start)) }
                if scratch.end > window.end { scratch.clear(TimeRange(start: window.end, end: scratch.end)) }
                cropped.append(scratch)
            }
            if kind == .video, !keepsPicture(of: g, inner: cropped, canvas: inner.format) { throw EditError.ungroupLosesLook }
            for (ordinal, scratch) in cropped.enumerated() {
                guard !scratch.clips.isEmpty else { continue }
                let target: Int
                if let src = info.sourceTracks[scratch.id], let i = tl.tracks.firstIndex(where: { $0.id == src }),
                   tl.tracks[i].kind == kind {
                    target = i
                } else if let own, let base = kindTracks.firstIndex(of: own), base + ordinal < kindTracks.count {
                    target = kindTracks[base + ordinal]
                } else {
                    let after = (tl.tracks.indices.last { tl.tracks[$0].kind == kind } ?? (tl.tracks.count - 1)) + 1
                    tl.tracks.insert(Track(kind: kind), at: after)
                    for p in placed.indices where placed[p].track >= after { placed[p].track += 1 }
                    target = after
                }
                if tl.tracks[target].isLocked { throw EditError.trackLocked }
                guard Self.trackStateCarries(inner: scratch, through: partnerTrack, to: tl.tracks[target]) else {
                    throw EditError.ungroupLosesLook
                }
                if kind == .video {
                    outerTrack[scratch.id] = tl.tracks[target].id
                    // An Adjustment Layer only reached the inner layers below it; on the outer timeline it would also reach
                    // the outer clips on lower tracks it overlaps.
                    for adj in scratch.clips where adj.isAdjustment {
                        let range = TimeRange(start: adj.start - window.start + g.start, duration: adj.timeline.duration)
                        let reaches = tl.tracks[..<target].contains { t in
                            t.kind == .video && t.isVisible && t.clips.contains { $0.timeline.overlaps(range) }
                        }
                        if reaches { throw EditError.ungroupLosesLook }
                    }
                }
                let clips = scratch.clips.map { c -> Clip in
                    var c = c
                    c.start = c.start - window.start + g.start
                    if kind == .video, let e = ClipEffect.groupTransform(from: g, shift: g.start - c.start), !e.isIdentityGroupStage {
                        c.effects.append(e)
                    }
                    return c
                }
                placed.append((target, clips, scratch.transitions))
            }
        }

        // Picture masks read inner track ids: follow them to the outer tracks the clips landed on; a matte track whose clips
        // were not placed has no outer equivalent, so the mask reads nothing.
        for p in placed.indices where tl.tracks[placed[p].track].kind == .video {
            placed[p].clips = placed[p].clips.map { c in
                guard c.masks.contains(where: { $0.source == .picture && $0.pictureTrack != nil })
                        || c.effects.contains(where: { $0.isTrackMask && $0.maskTrack != nil }) else { return c }
                var c = c.mappingTrackMasks { outerTrack[$0] }
                c.masks = c.masks.map { m in
                    guard m.source == .picture, let old = m.pictureTrack else { return m }
                    var m = m
                    m.pictureTrack = outerTrack[old]
                    return m
                }
                return c
            }
        }

        // A copy of a group whose clips are already back gets fresh ids (and links, so the copies link to each other).
        let existing = Set(tl.tracks.flatMap(\.clips).map(\.id))
        if plain || placed.contains(where: { $0.clips.contains { existing.contains($0.id) } }) {
            var ids: [UUID: UUID] = [:], links: [UUID: UUID] = [:]
            for p in placed.indices {
                placed[p].clips = placed[p].clips.map { c in
                    var c = c
                    let fresh = UUID(); ids[c.id] = fresh; c.id = fresh
                    if let l = c.link { if links[l] == nil { links[l] = UUID() }; c.link = links[l] }
                    return c
                }
            }
            for p in placed.indices {
                for k in placed[p].clips.indices where placed[p].clips[k].attachment != nil { placed[p].clips[k].remapAttachment(ids) }
                placed[p].transitions = placed[p].transitions.map { tr in
                    var tr = tr
                    tr.id = UUID()
                    tr.outgoing = tr.outgoing.map { ids[$0] ?? $0 }; tr.incoming = tr.incoming.map { ids[$0] ?? $0 }
                    return tr
                }
            }
        }

        for p in placed {
            for c in p.clips {
                if tl.tracks[p.track].clips.contains(where: { $0.timeline.overlaps(c.timeline) }) { throw EditError.collision }
                try tl.tracks[p.track].overwrite(c)
            }
            tl.tracks[p.track].transitions += p.transitions
        }
        tl.pruneTransitions()
        // Fast Cut: clips attached to the group clip go back to the restored clip under their attach time (nest moved them
        // onto the group clip); with none there they are dropped and re-derived at the next Fast Cut edit.
        let back = Set(placed.flatMap { $0.clips.map(\.id) })
        for i in tl.tracks.indices where tl.tracks[i].clips.contains(where: { $0.attachment.map { partnerIDs.contains($0.host) } ?? false }) {
            let snapshot = tl
            tl.tracks[i].mapClipsKeepingTiming { c in
                guard let a = c.attachment, partnerIDs.contains(a.host) else { return c }
                var c = c
                let host = snapshot.attachHost(at: c.start + a.point)
                c.attachment = host.flatMap { back.contains($0) ? ClipAttachment(host: $0, point: a.point) : nil }
                return c
            }
        }
        // One side of an unlinked group: its clips' partners stay inside the other side, so their links point at nothing.
        let restoredLinks = Set(placed.flatMap { $0.clips.compactMap(\.link) })
        var linkCount: [UUID: Int] = [:]
        for t in tl.tracks { for c in t.clips { if let l = c.link, restoredLinks.contains(l) { linkCount[l, default: 0] += 1 } } }
        let restored = Set(placed.flatMap { $0.clips.map(\.id) })
        for i in tl.tracks.indices {
            for var c in tl.tracks[i].clips where restored.contains(c.id) {
                if let l = c.link, linkCount[l, default: 0] < 2 { c.link = nil; tl.tracks[i].replace(c) }
            }
        }

        var work = self
        work.timelines[oi] = tl
        if !plain, !work.timelines.contains(where: { t in t.tracks.contains { $0.clips.contains { $0.sequence == seqID } } }) {
            work.timelines.removeAll { $0.id == seqID }
            work.rootBin.prune { $0 != .sequence(seqID) }
        }
        self = work
        return placed.flatMap { $0.clips.map(\.id) }
    }

    /// Removes Groups no clip plays any more (their clips were deleted, or the sequence playing them was), until none is
    /// left. Groups are not in the Project panel, so nothing else could reach them. Run when saving: in the session undo
    /// and the clipboard can still bring the group clips back.
    public mutating func pruneUnusedGroups() {
        while true {
            let played = Set(timelines.flatMap { $0.tracks.flatMap { $0.clips.compactMap(\.sequence) } })
            let unused = Set(timelines.filter { $0.isGroup && !played.contains($0.id) }.map(\.id))
            guard !unused.isEmpty else { return }
            timelines.removeAll { unused.contains($0.id) }
            rootBin.prune { item in
                if case .sequence(let id) = item { return !unused.contains(id) }
                return true
            }
        }
    }

    /// True when everything the group clip `g` does besides its Motion and Opacity is at its default, so Ungroup changes nothing.
    static func ungroupKeepsLook(_ g: Clip) -> Bool {
        guard g.isEnabled, !g.isRetimed, g.holdFrame == nil, g.effects.isEmpty, g.blendMode == .normal,
              g.variantOverrides.isEmpty else { return false }
        if g.kind == .audio {
            let v = g.animation.volume
            return !v.isAnimated && v.value == 1 && g.audioGainDB == 0 && g.audioFades.isEmpty
        }
        return true
    }

    /// Inner track state (visibility, mute, solo, volume, pan, role) that played through the group clip's track `outer` and
    /// plays the same from `target` after Ungroup.
    static func trackStateCarries(inner i: Track, through outer: Track, to target: Track) -> Bool {
        if i.kind == .video { return (i.isVisible && outer.isVisible) == target.isVisible }
        guard (i.isMuted || outer.isMuted) == target.isMuted, outer.isSolo == target.isSolo,
              !i.isSolo || target.isSolo,
              abs(i.volumeDB + outer.volumeDB - target.volumeDB) < 1e-9,
              (i.pan == 0 && outer.pan == target.pan) || (outer.pan == 0 && i.pan == target.pan) else { return false }
        return (i.audioRole ?? outer.audioRole) == target.audioRole
    }

    /// True when the inner video tracks (cropped to what group clip `g` shows) look the same composited one by one through the
    /// group's stage on the canvas as composited into the group picture first:
    /// - no blend mode inside (it blended against the group's transparent picture, not the clips below);
    /// - with a moved / scaled / rotated / faded group: only dissolves inside (a dip fills, a motion transition moves within
    ///   the group frame), no open shutter (the blur would pick up the group's motion), nothing outside the group frame
    ///   (the frame cut it; on the canvas the group's stage could bring it on screen);
    /// - with a non-uniform group scale: no rotated clip (the composed stage cannot skew);
    /// - with a group opacity below 1: no clips that overlap in time (they were faded as one picture, not one by one).
    func keepsPicture(of g: Clip, inner tracks: [Track], canvas: SequenceFormat) -> Bool {
        let clips = tracks.flatMap(\.clips)
        if clips.contains(where: { $0.blendMode != .normal }) { return false }
        guard let stage = ClipEffect.groupTransform(from: g, shift: .zero), !stage.isIdentityGroupStage else { return true }
        let transitions = tracks.flatMap(\.transitions)
        if transitions.contains(where: { $0.kind != .crossDissolve && $0.kind != .quickFade }) { return false }
        let open = clips.contains { c in
            c.animation.isShutterOpenOrKeyed || c.effects.contains { e in
                guard e.enabled, e.isTransformStage, let s = e.parameters[ClipEffect.stageShutterAngleKey] else { return false }
                return s.value > 0 || s.track.keys.contains { $0.value > 0 }
            }
        }
        if open { return false }
        if let s = stage.points[ClipEffect.groupScaleKey], s.value.x != s.value.y || s.track.keys.contains(where: { $0.value.x != $0.value.y }) {
            let rotated = clips.contains { c in
                c.animation.rotation.value != 0 || c.animation.rotation.isAnimated || c.hasTransformStage
            }
            if rotated { return false }
        }
        if let o = stage.parameters[ClipEffect.groupOpacityKey], o.value != 1 || o.isAnimated {
            if !transitions.isEmpty { return false }
            for (i, a) in clips.enumerated() where clips[(i + 1)...].contains(where: { $0.timeline.overlaps(a.timeline) }) {
                return false
            }
        }
        // Frame corners inside the group frame at every frame (one sample for a clip that does not move). Effects that draw past
        // the picture (Drop Shadow) widen the clip's frame by their reach: the group frame cut that part off.
        let half = Vec2(Double(canvas.displayWidth) / 2 + 0.5, Double(canvas.height) / 2 + 0.5)
        let frame = Vec2(Double(canvas.displayWidth), Double(canvas.height))
        let fd = canvas.frameDuration
        for c in clips {
            let size = pictureSize(of: c) ?? (width: canvas.displayWidth, height: canvas.height)
            let bleed = Self.frameBleed(of: c)
            let w = Double(size.width) / 2 + bleed, h = Double(size.height) / 2 + bleed
            let corners = [Vec2(-w, -h), Vec2(w, -h), Vec2(w, h), Vec2(-w, h)]
            let a = c.animation
            let moves = a.position.isAnimated || a.scale.isAnimated || a.rotation.isAnimated || a.anchor.isAnimated
                || c.hasTransformStage
            var times = [c.start]
            if moves, fd > .zero {
                // Every frame, at most about 600 samples (a long clip is sampled every few frames).
                var step = fd
                while step * 600 < c.source.duration { step = step * 2 }
                times = []
                var t = c.start
                while t < c.timeline.end { times.append(t); t = t + step }
            }
            for t in times {
                let tr = c.renderTransform(at: t, frame: frame)
                for p in corners {
                    let q = tr.map(p)
                    if abs(q.x) > half.x || abs(q.y) > half.y { return false }
                }
            }
        }
        return true
    }

    /// How far (px of the clip's own frame, upper bound at any keyframe) the enabled effects of `c` draw past its picture.
    /// Drop Shadow reaches its distance plus twice its softness.
    static func frameBleed(of c: Clip) -> Double {
        func peak(_ p: AnimatedProperty<Double>?) -> Double {
            guard let p else { return 0 }
            return max(abs(p.value), p.track.keys.map { abs($0.value) }.max() ?? 0)
        }
        var reach = 0.0
        for e in c.effects where e.enabled && e.kind == ClipEffect.dropShadowKind {
            let defaults = EffectCatalog.param(e.kind, ClipEffect.shadowDistanceKey)?.defaultValue ?? 0
            let soft = EffectCatalog.param(e.kind, ClipEffect.shadowSoftnessKey)?.defaultValue ?? 0
            let d = e.parameters[ClipEffect.shadowDistanceKey] == nil ? defaults : peak(e.parameters[ClipEffect.shadowDistanceKey])
            let f = e.parameters[ClipEffect.shadowSoftnessKey] == nil ? soft : peak(e.parameters[ClipEffect.shadowSoftnessKey])
            reach = max(reach, d + 2 * f)
        }
        return reach
    }

    private func nextGroupName() -> String {
        let names = Set(timelines.map(\.name))
        var n = 1
        while names.contains(String(format: "Group %02d", n)) { n += 1 }
        return String(format: "Group %02d", n)
    }
}

// MARK: Group Transform effect

extension ClipEffect {
    /// The Motion and Opacity of an ungrouped Group on one of its clips: a stage in canvas px applied after the clip's own Motion
    /// (render = group ∘ Motion ∘ transform stages). Written by Ungroup only; not offered in the Effects panel.
    public static let groupTransformKind = "groupTransform"
    // Stored keys (never rename): the group clip's Motion properties, values and keys as they were.
    public static let groupPositionKey = "position", groupScaleKey = "scale", groupAnchorKey = "anchor"
    public static let groupRotationKey = "rotation", groupOpacityKey = "opacity"

    static let groupTransformSpec = EffectSpec(kind: groupTransformKind, title: "Group Transform", params: [
        .point(groupPositionKey, "Position"),
        EffectParamSpec(key: groupScaleKey, title: "Scale", unit: "%", defaultValue: 0, range: 0...100, step: 0.01,
                        decimals: 1, kind: .point(Vec2(1, 1)), displayScale: 100),
        EffectParamSpec(key: groupRotationKey, title: "Rotation", unit: "\u{00B0}", defaultValue: 0,
                        range: -36_000...36_000, step: 1, decimals: 1),
        .point(groupAnchorKey, "Anchor"),
        EffectParamSpec(key: groupOpacityKey, title: "Opacity", unit: "%", defaultValue: 1, range: 0...1, step: 0.01, decimals: 1,
                        displayScale: 100),
    ])

    /// The Group Transform for a clip of group clip `g`: its Motion (when Motion is on) and Opacity (when Opacity is on), every key
    /// moved by `shift` (the group clip's start minus this clip's start). Nil for an audio clip.
    public static func groupTransform(from g: Clip, shift: Time) -> ClipEffect? {
        guard g.kind == .video else { return nil }
        var e = ClipEffect(kind: groupTransformKind)
        let a = g.animation
        if g.motionEnabled {
            e.points[groupPositionKey] = a.position.shifted(by: shift)
            e.points[groupScaleKey] = a.scale.shifted(by: shift)
            e.points[groupAnchorKey] = a.anchor.shifted(by: shift)
            e.parameters[groupRotationKey] = a.rotation.shifted(by: shift)
        }
        if g.opacityEnabled { e.parameters[groupOpacityKey] = a.opacity.shifted(by: shift) }
        return e
    }

    /// A Group Transform that moves nothing and keeps the opacity (no keys, identity values).
    public var isIdentityGroupStage: Bool {
        guard kind == Self.groupTransformKind else { return false }
        let pts: [(String, Vec2)] = [(Self.groupPositionKey, .zero), (Self.groupScaleKey, Vec2(1, 1)), (Self.groupAnchorKey, .zero)]
        let sc: [(String, Double)] = [(Self.groupRotationKey, 0), (Self.groupOpacityKey, 1)]
        return pts.allSatisfy { k, d in points[k].map { !$0.isAnimated && $0.value == d } ?? true }
            && sc.allSatisfy { k, d in parameters[k].map { !$0.isAnimated && $0.value == d } ?? true }
    }

    /// The group's transform at clip-local `t` (clamped like `Clip.transform(at:)`).
    func groupStage(atLocal t: Time) -> ClipTransform {
        let s = points[Self.groupScaleKey]?.value(atLocal: t) ?? Vec2(1, 1)
        return ClipTransform(position: points[Self.groupPositionKey]?.value(atLocal: t) ?? .zero,
                             scale: Vec2(max(s.x, 0), max(s.y, 0)),
                             rotation: parameters[Self.groupRotationKey]?.value(atLocal: t) ?? 0,
                             opacity: min(max(parameters[Self.groupOpacityKey]?.value(atLocal: t) ?? 1, 0), 1),
                             anchor: points[Self.groupAnchorKey]?.value(atLocal: t) ?? .zero)
    }
}

extension ClipTransform {
    /// `self` (an outer, group transform) applied after `inner`: one transform that maps a point as `self.map(inner.map(p))`.
    /// Exact when `self`'s scale is uniform or `inner` is not rotated; otherwise the anchor lands exactly and the picture is
    /// scaled after the summed rotation (no skew). Opacities multiply.
    public func composed(after inner: ClipTransform) -> ClipTransform {
        let l = Affine2.rotScale(rotation, scale.x, scale.y)
        return ClipTransform(position: l.linear(inner.position - anchor) + position,
                             scale: Vec2(scale.x * inner.scale.x, scale.y * inner.scale.y),
                             rotation: rotation + inner.rotation, opacity: opacity * inner.opacity, anchor: inner.anchor,
                             tiltX: inner.tiltX, tiltY: inner.tiltY)
    }
}

extension Clip {
    /// `tr` after the clip's enabled Group Transform effects, in list order (the first is the innermost group).
    func applyingGroupStages(_ tr: ClipTransform, at t: Time) -> ClipTransform {
        var out = tr
        let local = t - start
        for e in effects where e.enabled && e.kind == ClipEffect.groupTransformKind {
            out = e.groupStage(atLocal: local).composed(after: out)
        }
        return out
    }
}

extension ClipTransform {
    /// Inverse of `composed(after:)` for a chain: `self` drawn after the group `stages` (in list order) becomes the transform
    /// the clip had before them. A stage with zero scale or opacity cannot be undone and leaves that component unchanged.
    public func removingGroupStages(_ stages: [ClipTransform]) -> ClipTransform {
        var out = self
        for g in stages.reversed() {
            let a = -g.rotation * .pi / 180
            let d = out.position - g.position
            let r = Vec2(d.x * cos(a) - d.y * sin(a), d.x * sin(a) + d.y * cos(a))
            let sx = abs(g.scale.x) > 1e-9 ? g.scale.x : 1, sy = abs(g.scale.y) > 1e-9 ? g.scale.y : 1
            out.position = Vec2(r.x / sx + g.anchor.x, r.y / sy + g.anchor.y)
            out.scale = Vec2(out.scale.x / sx, out.scale.y / sy)
            out.rotation -= g.rotation
            if g.opacity > 1e-9 { out.opacity /= g.opacity }
        }
        return out
    }
}

extension Clip {
    /// The enabled Group Transform effects of this clip at `t` as transforms, in list order (the first is the innermost group).
    public func groupStageTransforms(at t: Time) -> [ClipTransform] {
        effects.filter { $0.enabled && $0.kind == ClipEffect.groupTransformKind }.map { $0.groupStage(atLocal: t - start) }
    }
}
