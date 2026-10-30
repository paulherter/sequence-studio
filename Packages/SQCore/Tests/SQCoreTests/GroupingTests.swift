import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func f(_ n: Int64) -> Time { Time(n, 30) }
/// One 640 x 360 picture every fixture clip plays (so Ungroup can measure their frames).
private let pic = UUID()
private let picRef = MediaRef(id: pic, name: "pic", path: "/pic.mov", fingerprint: MediaFingerprint(size: 1),
                              info: MediaInfo(duration: s(100), video: VideoTrackInfo(
                                width: 640, height: 360, codec: "h264", bitDepth: 8, chroma: "420",
                                nominalFrameDuration: Time(1, 30), isVariableFrameRate: false)))
private func clip(_ start: Int64, _ dur: Int64, src: Int64 = 0, kind: TrackKind = .video,
                  link: UUID? = nil, media: UUID = pic) -> Clip {
    Clip(name: "c", media: media, kind: kind, source: TimeRange(start: s(src), duration: s(dur)), start: s(start), link: link,
         mediaDuration: s(100))
}
private func track(_ clips: [Clip], kind: TrackKind = .video) throws -> Track {
    var t = Track(kind: kind)
    for c in clips { try t.overwrite(c) }
    return t
}
private func tl(_ name: String, _ tracks: [Track]) -> Timeline { Timeline(name: name, frameDuration: Time(1, 30), tracks: tracks) }

/// Where clip-frame point `p` of a layer lands on the top canvas: its own transform, then each enclosing group's.
private func place(_ l: LayerRequest, _ p: Vec2) -> Vec2 {
    var q = l.transform.map(p)
    for g in l.groups.reversed() { q = g.transform.map(q) }
    return q
}
private func opacity(_ l: LayerRequest) -> Double { l.groups.reduce(l.transform.opacity) { $0 * $1.transform.opacity } }
private func close(_ a: Vec2, _ b: Vec2) -> Bool { abs(a.x - b.x) < 1e-6 && abs(a.y - b.y) < 1e-6 }

@Suite struct GroupingTests {
    /// V1: a (0...3) dissolve b (3...6), V2: c (1...4) linked to audio d, V3: e outside the group.
    private func fixture() throws -> (Project, Timeline, [Clip]) {
        let link = UUID()
        var a = clip(0, 3, src: 10), b = clip(3, 3, src: 20)
        a.animation.scale = AnimatedProperty(Vec2(1.2, 1.2))
        b.animation.position = AnimatedProperty(.zero, track: KeyframeTrack(keys: [
            Keyframe(time: s(0), value: Vec2(-100, 0)), Keyframe(time: s(2), value: Vec2(100, 40), inTangent: Vec2(5, 5))]))
        var c = clip(1, 3, link: link)
        c.animation.rotation = AnimatedProperty(15)
        let d = clip(1, 3, kind: .audio, link: link)
        let e = clip(10, 2)
        var v1 = try track([a, b])
        v1.transitions = [Transition(kind: .crossDissolve, duration: f(10), outgoing: a.id, incoming: b.id)]
        let outer = tl("Main", [v1, try track([c]), try track([e]), try track([d], kind: .audio)])
        let p = Project(name: "P", media: [picRef], timelines: [outer])
        return (p, outer, [a, b, c, d, e])
    }

    /// Changes the clip on outer track `track` that plays `seq`.
    private func editGroup(_ p: inout Project, _ outer: Timeline.ID, track: Int, _ seq: Timeline.ID,
                           _ body: (inout Clip) -> Void) throws -> Clip {
        var o = try #require(p.timeline(outer))
        var g = try #require(o.tracks[track].clips.first { $0.sequence == seq })
        body(&g)
        o.tracks[track].replace(g)
        try p.edit(outer) { $0 = o }
        return g
    }

    /// Changes a group's inner sequence.
    private func editInner(_ p: inout Project, _ seq: Timeline.ID, _ body: (inout Timeline) throws -> Void) throws {
        let i = try #require(p.timelines.firstIndex { $0.id == seq })
        try body(&p.timelines[i])
    }

    @Test func groupThenUngroupRestoresTheTimelineExactly() throws {
        var (p, outer, cl) = try fixture()
        let bins = p.rootBin
        let seq = try p.group(clips: [cl[0].id, cl[1].id, cl[2].id], in: outer.id)

        let inner = try #require(p.timeline(seq))
        #expect(inner.isGroup)
        #expect(inner.name == "Group 01")
        #expect(inner.tracks.map { inner.group?.sourceTracks[$0.id] }
                == [outer.tracks[0].id, outer.tracks[1].id, outer.tracks[3].id])
        #expect(inner.tracks[0].transitions.count == 1)
        // Groups are not filed in the Project panel.
        #expect(p.rootBin.parent(of: .sequence(seq)) == nil)
        let o = try #require(p.timeline(outer.id))
        let gv = try #require(o.tracks[0].clips.first { $0.sequence == seq })
        #expect(gv.timeline == TimeRange(start: s(0), end: s(6)))
        #expect(o.tracks[0].transitions.isEmpty)
        #expect(o.tracks[3].clips.first?.sequence == seq)

        let restored = try p.ungroup(clip: gv.id, in: outer.id)
        #expect(Set(restored) == Set(cl[0...3].map(\.id)))
        #expect(p.timeline(outer.id) == outer)
        #expect(p.timeline(seq) == nil)
        #expect(p.timelines.count == 1)
        #expect(p.rootBin == bins)
    }

    @Test func ungroupFromTheAudioPartnerWorksToo() throws {
        var (p, outer, cl) = try fixture()
        let seq = try p.group(clips: [cl[2].id], in: outer.id)
        let ga = try #require(p.timeline(outer.id)?.tracks[3].clips.first { $0.sequence == seq })
        try p.ungroup(clip: ga.id, in: outer.id)
        #expect(p.timeline(outer.id) == outer)
    }

    @Test func groupTransformSurvivesUngroup() throws {
        var (p, outer, cl) = try fixture()
        let seq = try p.group(clips: [cl[0].id, cl[1].id, cl[2].id], in: outer.id)
        var o = try #require(p.timeline(outer.id))
        var g = try #require(o.tracks[0].clips.first { $0.sequence == seq })
        g.animation.position = AnimatedProperty(.zero, track: KeyframeTrack(keys: [
            Keyframe(time: s(0), value: Vec2(0, 0)), Keyframe(time: s(5), value: Vec2(300, -80), outHandle: .linear)]))
        g.animation.scale = AnimatedProperty(Vec2(0.8, 0.8))
        g.animation.rotation = AnimatedProperty(0, track: KeyframeTrack(keys: [
            Keyframe(time: s(1), value: 0), Keyframe(time: s(4), value: 30)]))
        g.animation.anchor = AnimatedProperty(Vec2(40, 20))
        o.tracks[0].replace(g)
        try p.edit(outer.id) { $0 = o }

        let times: [Time] = [s(0), Time(1, 2), s(1), Time(7, 3), s(3), Time(41, 10), Time(59, 10)]
        let probe = [Vec2(0, 0), Vec2(200, -50), Vec2(-640, 360)]
        let before = times.map { p.videoLayers(at: $0, in: outer.id) }
        try p.ungroup(clip: g.id, in: outer.id)
        let after = times.map { p.videoLayers(at: $0, in: outer.id) }

        for (b, a) in zip(before, after) {
            #expect(b.map(\.clip) == a.map(\.clip))
            for (lb, la) in zip(b, a) {
                #expect(la.groups.isEmpty)
                for q in probe { #expect(close(place(lb, q), place(la, q))) }
                #expect(abs(opacity(lb) - opacity(la)) < 1e-9)
            }
        }
        // The children keep their own Motion; the group's sits in one Group Transform effect each.
        let back = try #require(p.timeline(outer.id))
        let a = try #require(back.tracks[0].clips.first { $0.id == cl[0].id })
        #expect(a.animation == cl[0].animation)
        #expect(a.effects.map(\.kind) == [ClipEffect.groupTransformKind])
        // Audio children get no picture effect.
        #expect(back.tracks[3].clips.first?.effects.isEmpty == true)
    }

    @Test func groupShadowAppliesToTheWholeGroup() throws {
        var (p, outer, cl) = try fixture()
        let seq = try p.group(clips: [cl[0].id, cl[1].id, cl[2].id], in: outer.id)
        var o = try #require(p.timeline(outer.id))
        var g = try #require(o.tracks[0].clips.first { $0.sequence == seq })
        g.effects = [try #require(ClipEffect.make(kind: ClipEffect.dropShadowKind))]
        o.tracks[0].replace(g)
        try p.edit(outer.id) { $0 = o }
        let layers = p.videoLayers(at: s(2), in: outer.id)
        #expect(layers.count == 2)
        #expect(layers.allSatisfy { $0.groups.first?.effects == g.effects(at: s(2)) && $0.effects == cl[0].effects(at: s(2)) })
    }

    /// The group's own Sequence Volume has no place after Ungroup: refused, nothing changes; at 0 dB it ungroups.
    @Test func ungroupRefusesAGroupWithItsOwnSequenceVolume() throws {
        var (p, outer, cl) = try fixture()
        let seq = try p.group(clips: [cl[0].id], in: outer.id)
        let g = try #require(p.timeline(outer.id)?.tracks[0].clips.first { $0.sequence == seq })
        try p.edit(seq) { $0.masterVolumeDB = -6 }
        let snapshot = p
        #expect(throws: EditError.ungroupLosesLook) { try p.ungroup(clip: g.id, in: outer.id) }
        #expect(p == snapshot)
        try p.edit(seq) { $0.masterVolumeDB = 0 }
        _ = try p.ungroup(clip: g.id, in: outer.id)
    }

    @Test func ungroupRefusesWhatItCannotKeep() throws {
        var (p, outer, cl) = try fixture()
        let seq = try p.group(clips: [cl[0].id], in: outer.id)
        var o = try #require(p.timeline(outer.id))
        var g = try #require(o.tracks[0].clips.first { $0.sequence == seq })
        g.effects = [try #require(ClipEffect.make(kind: ClipEffect.dropShadowKind))]
        o.tracks[0].replace(g)
        try p.edit(outer.id) { $0 = o }
        let snapshot = p
        #expect(throws: EditError.ungroupLosesLook) { try p.ungroup(clip: g.id, in: outer.id) }
        #expect(p == snapshot)

        g.effects = []; g.speed = ClipSpeed(num: 2, den: 1)
        o.tracks[0].replace(g)
        try p.edit(outer.id) { $0 = o }
        #expect(throws: EditError.ungroupLosesLook) { try p.ungroup(clip: g.id, in: outer.id) }
        // Only groups ungroup: a plain nest does not.
        var (q, outer2, cl2) = try fixture()
        let nestID = try q.nest(clips: [cl2[4].id], in: outer2.id)
        let n = try #require(q.timeline(outer2.id)?.tracks[2].clips.first { $0.sequence == nestID })
        #expect(throws: EditError.notAGroup) { try q.ungroup(clip: n.id, in: outer2.id) }
    }

    @Test func ungroupOfATrimmedGroupTrimsTheChildren() throws {
        var (p, outer, cl) = try fixture()
        let seq = try p.group(clips: [cl[0].id, cl[1].id], in: outer.id)
        var o = try #require(p.timeline(outer.id))
        var g = try #require(o.tracks[0].clips.first { $0.sequence == seq })
        // Group 0...6 trimmed to inner 1...4, moved to 20.
        g.source = TimeRange(start: s(1), end: s(4)); g.start = s(20)
        o.tracks[0].remove(g.id); try o.tracks[0].overwrite(g)
        try p.edit(outer.id) { $0 = o }
        try p.ungroup(clip: g.id, in: outer.id)
        let v1 = try #require(p.timeline(outer.id)?.tracks[0].clips)
        #expect(v1.map(\.timeline) == [TimeRange(start: s(20), end: s(22)), TimeRange(start: s(22), end: s(23))])
        #expect(v1.map(\.source.start) == [s(11), s(20)])
        #expect(v1[0].id == cl[0].id)
    }

    @Test func ungroupFallsBackWhenTheSourceTrackIsGone() throws {
        var (p, outer, cl) = try fixture()
        let seq = try p.group(clips: [cl[2].id], in: outer.id)   // from V2 (+ A1)
        var o = try #require(p.timeline(outer.id))
        let gv = try #require(o.tracks[1].clips.first { $0.sequence == seq })
        // Move the group to V3 at 20 and delete V2.
        o.tracks[1].remove(gv.id)
        var moved = gv; moved.start = s(20)
        try o.tracks[2].overwrite(moved)
        o.tracks.remove(at: 1)
        var ga = try #require(o.tracks[2].clips.first { $0.sequence == seq })
        o.tracks[2].remove(ga.id); ga.start = s(20); try o.tracks[2].overwrite(ga)
        try p.edit(outer.id) { $0 = o }
        try p.ungroup(clip: gv.id, in: outer.id)
        let back = try #require(p.timeline(outer.id))
        #expect(back.tracks[1].clips.contains { $0.id == cl[2].id && $0.start == s(20) })
        #expect(back.tracks[2].clips.contains { $0.id == cl[3].id && $0.start == s(20) })
    }

    @Test func ungroupRefusesACollision() throws {
        var (p, outer, cl) = try fixture()
        // c (V2) and e (V3) group onto V2; then something lands on V3 where e would return.
        let seq = try p.group(clips: [cl[2].id, cl[4].id], in: outer.id)
        var o = try #require(p.timeline(outer.id))
        let gv = try #require(o.tracks[1].clips.first { $0.sequence == seq })
        #expect(o.tracks[2].clips.isEmpty)
        try o.tracks[2].overwrite(clip(10, 1))
        try p.edit(outer.id) { $0 = o }
        let snapshot = p
        #expect(throws: EditError.collision) { try p.ungroup(clip: gv.id, in: outer.id) }
        #expect(p == snapshot)
    }

    @Test func aCopiedGroupKeepsItsSequenceAfterTheOtherIsUngrouped() throws {
        var (p, outer, cl) = try fixture()
        let seq = try p.group(clips: [cl[4].id], in: outer.id)
        var o = try #require(p.timeline(outer.id))
        let g = try #require(o.tracks[2].clips.first { $0.sequence == seq })
        var copy = g; copy.id = UUID(); copy.start = s(30)
        try o.tracks[2].overwrite(copy)
        try p.edit(outer.id) { $0 = o }
        try p.ungroup(clip: g.id, in: outer.id)
        #expect(p.timeline(seq) != nil)
        try p.ungroup(clip: copy.id, in: outer.id)
        #expect(p.timeline(seq) == nil)
        let v3 = try #require(p.timeline(outer.id)?.tracks[2].clips)
        #expect(v3.map(\.start) == [s(10), s(30)])
        // The second copy got fresh ids (the first already owns the originals).
        #expect(v3[0].id == cl[4].id && v3[1].id != cl[4].id)
    }

    @Test func groupNamesCountUp() throws {
        var (p, outer, cl) = try fixture()
        let a = try p.group(clips: [cl[4].id], in: outer.id)
        let b = try p.group(clips: [cl[2].id], in: outer.id)
        #expect(p.timeline(a)?.name == "Group 01")
        #expect(p.timeline(b)?.name == "Group 02")
    }

    @Test func groupRoundTripsThroughTheFile() throws {
        var (p, outer, cl) = try fixture()
        let seq = try p.group(clips: [cl[0].id, cl[1].id, cl[2].id], in: outer.id)
        let back = try ProjectFile.decode(try ProjectFile.encode(p), migrations: ProjectFile.migrations)
        #expect(back.timeline(seq)?.group == p.timeline(seq)?.group)
        #expect(back.rootBin.parent(of: .sequence(seq)) == nil)
        #expect(ProjectFile.currentVersion >= 30)
    }

    @Test func groupTransformEffectIsANoOpAtIdentity() throws {
        var c = clip(0, 2)
        c.animation.position = AnimatedProperty(Vec2(10, 20))
        let plain = c.renderTransform(at: s(1), frame: Vec2(1920, 1080))
        let g = Clip(name: "g", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(2)), start: .zero)
        let e = try #require(ClipEffect.groupTransform(from: g, shift: .zero))
        #expect(e.isIdentityGroupStage)
        c.effects = [e]
        #expect(c.renderTransform(at: s(1), frame: Vec2(1920, 1080)) == plain)
    }

    // MARK: What Ungroup cannot keep exactly

    @Test func ungroupRefusesNonUniformScaleOverARotatedClip() throws {
        var (p, outer, cl) = try fixture()
        let seq = try p.group(clips: [cl[0].id, cl[1].id, cl[2].id], in: outer.id)   // c is rotated 15 degrees
        let g = try editGroup(&p, outer.id, track: 0, seq) { $0.animation.scale = AnimatedProperty(Vec2(1.2, 0.8)) }
        #expect(throws: EditError.ungroupLosesLook) { try p.ungroup(clip: g.id, in: outer.id) }
        // Without a rotated clip the same scale is exact.
        var (q, outer2, cl2) = try fixture()
        let seq2 = try q.group(clips: [cl2[4].id], in: outer2.id)
        let g2 = try editGroup(&q, outer2.id, track: 2, seq2) { $0.animation.scale = AnimatedProperty(Vec2(1.2, 0.8)) }
        try q.ungroup(clip: g2.id, in: outer2.id)
    }

    @Test func ungroupRefusesGroupOpacityOverOverlappingClips() throws {
        var (p, outer, cl) = try fixture()
        let seq = try p.group(clips: [cl[0].id, cl[1].id, cl[2].id], in: outer.id)
        let g = try editGroup(&p, outer.id, track: 0, seq) { $0.animation.opacity = AnimatedProperty(0.5) }
        #expect(throws: EditError.ungroupLosesLook) { try p.ungroup(clip: g.id, in: outer.id) }
        // One clip alone: the opacity multiplies exactly.
        var (q, outer2, cl2) = try fixture()
        let seq2 = try q.group(clips: [cl2[4].id], in: outer2.id)
        let g2 = try editGroup(&q, outer2.id, track: 2, seq2) { $0.animation.opacity = AnimatedProperty(0.5) }
        try q.ungroup(clip: g2.id, in: outer2.id)
        #expect(q.videoLayers(at: s(11), in: outer2.id).map(opacity) == [0.5])
    }

    @Test func ungroupRefusesContentTheGroupFrameCutOff() throws {
        var (p, outer, cl) = try fixture()
        // e is 640 x 360 at 400 %: wider than the 1920 x 1080 group frame, which cuts it.
        try p.edit(outer.id) { t in
            var e = t.tracks[2].clips[0]; e.animation.scale = AnimatedProperty(Vec2(4, 4)); t.tracks[2].replace(e)
        }
        let seq = try p.group(clips: [cl[4].id], in: outer.id)
        var untouched = p
        let g = try editGroup(&p, outer.id, track: 2, seq) { $0.animation.scale = AnimatedProperty(Vec2(0.5, 0.5)) }
        #expect(throws: EditError.ungroupLosesLook) { try p.ungroup(clip: g.id, in: outer.id) }
        // An untouched group cuts at the canvas edge, as the canvas does.
        try untouched.ungroup(clip: g.id, in: outer.id)
    }

    @Test func ungroupRefusesInnerBlendModesDipsAndShutter() throws {
        // A blend mode inside blended against the group's transparent picture, not the clips below.
        var (p, outer, cl) = try fixture()
        let seq = try p.group(clips: [cl[4].id], in: outer.id)
        try editInner(&p, seq) { t in var e = t.tracks[0].clips[0]; e.blendMode = .multiply; t.tracks[0].replace(e) }
        let g = try #require(p.timeline(outer.id)?.tracks[2].clips.first { $0.sequence == seq })
        #expect(throws: EditError.ungroupLosesLook) { try p.ungroup(clip: g.id, in: outer.id) }

        // A dip inside a moved group filled the group frame, not the canvas.
        var (q, outer2, cl2) = try fixture()
        let seq2 = try q.group(clips: [cl2[0].id, cl2[1].id, cl2[2].id], in: outer2.id)
        try editInner(&q, seq2) { t in t.tracks[0].transitions[0].kind = .dipToBlack }
        var still = q
        let g2 = try editGroup(&q, outer2.id, track: 0, seq2) { $0.animation.position = AnimatedProperty(Vec2(50, 0)) }
        #expect(throws: EditError.ungroupLosesLook) { try q.ungroup(clip: g2.id, in: outer2.id) }
        try still.ungroup(clip: g2.id, in: outer2.id)

        // An open shutter inside an animated group would pick up the group's motion after Ungroup.
        var (u, outer3, cl3) = try fixture()
        let seq3 = try u.group(clips: [cl3[4].id], in: outer3.id)
        try editInner(&u, seq3) { t in
            var e = t.tracks[0].clips[0]
            var fx = try #require(ClipEffect.make(kind: ClipEffect.transformKind))
            fx.parameters[ClipEffect.stageShutterAngleKey] = AnimatedProperty(180)
            e.effects = [fx]; t.tracks[0].replace(e)
        }
        let g3 = try editGroup(&u, outer3.id, track: 2, seq3) { $0.animation.rotation = AnimatedProperty(10) }
        #expect(throws: EditError.ungroupLosesLook) { try u.ungroup(clip: g3.id, in: outer3.id) }
    }

    @Test func ungroupRefusesInnerTrackStateAndSequenceItems() throws {
        let (p, outer, cl) = try fixture()
        var base = p
        let seq = try base.group(clips: [cl[4].id], in: outer.id)
        let g = try #require(base.timeline(outer.id)?.tracks[2].clips.first { $0.sequence == seq })
        var hidden = base
        try editInner(&hidden, seq) { $0.tracks[0].isVisible = false }
        #expect(throws: EditError.ungroupLosesLook) { try hidden.ungroup(clip: g.id, in: outer.id) }
        var marked = base
        try editInner(&marked, seq) { $0.markers = [Marker(time: s(1))] }
        #expect(throws: EditError.ungroupLosesLook) { try marked.ungroup(clip: g.id, in: outer.id) }
        var ranged = base
        try editInner(&ranged, seq) { $0.inOut = TimeRange(start: s(0), end: s(1)) }
        #expect(throws: EditError.ungroupLosesLook) { try ranged.ungroup(clip: g.id, in: outer.id) }
        // Grouped from a muted track: inside and outside are muted alike, so Ungroup keeps the sound.
        var (q, outer2, cl2) = try fixture()
        try q.edit(outer2.id) { $0.tracks[3].isMuted = true }
        let seq2 = try q.group(clips: [cl2[2].id], in: outer2.id)
        let g2 = try #require(q.timeline(outer2.id)?.tracks[1].clips.first { $0.sequence == seq2 })
        try q.ungroup(clip: g2.id, in: outer2.id)
        #expect(q.timeline(outer2.id)?.tracks[3].isMuted == true)
    }

    @Test func ungroupChecksLocksOnTheDestinationTracks() throws {
        var (p, outer, cl) = try fixture()
        // c (V2) and e (V3) group onto V2; then V3 is locked.
        let seq = try p.group(clips: [cl[2].id, cl[4].id], in: outer.id)
        try p.edit(outer.id) { $0.tracks[2].isLocked = true }
        let g = try #require(p.timeline(outer.id)?.tracks[1].clips.first { $0.sequence == seq })
        let snapshot = p
        #expect(throws: EditError.trackLocked) { try p.ungroup(clip: g.id, in: outer.id) }
        #expect(p == snapshot)
    }

    @Test func ungroupMapsReorderedAndAddedInnerTracksById() throws {
        var (p, outer, cl) = try fixture()
        let seq = try p.group(clips: [cl[0].id, cl[1].id, cl[2].id], in: outer.id)
        try editInner(&p, seq) { t in
            t.tracks.swapAt(0, 1)
            t.tracks.insert(Track(kind: .video), at: 0)
        }
        let g = try #require(p.timeline(outer.id)?.tracks[0].clips.first { $0.sequence == seq })
        try p.ungroup(clip: g.id, in: outer.id)
        #expect(p.timeline(outer.id) == outer)
    }

    @Test func ungroupedGroupTransformConformsWithTheFormat() throws {
        var (p, outer, cl) = try fixture()
        let seq = try p.group(clips: [cl[4].id], in: outer.id)
        let g = try editGroup(&p, outer.id, track: 2, seq) { g in
            g.animation.position = AnimatedProperty(Vec2(100, -40)); g.animation.anchor = AnimatedProperty(Vec2(30, 10))
            g.animation.rotation = AnimatedProperty(20); g.animation.scale = AnimatedProperty(Vec2(0.7, 0.7))
        }
        try p.ungroup(clip: g.id, in: outer.id)
        let t = try #require(p.timeline(outer.id))
        let big = SequenceConform.conformed(t, to: SequenceFormat(width: 3840, height: 2160, frameDuration: Time(1, 30)),
                                            mode: .fit)
        let before = try #require(t.videoLayers(at: s(11)).first), after = try #require(big.videoLayers(at: s(11)).first)
        for q in [Vec2(0, 0), Vec2(320, 180), Vec2(-100, 50)] {
            let a = place(before, q), b = place(after, q)
            #expect(close(Vec2(a.x * 2, a.y * 2), b))
        }
    }

    @Test func savingDropsGroupsNothingPlays() throws {
        var (p, outer, cl) = try fixture()
        let seq = try p.group(clips: [cl[4].id], in: outer.id)
        try p.edit(outer.id) { t in for c in t.tracks[2].clips { t.tracks[2].remove(c.id) } }
        let back = try ProjectFile.decode(try ProjectFile.encode(p), migrations: ProjectFile.migrations)
        #expect(back.timeline(seq) == nil)
        #expect(back.timelines.map(\.id) == [outer.id])
        // A group that still plays is kept.
        var (q, outer2, cl2) = try fixture()
        let kept = try q.group(clips: [cl2[4].id], in: outer2.id)
        let back2 = try ProjectFile.decode(try ProjectFile.encode(q), migrations: ProjectFile.migrations)
        #expect(back2.timeline(kept) != nil)
    }

    @Test func ungroupingOneUnlinkedSideClearsDanglingLinks() throws {
        var (p, outer, cl) = try fixture()
        let seq = try p.group(clips: [cl[2].id], in: outer.id)
        try p.edit(outer.id) { t in
            for i in t.tracks.indices {
                for var c in t.tracks[i].clips where c.sequence == seq { c.link = nil; t.tracks[i].replace(c) }
            }
        }
        let gv = try #require(p.timeline(outer.id)?.tracks[1].clips.first { $0.sequence == seq })
        try p.ungroup(clip: gv.id, in: outer.id)
        let back = try #require(p.timeline(outer.id))
        #expect(back.tracks[1].clips.first { $0.id == cl[2].id }?.link == nil)
        #expect(back.tracks[3].clips.first?.sequence == seq)   // the audio side is still a group
        #expect(p.timeline(seq) != nil)
    }

    @Test func ungroupRefusesAShadowThatTheGroupFrameCutOff() throws {
        var (p, outer, cl) = try fixture()
        // e is 640 x 360 at x = 640: its right edge sits exactly on the 1920 x 1080 group frame edge.
        var shadow = try #require(ClipEffect.make(kind: ClipEffect.dropShadowKind))
        shadow.parameters[ClipEffect.shadowDistanceKey] = AnimatedProperty(20)
        try p.edit(outer.id) { t in
            var e = t.tracks[2].clips[0]
            e.animation.position = AnimatedProperty(Vec2(640, 0))
            e.effects = [shadow]
            t.tracks[2].replace(e)
        }
        let seq = try p.group(clips: [cl[4].id], in: outer.id)
        var untouched = p
        let g = try editGroup(&p, outer.id, track: 2, seq) { $0.animation.scale = AnimatedProperty(Vec2(0.5, 0.5)) }
        #expect(throws: EditError.ungroupLosesLook) { try p.ungroup(clip: g.id, in: outer.id) }
        // Untouched group (identity stage): the canvas cuts the shadow the same way.
        try untouched.ungroup(clip: g.id, in: outer.id)
    }

    @Test func aShadowInsideTheGroupFrameDoesNotBlockUngroup() throws {
        var (p, outer, cl) = try fixture()
        let shadow = try #require(ClipEffect.make(kind: ClipEffect.dropShadowKind))
        try p.edit(outer.id) { t in
            var e = t.tracks[2].clips[0]
            e.effects = [shadow]
            t.tracks[2].replace(e)
        }
        let seq = try p.group(clips: [cl[4].id], in: outer.id)
        let g = try editGroup(&p, outer.id, track: 2, seq) { $0.animation.scale = AnimatedProperty(Vec2(0.5, 0.5)) }
        try p.ungroup(clip: g.id, in: outer.id)
    }

    @Test func groupsAreNotSequencesToPick() throws {
        var (p, outer, cl) = try fixture()
        let seq = try p.group(clips: [cl[4].id], in: outer.id)
        #expect(p.timelines.count == 2)
        #expect(p.pickableTimelines.map(\.id) == [outer.id])
        #expect(!p.pickableTimelines.contains { $0.id == seq })
    }

    @Test func groupStageTransformsAreExposedAndInvertible() throws {
        var c = clip(0, 3)
        var e = ClipEffect(kind: ClipEffect.groupTransformKind)
        e.points[ClipEffect.groupPositionKey] = AnimatedProperty(Vec2(100, 20))
        e.points[ClipEffect.groupScaleKey] = AnimatedProperty(Vec2(0.5, 0.5))
        e.parameters[ClipEffect.groupRotationKey] = AnimatedProperty(30)
        e.parameters[ClipEffect.groupOpacityKey] = AnimatedProperty(0.5)
        c.effects = [e]
        c.animation.position = AnimatedProperty(Vec2(40, -10))
        c.animation.scale = AnimatedProperty(Vec2(1.5, 1.5))
        let stages = c.groupStageTransforms(at: s(1))
        #expect(stages.count == 1)
        let base = c.transform(at: s(1))
        let shown = stages.reduce(base) { $1.composed(after: $0) }
        #expect(shown == c.renderTransform(at: s(1), frame: Vec2(1920, 1080)))
        let back = shown.removingGroupStages(stages)
        #expect(close(back.position, base.position) && close(back.scale, base.scale))
        #expect(abs(back.rotation - base.rotation) < 1e-9 && abs(back.opacity - base.opacity) < 1e-9)
    }

    // MARK: Unnest

    @Test func unnestReplacesANestByItsContentAndKeepsTheSequence() throws {
        var (p, outer, cl) = try fixture()
        let seq = try p.nest(clips: [cl[4].id], in: outer.id)
        let n = try #require(p.timeline(outer.id)?.tracks[2].clips.first { $0.sequence == seq })
        let back = try p.unnest(clip: n.id, in: outer.id)
        #expect(back.count == 1)
        let o = try #require(p.timeline(outer.id))
        #expect(o.tracks.flatMap(\.clips).contains { $0.sequence == seq } == false)
        let c = try #require(o.tracks.flatMap(\.clips).first { $0.id == back[0] })
        #expect(c.start == cl[4].start && c.duration == cl[4].duration && c.media == pic)
        #expect(p.timeline(seq) != nil)
    }

    @Test func unnestRefusesAGroupAndUngroupStillRefusesANest() throws {
        var (p, outer, cl) = try fixture()
        let g = try p.group(clips: [cl[0].id], in: outer.id)
        let gc = try #require(p.timeline(outer.id)?.tracks[0].clips.first { $0.sequence == g })
        #expect(throws: EditError.notNested) { try p.unnest(clip: gc.id, in: outer.id) }
    }

    @Test func unnestOfATrimmedNestShowsOnlyWhatPlayed() throws {
        var (p, outer, cl) = try fixture()
        let seq = try p.nest(clips: [cl[0].id, cl[1].id], in: outer.id)
        var o = try #require(p.timeline(outer.id))
        var n = try #require(o.tracks[0].clips.first { $0.sequence == seq })
        n.source = TimeRange(start: s(1), end: s(4))
        o.tracks[0].replace(n)
        try p.edit(outer.id) { $0 = o }
        _ = try p.unnest(clip: n.id, in: outer.id)
        let clips = try #require(p.timeline(outer.id)).tracks[0].clips
        #expect(clips.first?.start == n.start)
        #expect((clips.last?.timeline.end ?? .zero) <= n.timeline.end)
    }

    // MARK: Unnest / Ungroup content that leaves its sequence

    @Test func unnestMapsPictureMasksToTheOuterTracksAndDropsUnplacedOnes() throws {
        var (p, outer, cl) = try fixture()
        let seq = try p.nest(clips: [cl[2].id, cl[4].id], in: outer.id)
        var innerIDs: [Track.ID] = []
        try editInner(&p, seq) { t in
            innerIDs = t.tracks.map(\.id)
            let extra = Track(kind: .video)
            t.tracks.append(extra)
            innerIDs.append(extra.id)
            var e = t.tracks[1].clips[0]
            e.masks = [ClipMask.makePicture(track: innerIDs[0]), ClipMask.makePicture(track: extra.id)]
            t.tracks[1].replace(e)
        }
        let n = try #require(p.timeline(outer.id)?.tracks.flatMap(\.clips).first { $0.sequence == seq && $0.kind == .video })
        let back = try p.unnest(clip: n.id, in: outer.id)
        let o = try #require(p.timeline(outer.id))
        let withMask = try #require(o.tracks.flatMap(\.clips).first { back.contains($0.id) && !$0.masks.isEmpty })
        let matte = try #require(o.tracks.first { t in t.clips.contains { back.contains($0.id) && $0.masks.isEmpty && $0.kind == .video } })
        #expect(withMask.masks[0].pictureTrack == matte.id)
        #expect(!innerIDs.contains(withMask.masks[0].pictureTrack ?? UUID()))
        #expect(withMask.masks[1].pictureTrack == nil)
    }

    private func adjustmentFixture(belowAt: Int64) throws -> (Project, Timeline.ID, Clip.ID) {
        let x = clip(belowAt, 3), c = clip(1, 3)
        let outer = tl("Main", [try track([x]), try track([c]), Track(kind: .video)])
        var p = Project(name: "P", media: [picRef], timelines: [outer])
        let adj = try p.addAdjustmentClip(in: outer.id, at: s(1), track: outer.tracks[2].id, duration: s(2))
        _ = try p.nest(clips: [c.id, adj], in: outer.id)
        let n = try #require(p.timeline(outer.id)?.tracks.flatMap(\.clips).first { $0.sequence != nil })
        return (p, outer.id, n.id)
    }

    @Test func unnestRefusesAnAdjustmentLayerThatWouldReachOuterClipsBelow() throws {
        var (p, outer, n) = try adjustmentFixture(belowAt: 0)
        let before = p
        #expect(throws: EditError.ungroupLosesLook) { try p.unnest(clip: n, in: outer) }
        #expect(p == before)
    }

    @Test func unnestKeepsAnAdjustmentLayerWithNothingOuterBelowIt() throws {
        var (p, outer, n) = try adjustmentFixture(belowAt: 10)
        let back = try p.unnest(clip: n, in: outer)
        #expect(back.count == 2)
    }
}
