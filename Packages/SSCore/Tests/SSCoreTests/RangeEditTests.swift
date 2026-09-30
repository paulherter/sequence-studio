import Foundation
import Testing
@testable import SSCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func r(_ a: Int64, _ b: Int64) -> TimeRange { TimeRange(start: s(a), end: s(b)) }
private func clip(_ start: Int64, _ dur: Int64, src: Int64 = 0, kind: TrackKind = .video,
                  link: UUID? = nil, media: Int64? = nil) -> Clip {
    Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: s(src), duration: s(dur)),
         start: s(start), link: link, mediaDuration: media.map(s))
}
private func track(_ clips: [Clip], kind: TrackKind = .video, locked: Bool = false, sync: Bool = true) throws -> Track {
    var t = Track(kind: kind, isLocked: locked, syncLock: sync)
    for c in clips { try t.overwrite(c) }
    return t
}
private func timeline(_ tracks: Track...) -> Timeline { Timeline(name: "t", frameDuration: Time(1, 30), tracks: tracks) }
private func spans(_ t: Track) -> [[Int64]] {
    t.clips.map { [$0.start.value / $0.start.timescale, $0.timeline.end.value / $0.timeline.end.timescale] }
}

@Suite struct LiftTests {
    @Test func cutsStraddlersRemovesInsideLeavesGap() throws {
        let a = clip(0, 4), b = clip(4, 2), c = clip(6, 4, src: 10)
        var tl = timeline(try track([a, b, c]))
        try tl.lift(r(2, 8), tracks: [tl.tracks[0].id])
        #expect(spans(tl.tracks[0]) == [[0, 2], [8, 10]])
        #expect(tl.tracks[0].clips[1].source.start == s(12))
        #expect(tl.tracks[0].clips[0].id == a.id)
    }
    @Test func onlyTargetedTracksAndLockedRefused() throws {
        var tl = timeline(try track([clip(0, 6)]), try track([clip(0, 6)], locked: true))
        try tl.lift(r(1, 3), tracks: [tl.tracks[0].id])
        #expect(spans(tl.tracks[0]) == [[0, 1], [3, 6]])
        #expect(spans(tl.tracks[1]) == [[0, 6]])
        let before = tl
        #expect(throws: EditError.trackLocked) { try tl.lift(r(1, 3), tracks: [tl.tracks[0].id, tl.tracks[1].id]) }
        #expect(tl == before)
    }
    @Test func linkedPartnersOnTargetedTracksShareLink() throws {
        let l = UUID()
        var tl = timeline(try track([clip(0, 6, link: l)]), try track([clip(0, 6, kind: .audio, link: l)], kind: .audio))
        try tl.lift(r(2, 4), tracks: tl.tracks.map(\.id))
        for t in tl.tracks { #expect(spans(t) == [[0, 2], [4, 6]]) }
        #expect(tl.tracks[0].clips[0].link == l && tl.tracks[1].clips[0].link == l)   // left halves keep the link
        let r = tl.tracks.map { $0.clips[1].link }                                   // right halves share a new one
        #expect(r[0] != nil && r[0] == r[1] && r[0] != l)
    }
}

@Suite struct ExtractTests {
    @Test func closesGap() throws {
        var tl = timeline(try track([clip(0, 4), clip(4, 4), clip(8, 2)]))
        let closed = try tl.extract(r(2, 6), tracks: [tl.tracks[0].id])
        #expect(closed == s(4))
        #expect(spans(tl.tracks[0]) == [[0, 2], [2, 4], [4, 6]])
    }
    @Test func syncLockedOtherTrackShiftsUnlockedNoSyncStays() throws {
        var tl = timeline(try track([clip(0, 10)]),
                          try track([clip(0, 1), clip(8, 2)], sync: true),
                          try track([clip(8, 2)], sync: false),
                          try track([clip(8, 2)], locked: true))
        try tl.extract(r(2, 6), tracks: [tl.tracks[0].id])
        #expect(spans(tl.tracks[0]) == [[0, 2], [2, 6]])
        #expect(spans(tl.tracks[1]) == [[0, 1], [4, 6]])
        #expect(spans(tl.tracks[2]) == [[8, 10]])
        #expect(spans(tl.tracks[3]) == [[8, 10]])
    }
    @Test func blockedByOtherTrackClosesPartially() throws {
        var tl = timeline(try track([clip(0, 10)]), try track([clip(0, 4), clip(8, 2)]))
        // track 1 has only 4 s of room before its clip at 8; the range is 5 s
        let closed = try tl.extract(r(1, 6), tracks: [tl.tracks[0].id])
        #expect(closed == s(4))
        #expect(spans(tl.tracks[0]) == [[0, 1], [2, 6]])
        #expect(tl.tracks.allSatisfy { $0.isConsistent })
    }
    @Test func lockedTargetRefused() throws {
        var tl = timeline(try track([clip(0, 10)], locked: true))
        #expect(throws: EditError.trackLocked) { try tl.extract(r(2, 4), tracks: [tl.tracks[0].id]) }
    }
}

@Suite struct SlideTests {
    @Test func slideRightAdjustsNeighbours() throws {
        let p = clip(0, 4, media: 20), m = clip(4, 2, src: 7), n = clip(6, 4, src: 3)
        var tl = timeline(try track([p, m, n]))
        #expect(try tl.slide(m.id, by: s(2)) == s(2))
        let cs = tl.tracks[0].clips
        #expect(cs[0].timeline == r(0, 6))
        #expect(cs[1].start == s(6) && cs[1].source == m.source)
        #expect(cs[2].start == s(8) && cs[2].source == TimeRange(start: s(5), duration: s(2)))
    }
    @Test func slideLeft() throws {
        let p = clip(0, 4), m = clip(4, 2), n = clip(6, 4, src: 3)
        var tl = timeline(try track([p, m, n]))
        #expect(try tl.slide(m.id, by: s(-1)) == s(-1))
        let cs = tl.tracks[0].clips
        #expect(cs[0].timeline == r(0, 3) && cs[1].start == s(3))
        #expect(cs[2].start == s(5) && cs[2].source.start == s(2) && cs[2].timeline.end == s(10))
    }
    @Test func clampedByNeighbourAndHandles() throws {
        let p = clip(0, 4, media: 5), m = clip(4, 2), n = clip(6, 4, src: 1)
        var tl = timeline(try track([p, m, n]))
        #expect(try tl.slide(m.id, by: s(9)) == s(1))                    // prev media handle
        var t2 = timeline(try track([clip(0, 4), clip(4, 2), clip(6, 4, src: 2)]))
        #expect(try t2.slide(t2.tracks[0].clips[1].id, by: s(-9)) == s(-2))   // next source handle
        var t3 = timeline(try track([clip(0, 2), clip(2, 2), clip(4, 4, src: 9)]))
        let d = try t3.slide(t3.tracks[0].clips[1].id, by: s(-9))        // prev would vanish
        #expect(d > s(-2) && t3.tracks[0].clips[0].source.duration > .zero)
        #expect(t3.tracks[0].isConsistent)
    }
    @Test func gapSideLimitsAndFirstClip() throws {
        var tl = timeline(try track([clip(2, 2), clip(8, 2)]))
        let id = tl.tracks[0].clips[0].id
        #expect(try tl.slide(id, by: s(9)) == s(4))                      // gap to next
        var t2 = timeline(try track([clip(6, 2), clip(12, 2)]))
        #expect(try t2.slide(t2.tracks[0].clips[0].id, by: s(-9)) == s(-6))   // back to 0
        #expect(t2.tracks[0].clips[0].start == s(0))
    }
    @Test func partnersFollowAndLockRefused() throws {
        let l = UUID()
        let v = [clip(0, 4, media: 20), clip(4, 2, link: l), clip(6, 4, src: 3)]
        let a = [clip(0, 4, kind: .audio, media: 20), clip(4, 2, kind: .audio, link: l), clip(6, 4, src: 3, kind: .audio)]
        var tl = timeline(try track(v), try track(a, kind: .audio))
        #expect(try tl.slide(v[1].id, by: s(1)) == s(1))
        #expect(tl.tracks[1].clips[1].start == s(5) && tl.tracks[1].clips[0].timeline.end == s(5))
        var lk = timeline(try track(v), try track(a, kind: .audio, locked: true))
        #expect(throws: EditError.trackLocked) { try lk.slide(v[1].id, by: s(1)) }
    }
}

@Suite struct InsertMoveTests {
    @Test func moveLaterClosesSourceAndInsertsAtDestination() throws {
        let a = clip(0, 2), b = clip(2, 2), c = clip(4, 4), d = clip(8, 2)
        var tl = timeline(try track([a, b, c, d]))
        // drop a at original time 6 (inside c): after closing, c spans 2..6 and is split at 4
        try tl.moveInsert(a.id, to: s(6))
        #expect(spans(tl.tracks[0]) == [[0, 2], [2, 4], [4, 6], [6, 8], [8, 10]])
        let cs = tl.tracks[0].clips
        #expect(cs[0].id == b.id && cs[2].id == a.id && cs[1].id == c.id)
        #expect(cs[3].source == TimeRange(start: s(2), duration: s(2)))
    }
    @Test func moveEarlierPushesOthersRight() throws {
        let a = clip(0, 2), b = clip(2, 2), c = clip(4, 2)
        var tl = timeline(try track([a, b, c]))
        try tl.moveInsert(c.id, to: s(2))
        let order = tl.tracks[0].clips.map(\.id)
        #expect(order == [a.id, c.id, b.id])
        #expect(spans(tl.tracks[0]) == [[0, 2], [2, 4], [4, 6]])
    }
    @Test func splitsClipWhenDroppedInside() throws {
        let a = clip(0, 2), b = clip(2, 4), c = clip(6, 2, src: 0)
        var tl = timeline(try track([a, b, c]))
        try tl.moveInsert(c.id, to: s(4))          // inside b
        #expect(spans(tl.tracks[0]) == [[0, 2], [2, 4], [4, 6], [6, 8]])
        let cs = tl.tracks[0].clips
        #expect(cs[2].id == c.id && cs[1].id == b.id)
        #expect(cs[3].source == TimeRange(start: s(2), duration: s(2)))
    }
    @Test func syncLockAndLocksAndPartners() throws {
        let l = UUID()
        let v = [clip(0, 2, link: l), clip(2, 4)], au = [clip(0, 2, kind: .audio, link: l), clip(2, 4, kind: .audio)]
        var tl = timeline(try track(v), try track(au, kind: .audio), try track([clip(2, 4)]), try track([clip(2, 4)], locked: true))
        try tl.moveInsert(v[0].id, to: s(6))       // to the end
        #expect(spans(tl.tracks[0]) == [[0, 4], [4, 6]])
        #expect(tl.tracks[1].clips.last?.link == l)
        #expect(spans(tl.tracks[1]) == [[0, 4], [4, 6]])
        #expect(spans(tl.tracks[2]) == [[0, 4]])
        #expect(spans(tl.tracks[3]) == [[2, 6]])
        var lk = timeline(try track(v), try track(au, kind: .audio, locked: true))
        #expect(throws: EditError.trackLocked) { try lk.moveInsert(v[0].id, to: s(6)) }
    }
}

@Suite struct InsertMoveOffsetTests {
    // J-cut: audio starts one second before its video. Video v1 4..8, audio a1 3..7.
    private func jcut() throws -> (Timeline, [Clip], [Clip]) {
        let l = UUID()
        let v = [clip(0, 4), clip(4, 4, link: l), clip(8, 4)]
        let a = [clip(0, 3, kind: .audio), clip(3, 4, kind: .audio, link: l), clip(7, 5, kind: .audio)]
        return (timeline(try track(v), try track(a, kind: .audio)), v, a)
    }
    @Test func jCutMovedForwardKeepsOffset() throws {
        var (tl, v, a) = try jcut()
        try tl.moveInsert(v[1].id, to: s(12))
        #expect(spans(tl.tracks[0]) == [[0, 4], [4, 8], [9, 13]])
        #expect(spans(tl.tracks[1]) == [[0, 3], [3, 8], [8, 12]])
        #expect(tl.tracks[0].clips[2].id == v[1].id && tl.tracks[1].clips[2].id == a[1].id)
        #expect(tl.tracks[0].clips[2].link == tl.tracks[1].clips[2].link && tl.tracks[0].clips[2].link != nil)
    }
    @Test func jCutMovedBackwardKeepsOffset() throws {
        var (tl, v, a) = try jcut()
        try tl.moveInsert(a[1].id, to: s(0))       // drag by the audio partner
        #expect(spans(tl.tracks[0]) == [[1, 5], [5, 9], [9, 13]])
        #expect(spans(tl.tracks[1]) == [[0, 4], [5, 8], [8, 13]])
        #expect(tl.tracks[0].clips[0].id == v[1].id && tl.tracks[1].clips[0].id == a[1].id)
    }
    @Test func jCutDroppedMidClipSplitsEveryTrack() throws {
        var (tl, v, a) = try jcut()
        try tl.moveInsert(v[1].id, to: s(2))
        #expect(spans(tl.tracks[0]) == [[0, 2], [3, 7], [7, 9], [9, 13]])
        #expect(spans(tl.tracks[1]) == [[0, 2], [2, 6], [7, 8], [8, 13]])
        #expect(tl.tracks[0].clips[1].id == v[1].id && tl.tracks[1].clips[1].id == a[1].id)
        #expect(tl.tracks.allSatisfy { $0.isConsistent })
    }
    @Test func lCutAudioEndsLater() throws {
        let l = UUID()
        let v = [clip(0, 4), clip(4, 4, link: l), clip(8, 4)]
        let a = [clip(0, 4, kind: .audio), clip(4, 5, kind: .audio, link: l), clip(9, 3, kind: .audio)]
        var tl = timeline(try track(v), try track(a, kind: .audio))
        try tl.moveInsert(v[1].id, to: s(12))
        // The union of the group closes by one amount on every track (V lacks room for 5, so 4).
        #expect(spans(tl.tracks[0]) == [[0, 4], [4, 8], [8, 12]])
        #expect(spans(tl.tracks[1]) == [[0, 4], [5, 8], [8, 13]])
        #expect(tl.tracks[1].clips[2].id == a[1].id && tl.tracks[1].clips[2].link == l)
    }
    @Test func lockedPartnerRefusesAndSyncLockedTrackShifts() throws {
        let (tl0, v, _) = try jcut()
        var locked = tl0
        locked.tracks[1].isLocked = true
        let before = locked
        #expect(throws: EditError.trackLocked) { try locked.moveInsert(v[1].id, to: s(12)) }
        #expect(locked == before)
        // sync-locked bystander after the group closes by 4, then is pushed by the 5 s span
        var tl = tl0
        tl.tracks.append(try track([clip(8, 4)]))
        try tl.moveInsert(v[1].id, to: s(0))
        #expect(spans(tl.tracks[2]) == [[9, 13]])
        var tl2 = tl0
        tl2.tracks.append(try track([clip(8, 4)]))
        try tl2.moveInsert(v[1].id, to: s(12))
        #expect(spans(tl2.tracks[2]) == [[4, 8]])
    }
}
