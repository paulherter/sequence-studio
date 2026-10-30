import Foundation
import Testing
@testable import SQCore

// C6 Picture mask: another track's picture as a mask source (`MaskSource.picture`), linked by track id. Model, rules,
// editing (Delete Track, paste remap) and evaluation (matte requests tagged `matteFor`).

private let fd = Time(1, 30)
private let fmt = SequenceFormat(width: 1920, height: 1080, frameDuration: fd)

private func clip(_ start: Int, seconds: Int = 5, sourceStart: Int = 0, name: String = "c") -> Clip {
    Clip(name: name, media: UUID(), kind: .video, source: TimeRange(start: Time(Int64(sourceStart), 1), duration: Time(Int64(seconds), 1)),
         start: Time(Int64(start), 1), mediaDuration: Time(100, 1))
}

private func pictureClip(_ start: Int, track: Track.ID?, seconds: Int = 5) -> Clip {
    var c = clip(start, seconds: seconds, name: "consumer")
    c.masks = [ClipMask.makePicture(track: track)]
    return c
}

private func track(_ clips: [Clip], kind: TrackKind = .video) throws -> Track {
    var t = Track(kind: kind)
    for c in clips { try t.overwrite(c) }
    return t
}

/// V1 = consumer (mask on V2), V2 = matte clip. Returns the timeline plus the two track ids.
private func basic(matte: Clip? = nil, visible: Bool = true) throws -> (Timeline, v1: Track.ID, v2: Track.ID) {
    var v2 = try track([matte ?? clip(0, seconds: 10, name: "matte")])
    v2.isVisible = visible
    let v1 = try track([pictureClip(0, track: v2.id, seconds: 10)])
    return (Timeline(name: "S", format: fmt, tracks: [v1, v2]), v1.id, v2.id)
}

@Suite struct PictureMaskModelTests {
    @Test func makePictureIsAFullFrameMatteMask() {
        let id = UUID()
        let m = ClipMask.makePicture(track: id)
        #expect(m.source == .picture)
        #expect(m.source.usesMatte)
        #expect(m.pictureTrack == id)
        #expect(m.pictureChannel == .shape)
        #expect(m.name == "Picture")
        #expect(m.path.value == MaskPath.rectangle(Vec2(0, 0), Vec2(1, 1)))
        let s = m.shape(atLocal: .zero)
        #expect(s.source == .picture && s.pictureTrack == id && s.pictureChannel == .shape)
        #expect(s.polygon.isEmpty)
    }

    @Test func codableDefaultsKeepOldMasksByteIdentical() throws {
        let path = ClipMask.make(.rectangle, name: "Mask (1)")
        let json = String(decoding: try JSONEncoder().encode(path), as: UTF8.self)
        #expect(!json.contains("picture"))
        // Shape channel (default) is not stored; Brightness is.
        var m = ClipMask.makePicture(track: UUID())
        let plain = String(decoding: try JSONEncoder().encode(m), as: UTF8.self)
        #expect(plain.contains("\"pictureTrack\""))
        #expect(!plain.contains("pictureChannel"))
        m.pictureChannel = .brightness
        let data = try JSONEncoder().encode(m)
        #expect(String(decoding: data, as: UTF8.self).contains("\"pictureChannel\":\"brightness\""))
        #expect(try JSONDecoder().decode(ClipMask.self, from: data) == m)
        // A picture mask without a track (not picked yet) round-trips without the key.
        let none = ClipMask.makePicture(track: nil)
        let d2 = try JSONEncoder().encode(none)
        #expect(!String(decoding: d2, as: UTF8.self).contains("pictureTrack"))
        #expect(try JSONDecoder().decode(ClipMask.self, from: d2) == none)
        // A path mask never stores a channel even when set.
        var p = path
        p.pictureChannel = .brightness
        #expect(p.pictureChannel == .shape)
    }

    @Test func channelValues() {
        #expect(MatteChannel.shape.value(red: 0, green: 0, blue: 0, alpha: 0.4) == 0.4)
        #expect(abs(MatteChannel.brightness.value(red: 1, green: 1, blue: 1, alpha: 0.5) - 0.5) < 1e-12)
        #expect(abs(MatteChannel.brightness.value(red: 0, green: 1, blue: 0, alpha: 1) - 0.7152) < 1e-12)
        #expect(abs(MatteChannel.brightness.value(red: 1, green: 0, blue: 0, alpha: 1) - 0.2126) < 1e-12)
        #expect(MatteChannel.shape.title == "Shape" && MatteChannel.brightness.title == "Brightness")
    }

    @Test func coverageReadsThePictureMatteClosure() {
        let id = UUID()
        var m = ClipMask.makePicture(track: id).shape(atLocal: .zero)
        let frame = Vec2(100, 100)
        // No matte: covers nothing.
        #expect(MaskCoverage.coverage(at: Vec2(50, 50), masks: [m], frame: frame, pixel: 1) == 0)
        let half: (MaskShape, Vec2) -> Double? = { s, p in s.pictureTrack == id ? (p.x < 50 ? 1 : 0.25) : nil }
        #expect(MaskCoverage.coverage(at: Vec2(10, 50), masks: [m], frame: frame, pixel: 1, picture: half) == 1)
        #expect(MaskCoverage.coverage(at: Vec2(90, 50), masks: [m], frame: frame, pixel: 1, picture: half) == 0.25)
        m.inverted = true
        #expect(MaskCoverage.coverage(at: Vec2(90, 50), masks: [m], frame: frame, pixel: 1, picture: half) == 0.75)
        m.inverted = false; m.mode = .subtract
        #expect(MaskCoverage.coverage(at: Vec2(10, 50), masks: [m], frame: frame, pixel: 1, picture: half) == 0)
    }
}

@Suite struct PictureMaskRuleTests {
    @Test func candidatesAreOtherVideoTracksOfTheSameTimeline() throws {
        let a = try track([clip(0)]), b = try track([]), c = try track([])
        let au = try track([], kind: .audio)
        let tl = Timeline(name: "S", format: fmt, tracks: [a, b, c, au])
        #expect(tl.pictureMaskTracks(forClipOn: a.id).map(\.id) == [b.id, c.id])
        #expect(tl.acceptsPictureTrack(b.id, forClipOn: a.id))
        #expect(!tl.acceptsPictureTrack(a.id, forClipOn: a.id))        // own track
        #expect(!tl.acceptsPictureTrack(au.id, forClipOn: a.id))       // audio
        #expect(!tl.acceptsPictureTrack(UUID(), forClipOn: a.id))      // another timeline / missing
    }

    @Test func deleteTrackClearsEveryLinkToIt() throws {
        var (tl, v1, v2) = try basic()
        // A graphics clip on V3 also points at V2.
        var g = clip(0, name: "graphic")
        g.graphics = GraphicsDocument(layers: [GraphicsLayer(name: "L", content: .shape(kind: .rectangle))])
        g.masks = [ClipMask.makePicture(track: v2), ClipMask.make(.ellipse, name: "e")]
        tl.tracks.append(try track([g]))
        try tl.removeTrack(v2)
        #expect(tl.track(v2) == nil)
        let all = tl.tracks.flatMap(\.clips).flatMap(\.masks)
        #expect(all.filter { $0.source == .picture }.count == 2)
        #expect(all.allSatisfy { $0.pictureTrack == nil })
        #expect(tl.track(v1) != nil)
    }

    @Test func removeEmptyTracksKeepsOneOfEachKindAndLocked() throws {
        var tl = Timeline(name: "S", format: fmt, tracks: [Track(kind: .video), Track(kind: .video), Track(kind: .video), Track(kind: .audio), Track(kind: .audio)])
        tl.tracks[2].isLocked = true
        let gone = tl.removeEmptyTracks()
        #expect(gone.count == 2)
        #expect(tl.tracks.count == 3)
        #expect(tl.tracks[0].kind == .video && tl.tracks[1].isLocked && tl.tracks[2].kind == .audio)
        #expect(tl.removeEmptyTracks().isEmpty)
    }

    @Test func deleteTrackRefusesALockedTrack() throws {
        var (tl, _, v2) = try basic()
        tl.tracks[1].isLocked = true
        #expect(throws: EditError.trackLocked) { try tl.removeTrack(v2) }
        #expect(tl.tracks[0].clips[0].masks[0].pictureTrack == v2)
    }

    @Test func remapKeepsAnExistingTrackElseUsesTheLaneOffsetElseNil() {
        let src = UUID()
        let target = [UUID(), UUID(), UUID()]
        let c = pictureClip(0, track: src)
        // Track exists in the target (and is not the clip's own lane): kept.
        let kept = c.masks[0].pictureTrack
        #expect(Clip.remapPictureTrack(kept, sourceLane: 0, sourceLanes: [:], targetLane: 1, targetVideoTracks: [src, UUID()]) == src)
        // Missing: by offset (source clip lane 0, matte lane 1 -> target lane 1 + 1 = 2).
        let byOffset = c.remappingPictureTracks(sourceLane: 0, sourceLanes: [src: 1], targetLane: 1, targetVideoTracks: target)
        #expect(byOffset.masks[0].pictureTrack == target[2])
        // Offset out of range: nil.
        let out = c.remappingPictureTracks(sourceLane: 0, sourceLanes: [src: 1], targetLane: 2, targetVideoTracks: target)
        #expect(out.masks[0].pictureTrack == nil)
        // Unknown lane: nil.
        #expect(c.remappingPictureTracks(sourceLane: 0, sourceLanes: [:], targetLane: 0, targetVideoTracks: target).masks[0].pictureTrack == nil)
        // The track exists but is the target clip's own track: remapped by offset instead.
        let own = c.remappingPictureTracks(sourceLane: 1, sourceLanes: [src: 0], targetLane: 1, targetVideoTracks: [UUID(), src])
        #expect(own.masks[0].pictureTrack != src)
    }

    @Test func pasteIntoAnotherSequenceRemapsByLaneOffset() throws {
        let (a, _, v2) = try basic()
        let cb = try #require(a.clipboard(copying: [a.tracks[0].clips[0].id]))
        #expect(cb.pictureLanes == [v2: 1])
        var b = Timeline(name: "B", format: fmt, tracks: [try track([]), try track([]), try track([])])
        let ids = try b.paste(cb, at: .zero, lanes: [.video: 1])
        let pasted = try #require(b.tracks.flatMap(\.clips).first { $0.id == ids[0] })
        #expect(pasted.masks[0].pictureTrack == b.tracks[2].id)
        // Same sequence: the track exists, the link is kept.
        var a2 = a
        let ids2 = try a2.paste(cb, at: Time(20, 1))
        #expect(a2.tracks.flatMap(\.clips).first { $0.id == ids2[0] }?.masks[0].pictureTrack == v2)
        // Into a sequence with one track: nil.
        var c = Timeline(name: "C", format: fmt, tracks: [try track([])])
        let ids3 = try c.paste(cb, at: .zero)
        #expect(c.tracks[0].clips.first { $0.id == ids3[0] }?.masks[0].pictureTrack == nil)
    }

    @Test func pasteAttributesRemaps() throws {
        let (a, _, v2) = try basic()
        let src = a.tracks[0].clips[0]
        // Target sequence: clip on V2 of three tracks; source matte was one lane above the source clip.
        let dst = clip(0)
        var b = Timeline(name: "B", format: fmt, tracks: [try track([]), try track([dst]), try track([])])
        _ = try b.pasteAttributes(from: src, to: [dst.id], sourceLane: 0, pictureLanes: [v2: 1])
        #expect(b.tracks[1].clips[0].masks.first?.pictureTrack == b.tracks[2].id)
        // Without lanes: nothing to remap to.
        var b2 = Timeline(name: "B", format: fmt, tracks: [try track([]), try track([dst]), try track([])])
        _ = try b2.pasteAttributes(from: src, to: [dst.id])
        #expect(b2.tracks[1].clips[0].masks.first?.source == .picture)
        #expect(b2.tracks[1].clips[0].masks.first?.pictureTrack == nil)
        // Picture masks paste onto generators and nests too (no decoded frame needed).
        var gen = clip(0)
        gen.generator = GeneratorRef.solid(rgb: [10, 20, 30])
        #expect(gen.pastingAttributes(from: src).masks.map(\.source) == [.picture])
    }
}

@Suite struct PictureMaskEvaluationTests {
    private func mattes(_ ls: [LayerRequest]) -> [LayerRequest] { ls.filter { $0.matteFor != nil } }

    @Test func matteRequestsAppearOnceTaggedAndFollowTheTrack() throws {
        let (tl, v1, v2) = try basic()
        let ls = tl.videoLayers(at: Time(1, 1))
        let m = mattes(ls)
        #expect(m.count == 1)
        #expect(m[0].matteFor == v2 && m[0].track == v2)
        // Same picture as the visible V2 layer, only tagged.
        var plain = try #require(ls.first { $0.track == v2 && $0.matteFor == nil })
        plain.matteFor = v2
        #expect(m[0] == plain)
        // The consumer's mask names the track.
        let consumer = try #require(ls.first { $0.track == v1 })
        #expect(consumer.effects.masks.first?.pictureTrack == v2)
        // Without picture masks there are no matte requests.
        var t2 = tl
        var c = t2.tracks[0].clips[0]; c.masks = []
        try t2.replaceClip(c)
        #expect(mattes(t2.videoLayers(at: Time(1, 1))).isEmpty)
    }

    @Test func eyeOffStillMakesTheMatte() throws {
        let (tl, _, v2) = try basic(visible: false)
        let ls = tl.videoLayers(at: Time(1, 1))
        #expect(!ls.contains { $0.track == v2 && $0.matteFor == nil })
        #expect(mattes(ls).map(\.matteFor) == [v2])
    }

    @Test func emptySpotMissingTrackOwnTrackGiveNoMatte() throws {
        let (tl, _, _) = try basic(matte: clip(5, seconds: 2, name: "late"))
        #expect(mattes(tl.videoLayers(at: Time(1, 1))).isEmpty)          // V2 empty at 1 s
        #expect(mattes(tl.videoLayers(at: Time(6, 1))).count == 1)
        let v1 = try track([pictureClip(0, track: UUID())])
        #expect(mattes(Timeline(name: "S", format: fmt, tracks: [v1]).videoLayers(at: Time(1, 1))).isEmpty)
        // Own track.
        var own = Track(kind: .video)
        let oc = pictureClip(0, track: own.id)
        try own.overwrite(oc)
        #expect(mattes(Timeline(name: "S", format: fmt, tracks: [own]).videoLayers(at: Time(1, 1))).isEmpty)
    }

    @Test func disabledAndAdjustmentMatteClipsCoverNothing() throws {
        var off = clip(0, seconds: 10, name: "off")
        off.isEnabled = false
        #expect(mattes(try basic(matte: off).0.videoLayers(at: Time(1, 1))).isEmpty)
        var adj = clip(0, seconds: 10, name: "adj")
        adj.generator = .adjustmentLayer
        let (tl, _, _) = try basic(matte: adj)
        #expect(mattes(tl.videoLayers(at: Time(1, 1))).isEmpty)
    }

    @Test func followsMoveTrimAndSpeedAtTheSameTime() throws {
        let (tl, _, v2) = try basic()
        let before = try #require(mattes(tl.videoLayers(at: Time(2, 1))).first)
        #expect(before.sourceTime == Time(2, 1))
        var moved = tl
        var m = moved.tracks[1].clips[0]
        moved.tracks[1].remove(m.id)
        m.start = Time(1, 1)
        try moved.tracks[1].overwrite(m)
        #expect(mattes(moved.videoLayers(at: Time(2, 1))).first?.sourceTime == Time(1, 1))
        var fast = tl
        var f = fast.tracks[1].clips[0]
        fast.tracks[1].remove(f.id)
        f.speed = ClipSpeed(percent: 200)
        f.source.duration = Time(20, 1)
        try fast.tracks[1].overwrite(f)
        let r = try #require(mattes(fast.videoLayers(at: Time(2, 1))).first)
        #expect(r.sourceTime == Time(4, 1) && r.matteFor == v2)
    }

    @Test func consumerHoldDoesNotFreezeTheMatte() throws {
        var (tl, _, _) = try basic()
        var c = tl.tracks[0].clips[0]
        c.holdFrame = Time(0, 1)
        try tl.replaceClip(c)
        #expect(mattes(tl.videoLayers(at: Time(3, 1))).first?.sourceTime == Time(3, 1))
    }

    @Test func noChainsMatteLayersReadNoPicture() throws {
        // V1 -> V2, V2 -> V3: both mattes once; V2's matte copy has its picture link dropped.
        var v3 = try track([clip(0, seconds: 10, name: "v3")])
        v3.isVisible = false
        var v2 = Track(kind: .video)
        try v2.overwrite(pictureClip(0, track: v3.id, seconds: 10))
        let v1 = try track([pictureClip(0, track: v2.id, seconds: 10)])
        let tl = Timeline(name: "S", format: fmt, tracks: [v1, v2, v3])
        let m = mattes(tl.videoLayers(at: Time(1, 1)))
        #expect(m.map(\.matteFor) == [v2.id, v3.id])
        let v2Matte = try #require(m.first { $0.matteFor == v2.id })
        #expect(v2Matte.effects.masks.allSatisfy { $0.pictureTrack == nil })
        // A cycle (V1 -> V2, V2 -> V1) ends after one matte each.
        var w2 = Track(kind: .video)
        var w1 = Track(kind: .video)
        try w2.overwrite(pictureClip(0, track: w1.id))
        try w1.overwrite(pictureClip(0, track: w2.id))
        let cyc = mattes(Timeline(name: "S", format: fmt, tracks: [w1, w2]).videoLayers(at: Time(1, 1)))
        #expect(Set(cyc.compactMap(\.matteFor)) == [w1.id, w2.id] && cyc.count == 2)
    }

    @Test func maskOnlyFeedingAnEffectStillAsksForTheMatte() throws {
        var (tl, _, v2) = try basic()
        var c = tl.tracks[0].clips[0]
        c.masks[0].usedByOpacity = false
        var e = ClipEffect(kind: ClipEffect.mosaicKind, parameters: ClipEffect.defaultParameters(for: ClipEffect.mosaicKind))
        e.maskInput = [c.masks[0].id]
        c.effects = [e]
        try tl.replaceClip(c)
        #expect(mattes(tl.videoLayers(at: Time(1, 1))).map(\.matteFor) == [v2])
        // Disabled mask: no matte.
        c.masks[0].enabled = false
        try tl.replaceClip(c)
        #expect(mattes(tl.videoLayers(at: Time(1, 1))).isEmpty)
    }

    @Test func dissolveOnTheMatteTrackGivesPairRequests() throws {
        var v2 = try track([clip(0, seconds: 4, sourceStart: 10, name: "a"), clip(4, seconds: 4, sourceStart: 10, name: "b")])
        v2.transitions = [Transition(kind: .crossDissolve, duration: Time(1, 1), outgoing: v2.clips[0].id, incoming: v2.clips[1].id)]
        let v1 = try track([pictureClip(0, track: v2.id, seconds: 10)])
        let tl = Timeline(name: "S", format: fmt, tracks: [v1, v2])
        let m = mattes(tl.videoLayers(at: Time(4, 1)))
        #expect(m.count == 2)
        // Never grouped with drawn layers into a pair, never a held transition frame (review C6 #2).
        #expect(m.allSatisfy { $0.pair == nil && !$0.inTransition && $0.matteFor == v2.id })
        // The visible copies still are a pair.
        #expect(tl.videoLayers(at: Time(4, 1)).filter { $0.track == v2.id && $0.matteFor == nil }.allSatisfy { $0.pair != nil })
    }

    @Test func nestedClipsUseInnerTimeAndInnerTracks() throws {
        // Inner: consumer on inner V1 pointing at inner V2 (matte clip starting at inner 0).
        let (inner, _, iv2) = try basic()
        // Outer: nest on V1 playing inner 2 s ... from outer 0; its own mask points at outer V2.
        var nest = Clip(name: "n", media: inner.id, kind: .video, source: TimeRange(start: Time(2, 1), duration: Time(5, 1)),
                        start: .zero)
        nest.sequence = inner.id
        var ov2 = try track([clip(0, seconds: 10, name: "outer matte")])
        ov2.isVisible = false
        nest.masks = [ClipMask.makePicture(track: ov2.id)]
        let ov1 = try track([nest])
        let outer = Timeline(name: "O", format: fmt, tracks: [ov1, ov2])
        let ls = outer.videoLayers(at: Time(1, 1), sequences: { $0 == inner.id ? inner : nil })
        let m = mattes(ls)
        #expect(m.count == 2)
        let innerMatte = try #require(m.first { $0.matteFor == iv2 })
        #expect(innerMatte.groups.count == 1 && innerMatte.sourceTime == Time(3, 1))     // inner time 3 s
        let outerMatte = try #require(m.first { $0.matteFor == ov2.id })
        #expect(outerMatte.groups.isEmpty && outerMatte.sourceTime == Time(1, 1))
    }

    @Test func occlusionNeverUsesOrDropsMatteLayers() throws {
        let (tl, _, _) = try basic()
        let ls = tl.videoLayers(at: Time(1, 1))
        let r = LayerOcclusion.evaluate(ls, canvas: fmt) { _ in LayerOcclusion.Picture(width: 1920, height: 1080) }
        for i in r.hidden { #expect(ls[i].matteFor == nil) }
        if let c = r.cover { #expect(ls[c].matteFor == nil) }
    }
}

/// Review fixes C6 #3-#6.
@Suite struct PictureMaskReviewFixTests {
    private func mattes(_ ls: [LayerRequest]) -> [LayerRequest] { ls.filter { $0.matteFor != nil } }

    /// V1 consumer (mask on V2), V2 matte, V3 transition layer 2 s ..< 4 s (cut 3 s).
    private func transitionStack() throws -> (Timeline, v2: Track.ID) {
        let (tl, _, v2) = try basic()
        var t = tl
        t.tracks.append(Track(kind: .video))
        var p = Project(name: "P", timelines: [t])
        _ = try p.addTransitionLayer(kind: .crossDissolve, in: t.id, at: Time(2, 1), track: t.tracks[2].id, duration: Time(2, 1))
        return (try #require(p.timeline(t.id)), v2)
    }

    @Test func heldTransitionSideGetsItsOwnMatteAtTheHeldTime() throws {
        let (tl, v2) = try transitionStack()
        // Before the cut: the incoming side is held at the cut (3 s); the outgoing side plays live (2.5 s).
        let before = mattes(tl.videoLayers(at: Time(5, 2)))
        #expect(before.count == 2 && before.allSatisfy { $0.matteFor == v2 })
        let held = try #require(before.first { $0.stackTransitions.first?.role == .second })
        #expect(held.sourceTime == Time(3, 1))
        let live = try #require(before.first { $0.stackTransitions.isEmpty })
        #expect(live.sourceTime == Time(5, 2))
        // From the cut: the outgoing side holds the frame before the cut.
        let after = mattes(tl.videoLayers(at: Time(7, 2)))
        #expect(after.count == 2)
        let heldOut = try #require(after.first { $0.stackTransitions.first?.role == .first })
        #expect(heldOut.sourceTime == Time(3, 1) - fd)
        #expect(after.first { $0.stackTransitions.isEmpty }?.sourceTime == Time(7, 2))
    }

    /// Re-review #1: the held side is marked, so the compositor gives it its own (possibly empty) Picture scope and never
    /// the level's live-time matte.
    @Test func theHeldSideIsMarkedHeldAndTheLiveSideIsNot() throws {
        let (tl, _) = try transitionStack()
        for (t, heldRole) in [(Time(5, 2), LayerRequest.PairRole.second), (Time(7, 2), .first)] {
            let tagged = tl.videoLayers(at: t).filter { !$0.stackTransitions.isEmpty }
            #expect(tagged.contains { $0.stackTransitions[0].role == heldRole })
            #expect(tagged.contains { $0.stackTransitions[0].role != heldRole })
            for l in tagged { #expect(l.stackTransitions[0].held == (l.stackTransitions[0].role == heldRole)) }
        }
    }

    @Test func duplicateAsFormatRemapsTheLink() throws {
        let (tl, _, _) = try basic()
        var p = Project(name: "P", timelines: [tl])
        let id = try p.duplicateSequence(tl.id, as: SequenceFormat(width: 1080, height: 1920, frameDuration: fd), mode: .fit)
        let d = try #require(p.timeline(id))
        #expect(d.tracks[0].clips[0].masks[0].pictureTrack == d.tracks[1].id)
        #expect(d.tracks[1].id != tl.tracks[1].id)
    }

    @Test func nestRemapsInsideAndClearsALinkLeftOutside() throws {
        let (tl, _, _) = try basic()
        var p = Project(name: "P", timelines: [tl])
        let both = try p.nest(clips: tl.tracks.flatMap(\.clips).map(\.id), in: tl.id)
        let inner = try #require(p.timeline(both))
        let consumer = try #require(inner.tracks.flatMap(\.clips).first { $0.name == "consumer" })
        #expect(consumer.masks[0].pictureTrack == inner.tracks[1].id)
        var p2 = Project(name: "P", timelines: [tl])
        let alone = try p2.nest(clips: [tl.tracks[0].clips[0].id], in: tl.id)
        #expect(p2.timeline(alone)?.tracks[0].clips[0].masks[0].pictureTrack == nil)
    }

    @Test func titleTemplateCaptureAndInstantiateRemap() throws {
        let (tl, _, _) = try basic()
        let p = Project(name: "P", timelines: [tl])
        let tt = try TitleTemplate.capture(clips: tl.tracks.flatMap(\.clips).map(\.id), in: tl.id, of: p, name: "T")
        #expect(tt.content.tracks[0].clips[0].masks[0].pictureTrack == tt.content.tracks[1].id)
        let (inst, _) = tt.instantiated()
        #expect(inst.tracks[0].clips[0].masks[0].pictureTrack == inst.tracks[1].id)
        #expect(inst.tracks[1].id != tt.content.tracks[1].id)
        let one = try TitleTemplate.capture(clips: [tl.tracks[0].clips[0].id], in: tl.id, of: p, name: "T")
        #expect(one.content.tracks[0].clips[0].masks[0].pictureTrack == nil)
    }

    @Test func removingABlurredFillTrackClearsLinksToIt() throws {
        var shot = clip(1, name: "shot")
        shot.source = TimeRange(start: Time(2, 1), duration: Time(5, 1))
        var v = Track(kind: .video)
        try v.overwrite(shot)
        var t = Timeline(name: "T", format: SequenceFormat(width: 1080, height: 1920, frameDuration: fd), tracks: [v, Track(kind: .video)])
        try t.applyBlurredFill(shot.id, picture: (1920, 1080), style: .fit)
        let bgTrack = t.tracks[0].id
        try t.tracks[2].overwrite(pictureClip(0, track: bgTrack))
        try t.removeBlurredFill(shot.id)
        #expect(t.track(bgTrack) == nil)
        #expect(t.tracks.flatMap(\.clips).first { $0.name == "consumer" }?.masks[0].pictureTrack == nil)
    }

    @Test func placingSequenceClipsDropsALinkToAHiddenTrack() throws {
        let (shown, _, v2) = try basic()
        let (hidden, _, h2) = try basic(visible: false)
        let p = Project(name: "P", timelines: [shown, hidden])
        #expect(p.sequenceClips(of: shown.id, hostFrameDuration: fd)?.clipboard.pictureLanes == [v2: 1])
        let sc = try #require(p.sequenceClips(of: hidden.id, hostFrameDuration: fd))
        #expect(sc.clipboard.pictureLanes[h2] == nil)
        var host = Timeline(name: "H", format: fmt, tracks: [try track([]), try track([])])
        let ids = try host.paste(sc.clipboard, at: .zero)
        #expect(host.tracks.flatMap(\.clips).first { $0.id == ids[0] }?.masks[0].pictureTrack == nil)
    }
}

@Suite struct PictureMaskAngleWalkTests {
    private func fixture(angle: Int?) throws -> (outer: Timeline, inner: Timeline) {
        var t0 = Track(kind: .video), t1 = Track(kind: .video)
        try t0.overwrite(pictureClip(0, track: nil))   // unlinked picture mask in angle 0
        var two = pictureClip(0, track: nil); two.masks.append(ClipMask.makePicture(track: nil))
        try t1.overwrite(two)                           // two unlinked picture masks in angle 1
        let inner = Timeline(name: "angles", frameDuration: fd, tracks: [t0, t1])
        var nest = clip(0, name: "n")
        nest.sequence = inner.id
        if let angle { nest.angle = AngleChoice(index: angle) }
        return (Timeline(name: "outer", frameDuration: fd, tracks: [try track([nest])]), inner)
    }

    @Test func onlyTheShownAngleIsCounted() throws {
        let a = try fixture(angle: 0)
        #expect(a.outer.unlinkedPictureMaskCount(sequences: [a.inner.id: a.inner]) == 1)
        let b = try fixture(angle: 1)
        #expect(b.outer.unlinkedPictureMaskCount(sequences: [b.inner.id: b.inner]) == 2)
    }

    @Test func nonAnglesNestedSequenceCountsEverything() throws {
        let f = try fixture(angle: nil)
        #expect(f.outer.unlinkedPictureMaskCount(sequences: [f.inner.id: f.inner]) == 3)
    }
}
