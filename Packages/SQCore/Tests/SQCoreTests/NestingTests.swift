import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func clip(_ start: Int64, _ dur: Int64, src: Int64 = 0, kind: TrackKind = .video,
                  link: UUID? = nil, media: UUID = UUID()) -> Clip {
    Clip(name: "c", media: media, kind: kind, source: TimeRange(start: s(src), duration: s(dur)), start: s(start), link: link)
}
private func track(_ clips: [Clip], kind: TrackKind = .video) throws -> Track {
    var t = Track(kind: kind)
    for c in clips { try t.overwrite(c) }
    return t
}
private func tl(_ name: String, _ tracks: Track...) -> Timeline { Timeline(name: name, frameDuration: Time(1, 30), tracks: tracks) }

@Suite struct NestingTests {
    // MARK: Nest

    @Test func nestReplacesClipsWithOneNestedClip() throws {
        let link = UUID()
        let v1 = clip(2, 3, src: 10, link: link), a1 = clip(2, 3, src: 10, kind: .audio, link: link)
        let v2 = clip(5, 2)
        let untouched = clip(20, 2)
        let outer = tl("Main", try track([v1, v2, untouched]), try track([a1], kind: .audio))
        var p = Project(name: "P", timelines: [outer])
        let id = try p.nest(clips: [v1.id, v2.id], in: outer.id)

        let seq = try #require(p.timeline(id))
        #expect(seq.name == "Nested Sequence 01")
        #expect(seq.format == outer.format)
        // Inner: clips shifted to 0, linked audio came along, track kinds and order kept.
        #expect(seq.tracks.map(\.kind) == [.video, .audio])
        #expect(seq.tracks[0].clips.map(\.start) == [s(0), s(3)])
        #expect(seq.tracks[0].clips[0].source == v1.source)
        #expect(seq.tracks[1].clips.map(\.start) == [s(0)])
        #expect(seq.tracks[1].clips[0].link == link)
        // Outer: nested video + linked nested audio over 2...7, untouched clip stays.
        let o = try #require(p.timeline(outer.id))
        let nv = o.tracks[0].clips.first { $0.sequence == id }!
        let na = o.tracks[1].clips.first { $0.sequence == id }!
        #expect(nv.timeline == TimeRange(start: s(2), end: s(7)))
        #expect(na.timeline == nv.timeline)
        #expect(nv.link != nil && nv.link == na.link)
        #expect(nv.source == TimeRange(start: s(0), duration: s(5)))
        #expect(nv.clipSource == .sequence(id))
        #expect(nv.media == id)
        #expect(o.tracks[0].clips.contains { $0.id == untouched.id })
        #expect(o.tracks[0].clips.count == 2)
        // Filed next to the outer sequence.
        #expect(p.rootBin.parent(of: .sequence(id)) == p.rootBin.parent(of: .sequence(outer.id)))
    }

    @Test func nestGoesOnLowestTrack() throws {
        let a = clip(0, 2), b = clip(0, 2)
        let outer = tl("Main", try track([]), try track([a]), try track([b]))
        var p = Project(name: "P", timelines: [outer])
        let id = try p.nest(clips: [a.id, b.id], in: outer.id)
        let o = p.timeline(outer.id)!
        #expect(o.tracks[1].clips.first?.sequence == id)
        #expect(o.tracks[2].clips.isEmpty)
        #expect(p.timeline(id)!.tracks.count == 2)
    }

    @Test func nestNameIsUniqueAndBinIsKept() throws {
        let a = clip(0, 2), b = clip(3, 2)
        let outer = tl("Main", try track([a, b]))
        var p = Project(name: "P", timelines: [outer])
        let newBin = p.newBin(name: "Seqs")
        let bin = try #require(newBin)
        let moved = p.move([.sequence(outer.id)], to: bin)
        #expect(moved)
        let first = try p.nest(clips: [a.id], in: outer.id)
        let second = try p.nest(clips: [b.id], in: outer.id)
        #expect(p.timeline(first)?.name == "Nested Sequence 01")
        #expect(p.timeline(second)?.name == "Nested Sequence 02")
        #expect(p.rootBin.parent(of: .sequence(second)) == bin)
    }

    @Test func nestErrors() throws {
        let a = clip(0, 2), blocker = clip(3, 1), b = clip(6, 2)
        var locked = try track([clip(0, 1)]); locked.isLocked = true
        let outer = tl("Main", try track([a, blocker, b]), locked)
        var p = Project(name: "P", timelines: [outer])
        #expect(throws: EditError.timelineNotFound) { try p.nest(clips: [a.id], in: UUID()) }
        #expect(throws: EditError.emptyClip) { try p.nest(clips: [], in: outer.id) }
        #expect(throws: EditError.clipNotFound) { try p.nest(clips: [UUID()], in: outer.id) }
        #expect(throws: EditError.trackLocked) { try p.nest(clips: [outer.tracks[1].clips[0].id], in: outer.id) }
        // `blocker` sits between a and b on the target track.
        #expect(throws: EditError.collision) { try p.nest(clips: [a.id, b.id], in: outer.id) }
        #expect(p.timelines.count == 1)        // failed nest changed nothing
        #expect(p.timeline(outer.id) == outer)
    }

    // MARK: Cycles

    @Test func cycleDetection() throws {
        let a = tl("A", try track([clip(0, 4)]))
        let b = tl("B", try track([clip(0, 4)]))
        var p = Project(name: "P", timelines: [a, b])
        // A contains B: fine.
        let inB = try #require(p.sequenceClips(of: b.id, at: s(0))).first!
        // B is empty-duration? give it duration 4 via its clip.
        try p.edit(a.id) { try $0.tracks[0].overwrite(inB) }
        #expect(p.nestedSequences(of: a.id) == [b.id])
        // B containing A would close the loop.
        let inA = try #require(p.sequenceClips(of: a.id, at: s(0))).first!
        #expect(p.wouldCreateCycle(nesting: a.id, in: b.id))
        let before = p
        #expect(throws: EditError.nestingCycle) { try p.edit(b.id) { try $0.tracks[0].overwrite(inA) } }
        #expect(p == before)
        // Directly into itself.
        let self1 = Clip(name: "s", media: a.id, kind: .video, source: TimeRange(start: s(0), duration: s(1)),
                         start: s(10), sequence: a.id)
        #expect(throws: EditError.nestingCycle) { try p.edit(a.id) { try $0.tracks[0].overwrite(self1) } }
        #expect(p.isNestingAcyclic)
    }

    @Test func threeLevelCycle() throws {
        var p = Project(name: "P", timelines: [tl("A", try track([clip(0, 4)])), tl("B", try track([clip(0, 4)])),
                                               tl("C", try track([clip(0, 4)]))])
        let (a, b, c) = (p.timelines[0].id, p.timelines[1].id, p.timelines[2].id)
        try p.edit(a) { try $0.tracks[0].overwrite(Clip(name: "", media: b, kind: .video, source: TimeRange(start: .zero, duration: s(2)), start: s(10), sequence: b)) }
        try p.edit(b) { try $0.tracks[0].overwrite(Clip(name: "", media: c, kind: .video, source: TimeRange(start: .zero, duration: s(2)), start: s(10), sequence: c)) }
        #expect(p.reachableSequences(from: a) == [b, c])
        #expect(p.wouldCreateCycle(nesting: a, in: c))
        #expect(!p.wouldCreateCycle(nesting: c, in: a))
        #expect(throws: EditError.nestingCycle) {
            try p.edit(c) { try $0.tracks[0].overwrite(Clip(name: "", media: a, kind: .video, source: TimeRange(start: .zero, duration: s(2)), start: s(10), sequence: a)) }
        }
    }

    @Test func unknownTimelineEdit() {
        var p = Project(name: "P")
        #expect(throws: EditError.timelineNotFound) { try p.edit(UUID()) { _ in } }
    }

    // MARK: Evaluation

    /// Inner: video at 0...10 (source 100...), audio 0...10. Outer: nested clip at 20...25 playing inner 3...8.
    private func fixture() throws -> (Project, outer: Timeline.ID, inner: Timeline.ID, vMedia: UUID, aMedia: UUID) {
        let vm = UUID(), am = UUID()
        let inner = tl("Inner", try track([clip(0, 10, src: 100, media: vm)]),
                       try track([clip(0, 10, src: 50, kind: .audio, media: am)], kind: .audio))
        var outerV = Track(kind: .video), outerA = Track(kind: .audio)
        let link = UUID()
        let nv = Clip(name: "n", media: inner.id, kind: .video, source: TimeRange(start: s(3), duration: s(5)),
                      start: s(20), link: link, mediaDuration: s(10), sequence: inner.id)
        let na = Clip(name: "n", media: inner.id, kind: .audio, source: TimeRange(start: s(3), duration: s(5)),
                      start: s(20), link: link, mediaDuration: s(10), sequence: inner.id)
        try outerV.overwrite(nv); try outerA.overwrite(na)
        let outer = tl("Outer", outerV, outerA)
        return (Project(name: "P", timelines: [outer, inner]), outer.id, inner.id, vm, am)
    }

    @Test func videoLayersResolveNestedWithTimeMapping() throws {
        let f = try fixture()
        let l = f.0.videoLayers(at: s(22), in: f.outer)
        #expect(l.count == 1)
        #expect(l[0].media == f.vMedia)
        #expect(l[0].sourceTime == s(105))            // outer 22 -> inner 5 -> media 100 + 5
        #expect(l[0].groups.count == 1)
        #expect(l[0].groups[0].sequence == f.inner)
        #expect(l[0].groups[0].format == f.0.timeline(f.inner)!.format)
        #expect(f.0.videoLayers(at: s(19), in: f.outer).isEmpty)
        #expect(f.0.videoLayers(at: s(25), in: f.outer).isEmpty)     // past the nested range (inner 8 is cut)
        #expect(f.0.videoLayers(at: Time(41, 2), in: f.outer)[0].sourceTime == Time(207, 2))   // 20.5 -> inner 3.5 -> 103.5
    }

    @Test func nestedTransformAndCornerRadiusAreKeptSeparate() throws {
        var f = try fixture()
        var outer = f.0.timeline(f.outer)!
        var nv = outer.tracks[0].clips[0]
        nv.animation.scale = AnimatedProperty(Vec2(0.5, 0.5))
        nv.animation.opacity = AnimatedProperty(0.5)
        nv.roundedCorners = .roundedCorners(radius: 24)
        outer.tracks[0].replace(nv)
        var inner = f.0.timeline(f.inner)!
        var iv = inner.tracks[0].clips[0]
        iv.animation.rotation = AnimatedProperty(90.0)
        iv.roundedCorners = .roundedCorners(radius: -5)   // clamped
        inner.tracks[0].replace(iv)
        f.0.timelines = [outer, inner]
        let l = f.0.videoLayers(at: s(21), in: f.outer)[0]
        #expect(l.transform.rotation == 90)
        #expect(l.transform.scale == Vec2(1, 1))            // own transform only, not multiplied
        #expect(l.cornerRadius == 0)
        #expect(l.groups[0].transform.scale == Vec2(0.5, 0.5))
        #expect(l.groups[0].transform.opacity == 0.5)
        #expect(l.groups[0].cornerRadius == 24)
    }

    @Test func nestedKeyframesUseClipLocalTimeOfTheInnerSequence() throws {
        var f = try fixture()
        var inner = f.0.timeline(f.inner)!
        var iv = inner.tracks[0].clips[0]
        iv.animation.opacity = AnimatedProperty(1.0, track: KeyframeTrack(keys: [
            Keyframe(time: s(0), value: 0.0), Keyframe(time: s(10), value: 1.0)]))
        inner.tracks[0].replace(iv)
        f.0.timelines = [f.0.timeline(f.outer)!, inner]
        // outer 22 -> inner 5 -> half way.
        #expect(abs(f.0.videoLayers(at: s(22), in: f.outer)[0].transform.opacity - 0.5) < 1e-9)
    }

    @Test func hiddenOuterTrackAndMissingSequence() throws {
        var f = try fixture()
        var outer = f.0.timeline(f.outer)!
        outer.tracks[0].isVisible = false
        f.0.timelines[0] = outer
        #expect(f.0.videoLayers(at: s(22), in: f.outer).isEmpty)
        // Timeline-level call without resolver: nested clips contribute nothing.
        #expect(f.0.timeline(f.outer)!.videoLayers(at: s(22)).isEmpty)
        outer.tracks[0].isVisible = true
        f.0.timelines = [outer]          // inner sequence gone
        #expect(f.0.videoLayers(at: s(22), in: f.outer).isEmpty)
    }

    @Test func innerTrackVisibilityIsHonoured() throws {
        var f = try fixture()
        var inner = f.0.timeline(f.inner)!
        inner.tracks[0].isVisible = false
        f.0.timelines = [f.0.timeline(f.outer)!, inner]
        #expect(f.0.videoLayers(at: s(22), in: f.outer).isEmpty)
    }

    @Test func audioSegmentsResolveNestedInOuterTime() throws {
        let f = try fixture()
        let segs = f.0.audioSegments(in: TimeRange(start: s(18), end: s(30)), of: f.outer)
        #expect(segs.count == 1)
        #expect(segs[0].media == f.aMedia)
        #expect(segs[0].timeline == TimeRange(start: s(20), end: s(25)))
        #expect(segs[0].sourceStart == s(53))            // inner 3 -> media 50 + 3
        #expect(segs[0].nests.count == 1)
        // Partial range.
        let part = f.0.audioSegments(in: TimeRange(start: s(22), end: s(23)), of: f.outer)
        #expect(part[0].timeline == TimeRange(start: s(22), end: s(23)))
        #expect(part[0].sourceStart == s(55))
        #expect(f.0.audioSegments(in: TimeRange(start: s(0), end: s(10)), of: f.outer).isEmpty)
    }

    @Test func nestedAudioGainAndMute() throws {
        var f = try fixture()
        var outer = f.0.timeline(f.outer)!
        var na = outer.tracks[1].clips[0]
        na.animation.volume = AnimatedProperty(0.5)
        outer.tracks[1].replace(na)
        f.0.timelines[0] = outer
        let seg = f.0.audioSegments(in: TimeRange(start: s(20), end: s(25)), of: f.outer)[0]
        #expect(seg.nestGain(at: s(22)) == 0.5)
        #expect(AudioSegment(clip: UUID(), media: UUID(), track: UUID(), timeline: seg.timeline, sourceStart: .zero).nestGain(at: s(1)) == 1)
        outer.tracks[1].isMuted = true
        f.0.timelines[0] = outer
        #expect(f.0.audioSegments(in: TimeRange(start: s(20), end: s(25)), of: f.outer).isEmpty)
    }

    @Test func doubleNestingMapsThroughBothLevels() throws {
        // C: video at 0..10 (media src 0). B: nested C at 5 (plays C 2...6). A: nested B at 100 (plays B 6...9).
        let vm = UUID()
        let c = tl("C", try track([clip(0, 10, src: 0, media: vm)]))
        let bClip = Clip(name: "", media: c.id, kind: .video, source: TimeRange(start: s(2), duration: s(4)), start: s(5), sequence: c.id)
        let b = tl("B", try track([bClip]))
        let aClip = Clip(name: "", media: b.id, kind: .video, source: TimeRange(start: s(6), duration: s(3)), start: s(100), sequence: b.id)
        let a = tl("A", try track([aClip]))
        let p = Project(name: "P", timelines: [a, b, c])
        // A 101 -> B 7 -> C 2 + (7-5) = 4 -> media 4.
        let l = p.videoLayers(at: s(101), in: a.id)
        #expect(l.count == 1)
        #expect(l[0].sourceTime == s(4))
        #expect(l[0].groups.map(\.sequence) == [b.id, c.id])
        // B range 5...9 visible; A plays B 6...9 -> A 100...103; B 9 is outside C's range (ends at 9).
        #expect(p.videoLayers(at: s(100), in: a.id).count == 1)
        #expect(p.videoLayers(at: s(103), in: a.id).isEmpty)
    }

    @Test func corruptCycleDoesNotRecurseForever() throws {
        let aID = UUID()
        let self1 = Clip(name: "", media: aID, kind: .video, source: TimeRange(start: .zero, duration: s(4)), start: .zero, sequence: aID)
        let a = Timeline(id: aID, name: "A", frameDuration: Time(1, 30), tracks: [try track([self1])])
        let p = Project(name: "P", timelines: [a])
        #expect(!p.isNestingAcyclic)
        #expect(p.videoLayers(at: s(1), in: aID).isEmpty)
        #expect(p.audioSegments(in: TimeRange(start: .zero, duration: s(4)), of: aID).isEmpty)
    }

    @Test func sequenceClipsBuildVideoAndLinkedAudio() throws {
        let f = try fixture()
        let cs = try #require(f.0.sequenceClips(of: f.inner, at: s(7)))
        #expect(cs.map(\.kind) == [.video, .audio])
        #expect(cs[0].link != nil && cs[0].link == cs[1].link)
        #expect(cs[0].source == TimeRange(start: .zero, duration: s(10)))
        #expect(cs[0].start == s(7))
        #expect(cs[0].mediaDuration == s(10))
        #expect(f.0.sequenceClips(of: UUID(), at: .zero) == nil)
    }

    // MARK: Persistence

    @Test func nestedClipSurvivesCodable() throws {
        let f = try fixture()
        let back = try ProjectFile.decode(try ProjectFile.encode(f.0), migrations: ProjectFile.migrations)
        #expect(back == f.0)
        #expect(back.timeline(f.outer)!.tracks[0].clips[0].sequence == f.inner)
    }
}
