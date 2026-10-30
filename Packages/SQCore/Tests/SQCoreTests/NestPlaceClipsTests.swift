import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func clip(_ start: Int64, _ dur: Int64, kind: TrackKind = .video, link: UUID? = nil) -> Clip {
    Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: .zero, duration: s(dur)), start: s(start), link: link)
}
private func track(_ clips: [Clip], kind: TrackKind = .video) throws -> Track {
    var t = Track(kind: kind)
    for c in clips { try t.overwrite(c) }
    return t
}
private func host(_ name: String = "A") -> Timeline {
    Timeline(name: name, frameDuration: Time(1, 30), tracks: [Track(kind: .video, isTargeted: true), Track(kind: .audio, isTargeted: true)])
}

@Suite struct NestPlaceClipsTests {
    /// V1: [0,2) [2,5); A1: [0,5) linked to the first V clip; V2: [1,3).
    private func source() throws -> Timeline {
        let l = UUID()
        return Timeline(name: "B", frameDuration: Time(1, 30), tracks: [
            try track([clip(0, 2, link: l), clip(2, 3)]),
            try track([clip(0, 5, kind: .audio, link: l)], kind: .audio),
            try track([clip(1, 2)])])
    }

    @Test func clipsLandOnMatchingTracksWithFreshIDsAndLinks() throws {
        let b = try source(), a = host()
        var p = Project(name: "P", timelines: [a, b])
        let end = try p.placeSequenceClips([b.id], in: a.id, at: s(10), mode: .overwrite)
        #expect(end == s(15))
        let t = try #require(p.timeline(a.id))
        let v = t.tracks.filter { $0.kind == .video }, au = t.tracks.filter { $0.kind == .audio }
        #expect(v.count == 2 && au.count == 1)                                   // V2 was created
        #expect(v[0].clips.map(\.start) == [s(10), s(12)] && v[1].clips.map(\.start) == [s(11)])
        #expect(au[0].clips.map(\.start) == [s(10)])
        #expect(v[0].clips[0].sequence == nil && v[0].clips[0].id != b.tracks[0].clips[0].id)
        #expect(v[0].clips[0].link != nil && v[0].clips[0].link == au[0].clips[0].link)
        #expect(v[0].clips[0].link != b.tracks[0].clips[0].link)                  // a new link group
    }

    @Test func insertRipplesAndUndoIsOneEdit() throws {
        let b = try source()
        var a = host()
        try a.tracks[0].overwrite(clip(0, 4))
        var p = Project(name: "P", timelines: [a, b])
        let before = p
        try p.placeSequenceClips([b.id], in: a.id, at: s(2), mode: .insert)
        let t = try #require(p.timeline(a.id))
        // The existing clip is split at 2; its tail moves behind the 5 s of inserted clips.
        #expect(t.tracks[0].clips.map(\.start) == [.zero, s(2), s(4), s(7)])
        // Undo is the snapshot of the project before the edit: the placement did not touch it.
        #expect(before.timeline(a.id)!.tracks[0].clips.map(\.start) == [.zero] && before.timeline(a.id)!.tracks[0].clips[0].timeline.duration == s(4))
    }

    @Test func inOutCropsAndShiftsTheRange() throws {
        var b = try source()
        b.inOut = TimeRange(start: s(1), end: s(4))
        let a = host()
        var p = Project(name: "P", timelines: [a, b])
        let end = try p.placeSequenceClips([b.id], in: a.id, at: .zero, mode: .overwrite)
        #expect(end == s(3))
        let t = try #require(p.timeline(a.id))
        #expect(t.tracks[0].clips.map(\.start) == [.zero, s(1)])
        #expect(t.tracks[0].clips.map(\.timeline.duration) == [s(1), s(2)])       // [0,2) cut to [1,2), [2,5) to [2,4)
        #expect(t.tracks[0].clips[0].source.start == s(1))
        #expect(t.tracks.last { $0.kind == .video }!.clips.map(\.start) == [.zero])   // V2 [1,3) -> [0,2)
    }

    @Test func twoSequencesGoOneAfterAnother() throws {
        let b = try source()
        var c = host("C")
        try c.tracks[0].overwrite(clip(0, 2))
        let a = host()
        var p = Project(name: "P", timelines: [a, b, c])
        let end = try p.placeSequenceClips([c.id, b.id], in: a.id, at: .zero, mode: .overwrite)
        #expect(end == s(7))
        #expect(try #require(p.timeline(a.id)).tracks[0].clips.map(\.start) == [.zero, s(2), s(4)])
    }

    @Test func cycleEmptyAndUnknownAreRefusedWithoutChange() throws {
        let b = try source(), a = host()
        var p = Project(name: "P", timelines: [a, b])
        let before = p
        #expect(throws: EditError.nestingCycle) { try p.placeSequenceClips([a.id], in: a.id, at: .zero, mode: .overwrite) }
        #expect(throws: EditError.emptyClip) { try p.placeSequenceClips([host("E").id], in: a.id, at: .zero, mode: .overwrite) }
        #expect(throws: EditError.timelineNotFound) { try p.placeSequenceClips([b.id], in: UUID(), at: .zero, mode: .overwrite) }
        #expect(p == before)
    }

    @Test func nestedClipsStayNests() throws {
        let inner = try source(), a = host()
        var mid = host("M")
        var nest = clip(0, 5)
        nest.sequence = inner.id
        try mid.tracks[0].overwrite(nest)
        var p = Project(name: "P", timelines: [a, inner, mid])
        try p.placeSequenceClips([mid.id], in: a.id, at: .zero, mode: .overwrite)
        #expect(try #require(p.timeline(a.id)).tracks[0].clips.first?.sequence == inner.id)
    }

    /// V1 only: one clip [1,3) (leading gap of 1 s), sequence length 3 s.
    private func gapped(name: String = "G") throws -> Timeline {
        Timeline(name: name, frameDuration: Time(1, 30), tracks: [try track([clip(1, 2)])])
    }

    @Test func insertKeepsTheLeadingGapAndTwoSequencesDoNotOverlap() throws {
        let b = try gapped()
        var a = host()
        try a.tracks[0].overwrite(clip(0, 10))
        var p = Project(name: "P", timelines: [a, b])
        let end = try p.placeSequenceClips([b.id, b.id], in: a.id, at: s(2), mode: .insert)
        #expect(end == s(8))                                                       // 2 x 3 s span
        let t = try #require(p.timeline(a.id))
        #expect(t.tracks[0].clips.map(\.start) == [.zero, s(3), s(6), s(8)])        // [0,2) | [3,5) | [6,8) | tail [8,16)
        #expect(t.tracks[0].clips.last!.timeline.duration == s(8))
    }

    @Test func trailingRangeBeyondTheLastClipIsRippledToo() throws {
        var b = try gapped()
        b.inOut = TimeRange(start: .zero, end: s(6))                                // Out mark 3 s after the last clip
        var a = host()
        try a.tracks[0].overwrite(clip(0, 10))
        var p = Project(name: "P", timelines: [a, b])
        let end = try p.placeSequenceClips([b.id], in: a.id, at: s(2), mode: .insert)
        #expect(end == s(8))
        #expect(try #require(p.timeline(a.id)).tracks[0].clips.last!.start == s(8))
    }

    @Test func dropTrackReceivesTheSequencesFirstLane() throws {
        let b = try source()
        var a = host()
        a.tracks.insert(Track(kind: .video), at: 1)
        a.tracks.insert(Track(kind: .video), at: 2)                                 // V1 V2 V3 A1
        a.tracks[0].isLocked = true
        var p = Project(name: "P", timelines: [a, b])
        let drop = a.tracks[2].id                                                   // V3
        try p.placeSequenceClips([b.id], in: a.id, at: .zero, videoTrack: drop, mode: .overwrite)
        let t = try #require(p.timeline(a.id))
        #expect(t.tracks[0].clips.isEmpty && t.tracks[1].clips.isEmpty)
        #expect(t.tracks[2].clips.map(\.start) == [.zero, s(2)])                    // source V1 -> V3
        #expect(t.tracks.filter { $0.kind == .video }.count == 4)                   // source V2 -> new V4
        #expect(t.tracks.last { $0.kind == .video }!.clips.map(\.start) == [s(1)])
    }

    @Test func newTrackPutsTheFirstLaneOnANewTrack() throws {
        let b = try source()
        var p = Project(name: "P", timelines: [host(), b])
        let a = p.timelines[0].id
        try p.placeSequenceClips([b.id], in: a, at: .zero, newTrack: .video, mode: .overwrite)
        let t = try #require(p.timeline(a))
        let v = t.tracks.filter { $0.kind == .video }
        #expect(v.count >= 2 && v[0].clips.isEmpty && v[1].clips.count == 2)
    }

    @Test func fastCutInsertKeepsAttachedClipsWithTheirMainTrackClip() throws {
        let b = try gapped()
        var a = host()
        a.tracks.insert(Track(kind: .video), at: 1)
        try a.tracks[0].overwrite(clip(0, 4))
        try a.tracks[1].overwrite(clip(3, 2))
        a.editMode = .magnetic
        var p = Project(name: "P", timelines: [a, b])
        try p.placeSequenceClips([b.id], in: a.id, at: s(2), videoTrack: a.tracks[0].id, mode: .insert)
        let glued = try #require(p.timeline(a.id))
        // V1's tail moves by the 3 s span; the V2 clip [3,5) attached to it goes along instead of being cut.
        #expect(glued.tracks[0].clips.last!.start == s(5))
        #expect(glued.tracks[1].clips.map(\.start) == [s(6)])
    }

    @Test func transitiveCycleIsRefused() throws {
        var a = host("A")
        var b = host("B")
        var nest = clip(0, 2)
        nest.sequence = a.id
        try b.tracks[0].overwrite(nest)
        a.tracks[0].isTargeted = true
        var p = Project(name: "P", timelines: [a, b])
        let before = p
        #expect(throws: EditError.nestingCycle) { try p.placeSequenceClips([b.id], in: a.id, at: .zero, mode: .overwrite) }
        #expect(p == before)
    }

    @Test func otherFrameRateClipsLandOnHostFrames() throws {
        var c = clip(0, 2)
        c.start = Time(1, 25)                                                       // one 25 fps frame in: off the 30 fps grid
        let b = Timeline(name: "B", frameDuration: Time(1, 25), tracks: [Track(kind: .video)].map { var t = $0; try? t.overwrite(c); return t })
        let a = host()
        var p = Project(name: "P", timelines: [a, b])
        try p.placeSequenceClips([b.id], in: a.id, at: .zero, mode: .overwrite)
        let placed = try #require(p.timeline(a.id)).tracks[0].clips[0]
        #expect(placed.start == placed.start.snapped(to: Time(1, 30)) && placed.timeline.end == placed.timeline.end.snapped(to: Time(1, 30)))
    }

    @Test func hiddenAndMutedSourceTracksAreSkipped() throws {
        var b = try source()
        b.tracks[2].isVisible = false
        b.tracks[1].isMuted = true
        let a = host()
        var p = Project(name: "P", timelines: [a, b])
        try p.placeSequenceClips([b.id], in: a.id, at: .zero, mode: .overwrite)
        let t = try #require(p.timeline(a.id))
        #expect(t.tracks.filter { $0.kind == .video }.count == 1 && t.tracks[1].clips.isEmpty)
    }

    @Test func offGridCutsSnapOnceAndKeepTheTransition() throws {
        // 25 fps clips [0, 7/25) and [7/25, 14/25) with handles; the cut at 8.4 host frames.
        let fd25 = Time(1, 25)
        func c(_ start: Int64) -> Clip {
            Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: fd25 * 25, duration: fd25 * 7),
                 start: fd25 * start, mediaDuration: s(100))
        }
        var tr = Track(kind: .video)
        let a = c(0), b = c(7)
        try tr.overwrite(a); try tr.overwrite(b)
        var src = Timeline(name: "B", frameDuration: fd25, tracks: [tr])
        try src.addTransition(point: .cut(outgoing: a.id, incoming: b.id), kind: .crossDissolve, track: src.tracks[0].id, duration: fd25 * 2)
        let host = host()
        var p = Project(name: "P", timelines: [host, src])
        try p.placeSequenceClips([src.id], in: host.id, at: .zero, mode: .overwrite)
        let t = try #require(p.timeline(host.id))
        let clips = t.tracks[0].clips
        #expect(clips.count == 2)
        #expect(clips[0].timeline.end == clips[1].start)                              // one shared cut, no gap or overlap
        #expect(clips[1].start == clips[1].start.snapped(to: Time(1, 30)) && clips[1].timeline.end == clips[1].timeline.end.snapped(to: Time(1, 30)))
        #expect(t.tracks[0].transitions.count == 1)
    }

    @Test func fastCutInsertOffTheMainTrackMovesNothing() throws {
        let b = try gapped()
        var a = host()
        a.tracks.insert(Track(kind: .video), at: 1)
        try a.tracks[0].overwrite(clip(0, 4))
        try a.tracks[1].overwrite(clip(0, 4))
        a.editMode = .magnetic
        var p = Project(name: "P", timelines: [a, b])
        try p.placeSequenceClips([b.id], in: a.id, at: s(2), videoTrack: a.tracks[1].id, mode: .insert)
        let t = try #require(p.timeline(a.id))
        #expect(t.tracks[0].clips.map(\.start) == [.zero])                           // V1 not a target: untouched
        #expect(t.tracks[1].clips.map(\.start) == [.zero])                           // the attached clip is not cut or pushed
        #expect(t.tracks.filter { $0.kind == .video }.count > 2)                      // the new clips yield to a free track
    }

    @Test func newTrackKeepsOffsetsWhenTheSourceStartsOnLaneOne() throws {
        // Source: V1 empty (hidden), clip on V2; A1 muted, clip on A2.
        let b = Timeline(name: "B", frameDuration: Time(1, 30), tracks: [
            try track([clip(0, 2)]), try track([clip(0, 2)]), try track([clip(0, 2, kind: .audio)], kind: .audio), try track([clip(0, 2, kind: .audio)], kind: .audio)])
        var src = b
        src.tracks[0].isVisible = false; src.tracks[2].isMuted = true
        var p = Project(name: "P", timelines: [host(), src])
        let h = p.timelines[0].id
        try p.placeSequenceClips([src.id], in: h, at: .zero, newTrack: .video, mode: .overwrite)
        var t = try #require(p.timeline(h))
        var v = t.tracks.filter { $0.kind == .video }
        #expect(v.count == 2 && v[0].clips.isEmpty && v[1].clips.count == 1)          // the one used lane is the new track
        var q = Project(name: "Q", timelines: [host(), src])
        let h2 = q.timelines[0].id
        try q.placeSequenceClips([src.id], in: h2, at: s(10), newTrack: .audio, mode: .overwrite)
        t = try #require(q.timeline(h2))
        let au = t.tracks.filter { $0.kind == .audio }
        #expect(au.count == 2 && au[0].clips.isEmpty && au[1].clips.map(\.start) == [s(10)])   // no extra tracks above the new one
        #expect(t.tracks.filter { $0.kind == .video }.count == 1)
    }
}
