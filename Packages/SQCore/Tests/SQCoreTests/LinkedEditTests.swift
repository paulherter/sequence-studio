import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func clip(_ start: Int64, _ dur: Int64, kind: TrackKind = .video, link: UUID? = nil) -> Clip {
    Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: s(0), duration: s(dur)),
         start: s(start), link: link)
}
private func track(_ clips: [Clip], kind: TrackKind = .video) throws -> Track {
    var t = Track(kind: kind)
    for c in clips { try t.overwrite(c) }
    return t
}
private func ids(_ tl: Timeline, _ id: Clip.ID) throws -> Set<Clip.ID> {
    Set(try tl.linkedGroup(id).map(\.clip.id))
}

@Suite struct SplitRelinkTests {
    @Test func insertRelinksRightHalves() throws {
        let l = UUID()
        let v = clip(0, 10, link: l), a = clip(0, 10, kind: .audio, link: l)
        var tl = Timeline(name: "t", frameDuration: Time(1, 30),
                          tracks: [try track([v]), try track([a], kind: .audio)])
        let ins = clip(0, 2)
        try tl.insert([(ins, tl.tracks[0].id)], at: s(5))
        let vr = tl.tracks[0].clips.first { $0.start == s(7) }!
        let ar = tl.tracks[1].clips.first { $0.start == s(7) }!
        #expect(try ids(tl, v.id) == [v.id, a.id])
        #expect(try ids(tl, vr.id) == [vr.id, ar.id])
        #expect(vr.link != l)
    }

    @Test func liftAndExtractRelinkAcrossHole() throws {
        let l = UUID()
        let v = clip(0, 10, link: l), a = clip(0, 10, kind: .audio, link: l)
        let base = Timeline(name: "t", frameDuration: Time(1, 30),
                            tracks: [try track([v]), try track([a], kind: .audio)])
        let both = base.tracks.map(\.id)
        for extract in [false, true] {
            var tl = base
            let hole = TimeRange(start: s(3), end: s(5))
            if extract { try tl.extract(hole, tracks: both) } else { try tl.lift(hole, tracks: both) }
            let vr = tl.tracks[0].clips.last!, ar = tl.tracks[1].clips.last!
            #expect(try ids(tl, v.id) == [v.id, a.id])
            #expect(try ids(tl, vr.id) == [vr.id, ar.id])
        }
    }

    @Test func overwriteAndThreePointOverwriteRelinkAcrossTracks() throws {
        let l = UUID()
        let v = clip(0, 10, link: l), a = clip(0, 10, kind: .audio, link: l)
        let base = Timeline(name: "t", frameDuration: Time(1, 30),
                            tracks: [try track([v]), try track([a], kind: .audio)])
        let both = base.tracks.map(\.id)
        func check(_ tl: Timeline) throws {
            let vr = tl.tracks[0].clips.last!, ar = tl.tracks[1].clips.last!
            #expect(vr.start == s(6) && ar.start == s(6))
            #expect(try ids(tl, v.id) == [v.id, a.id])
            #expect(try ids(tl, vr.id) == [vr.id, ar.id])
        }
        var t1 = base
        try t1.overwrite([(clip(0, 2), both[0]), (clip(0, 2, kind: .audio), both[1])], at: s(4))
        try check(t1)
        var t2 = base
        try t2.threePointEdit(source: TimeRange(start: s(0), duration: s(2)), media: UUID(),
                              targets: both, at: s(4), mode: .overwrite)
        try check(t2)
    }

    @Test func movingLinkedPairOverLinkedPairRelinksRightHalves() throws {
        let l = UUID(), k = UUID()
        let v = clip(0, 10, link: l), a = clip(0, 10, kind: .audio, link: l)
        let m = clip(20, 2, link: k), m2 = clip(20, 2, kind: .audio, link: k)
        var tl = Timeline(name: "t", frameDuration: Time(1, 30),
                          tracks: [try track([v, m]), try track([a, m2], kind: .audio)])
        try tl.move(m.id, to: s(4))
        let vr = tl.tracks[0].clips.last!, ar = tl.tracks[1].clips.last!
        #expect(vr.start == s(6) && ar.start == s(6))
        #expect(try ids(tl, v.id) == [v.id, a.id])
        #expect(try ids(tl, vr.id) == [vr.id, ar.id])
    }

    @Test func unlinkedStaysUnlinked() throws {
        var t = try track([clip(0, 10)])
        try t.split(at: s(4))
        #expect(t.clips.allSatisfy { $0.link == nil })
    }
}

@Suite struct SyncedRippleTests {
    @Test func rippleDeleteShiftsAllTracksByGroupSpan() throws {
        let l1 = UUID(), l2 = UUID()
        let v1 = clip(10, 10, link: l1), a1 = clip(8, 12, kind: .audio, link: l1)
        let v2 = clip(20, 10, link: l2), a2 = clip(20, 10, kind: .audio, link: l2)
        var tl = Timeline(name: "t", frameDuration: Time(1, 30),
                          tracks: [try track([v1, v2]), try track([a1, a2], kind: .audio)])
        #expect(try tl.rippleDelete([v1.id]) == s(12))
        #expect(tl.find(v2.id)!.clip.start == s(8))
        #expect(tl.find(a2.id)!.clip.start == s(8))
    }

    @Test func rippleDeleteShrinksCommonAmountOnCollision() throws {
        let l1 = UUID()
        let v1 = clip(10, 10, link: l1), a1 = clip(8, 12, kind: .audio, link: l1)
        let v2 = clip(20, 10), a2 = clip(20, 10, kind: .audio)
        let blocker = clip(5, 10, kind: .video)          // on a third track, ends at 15, sync-locked
        var tl = Timeline(name: "t", frameDuration: Time(1, 30),
                          tracks: [try track([v1, v2]), try track([a1, a2], kind: .audio),
                                   try track([blocker, clip(25, 5)])])
        let closed = try tl.rippleDelete([v1.id])
        #expect(closed == s(10))                          // third track: 25 - 15 = 10 room
        #expect(tl.find(v2.id)!.clip.start == s(10))
        #expect(tl.find(a2.id)!.clip.start == s(10))
    }
}

@Suite struct RippleTrimPivotTests {
    private func setup() throws -> (Timeline, Clip, Clip, Clip) {
        let l = UUID()
        let v = clip(10, 10, link: l), a = clip(8, 7, kind: .audio, link: l), c = clip(15, 3, kind: .audio)
        let tl = Timeline(name: "t", frameDuration: Time(1, 30),
                          tracks: [try track([v]), try track([a, c], kind: .audio)])
        return (tl, v, a, c)
    }

    @Test func extendPushesUnlinkedClipAfterPartner() throws {
        var (tl, v, a, c) = try setup()
        #expect(try tl.rippleTrim(v.id, edge: .tail, by: s(2)) == s(2))
        #expect(tl.find(a.id)!.clip.timeline == TimeRange(start: s(8), end: s(17)))
        #expect(tl.find(c.id)!.clip.timeline == TimeRange(start: s(17), end: s(20)))
    }

    @Test func shortenPullsUnlinkedClipAfterPartner() throws {
        var (tl, v, a, c) = try setup()
        #expect(try tl.rippleTrim(v.id, edge: .tail, by: s(-2)) == s(-2))
        #expect(tl.find(a.id)!.clip.timeline == TimeRange(start: s(8), end: s(13)))
        #expect(tl.find(c.id)!.clip.timeline == TimeRange(start: s(13), end: s(16)))
    }
}
