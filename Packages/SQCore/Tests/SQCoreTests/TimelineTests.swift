import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
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
private func starts(_ t: Track) -> [Time] { t.clips.map(\.start) }

@Suite struct RippleDeleteTests {
    @Test func shiftsAllSyncLockedTracks() throws {
        let a = clip(2, 3)
        let v1 = try track([clip(0, 2), a, clip(5, 2)])
        let v2 = try track([clip(6, 2)])
        let a1 = try track([clip(8, 1, kind: .audio)], kind: .audio)
        var tl = timeline(v1, v2, a1)
        let closed = try tl.rippleDelete([a.id])
        #expect(closed == s(3))
        #expect(starts(tl.tracks[0]) == [s(0), s(2)])
        #expect(starts(tl.tracks[1]) == [s(3)])
        #expect(starts(tl.tracks[2]) == [s(5)])
    }

    @Test func lockedAndUnsyncedTracksStay() throws {
        let a = clip(0, 2)
        let v1 = try track([a, clip(2, 2)])
        let locked = try track([clip(4, 1)], locked: true)
        let unsynced = try track([clip(5, 1)], sync: false)
        var tl = timeline(v1, locked, unsynced)
        try tl.rippleDelete([a.id])
        #expect(starts(tl.tracks[0]) == [s(0)])
        #expect(starts(tl.tracks[1]) == [s(4)])
        #expect(starts(tl.tracks[2]) == [s(5)])
    }

    @Test func blockedByClipOnOtherTrackClosesPartially() throws {
        let a = clip(2, 4)                                  // range 2..6
        let v1 = try track([clip(0, 2), a, clip(6, 2)])
        let v2 = try track([clip(1, 4), clip(6, 1)])        // straddles into the deleted range, ends at 5
        var tl = timeline(v1, v2)
        let closed = try tl.rippleDelete([a.id])
        #expect(closed == s(1))                             // v2 gap between 5 and 6 is 1
        #expect(starts(tl.tracks[0]) == [s(0), s(5)])
        #expect(starts(tl.tracks[1]) == [s(1), s(5)])
        #expect(tl.tracks.allSatisfy { $0.isConsistent })
    }

    @Test func deletesLinkedPartner() throws {
        let link = UUID()
        let v = clip(1, 2, link: link), au = clip(1, 2, kind: .audio, link: link)
        var tl = timeline(try track([clip(0, 1), v, clip(3, 1)]), try track([au, clip(3, 1, kind: .audio)], kind: .audio))
        try tl.rippleDelete([v.id])
        #expect(tl.tracks[0].clips.count == 2 && tl.tracks[1].clips.count == 1)
        #expect(starts(tl.tracks[1]) == [s(1)])
    }

    @Test func lockedOwnTrackIsRefusedAndNothingChanges() throws {
        let a = clip(0, 2)
        let tl0 = timeline(try track([a, clip(2, 1)], locked: true), try track([clip(3, 1)]))
        var tl = tl0
        #expect(throws: EditError.trackLocked) { try tl.rippleDelete([a.id]) }
        #expect(tl == tl0)
    }

    @Test func multipleClipsRightToLeft() throws {
        let a = clip(0, 1), b = clip(2, 1)
        var tl = timeline(try track([a, clip(1, 1), b, clip(3, 1)]))
        try tl.rippleDelete([a.id, b.id])
        #expect(starts(tl.tracks[0]) == [s(0), s(1)])
    }
}

@Suite struct RippleTrimTests {
    @Test func tailShortenPullsAllTracks() throws {
        let a = clip(0, 4, media: 10)
        var tl = timeline(try track([a, clip(4, 2)]), try track([clip(5, 1)]))
        let moved = try tl.rippleTrim(a.id, edge: .tail, by: s(-1))
        #expect(moved == s(-1))
        #expect(tl.tracks[0].clips[0].timeline == TimeRange(start: s(0), duration: s(3)))
        #expect(starts(tl.tracks[0]) == [s(0), s(3)])
        #expect(starts(tl.tracks[1]) == [s(4)])
    }

    @Test func tailExtendPushesAndStopsAtMediaEnd() throws {
        let a = clip(0, 4, media: 6)
        var tl = timeline(try track([a, clip(4, 2)]), try track([clip(5, 1)]))
        let moved = try tl.rippleTrim(a.id, edge: .tail, by: s(5))
        #expect(moved == s(2))
        #expect(starts(tl.tracks[0]) == [s(0), s(6)])
        #expect(starts(tl.tracks[1]) == [s(7)])
    }

    @Test func headTrimKeepsStartAdvancesSource() throws {
        let a = clip(2, 4, src: 10)
        var tl = timeline(try track([clip(0, 2), a, clip(6, 1)]), try track([clip(7, 1)]))
        let moved = try tl.rippleTrim(a.id, edge: .head, by: s(1))
        #expect(moved == s(1))
        let c = tl.tracks[0].clips[1]
        #expect(c.start == s(2) && c.source == TimeRange(start: s(11), duration: s(3)))
        #expect(starts(tl.tracks[0]) == [s(0), s(2), s(5)])
        #expect(starts(tl.tracks[1]) == [s(6)])
    }

    @Test func headExtendLimitedBySourceStart() throws {
        let a = clip(2, 2, src: 1)
        var tl = timeline(try track([a, clip(4, 1)]))
        let moved = try tl.rippleTrim(a.id, edge: .head, by: s(-3))
        #expect(moved == s(-1))
        #expect(tl.tracks[0].clips[0].source == TimeRange(start: s(0), duration: s(3)))
        #expect(starts(tl.tracks[0]) == [s(2), s(5)])
    }

    @Test func shortenBlockedByOtherTrack() throws {
        let a = clip(0, 4, media: 10)
        var tl = timeline(try track([a, clip(4, 2)]), try track([clip(0, 3), clip(4, 1)]))   // v2 ends at 3, next at 4
        let moved = try tl.rippleTrim(a.id, edge: .tail, by: s(-3))
        #expect(moved == s(-1))
        #expect(tl.tracks.allSatisfy { $0.isConsistent })
    }

    @Test func linkedPartnerTrimsToo() throws {
        let link = UUID()
        let v = clip(0, 4, link: link, media: 10), au = clip(0, 4, kind: .audio, link: link, media: 10)
        var tl = timeline(try track([v, clip(4, 1)]), try track([au, clip(4, 1, kind: .audio)], kind: .audio))
        try tl.rippleTrim(v.id, edge: .tail, by: s(-2))
        #expect(tl.tracks[1].clips[0].source.duration == s(2))
        #expect(starts(tl.tracks[1]) == [s(0), s(2)])
    }

    @Test func emptyingAndLockedAreRefused() throws {
        let a = clip(0, 2)
        var tl = timeline(try track([a]))
        #expect(throws: EditError.emptyClip) { try tl.rippleTrim(a.id, edge: .tail, by: s(-2)) }
        var locked = timeline(try track([a], locked: true))
        #expect(throws: EditError.trackLocked) { try locked.rippleTrim(a.id, edge: .tail, by: s(1)) }
    }

    // V1 verification (docs/research/V1-edit-bug-verification.md): head edits pivot at the edit point, not the clip end.

    private func cap(_ text: String, _ a: Int64, _ b: Int64) -> CaptionItem {
        CaptionItem(lines: [text], range: TimeRange(start: s(a), end: s(b)))
    }
    private func captions(_ tl: Timeline) -> [String] {
        tl.captionTracks[0].items.map { "\($0.lines[0])@\($0.range.start.value / $0.range.start.timescale)-\($0.range.end.value / $0.range.end.timescale)" }
    }

    @Test func headTrimKeepsOtherTracksCaptionsAndMarkersInSync() throws {
        let a = clip(0, 10, src: 100, media: 200)
        var tl = timeline(try track([a]), try track([clip(6, 2, src: 106)]))
        tl.captionTracks = [CaptionTrack(items: [cap("six", 6, 7), cap("nine", 9, 10)])]
        tl.addMarker(at: s(6))
        tl.inOut = TimeRange(start: s(6), end: s(9))
        try tl.rippleTrimToPlayhead(.head, at: s(2), tracks: nil)
        let c = tl.tracks[0].clips[0]
        #expect(c.timeline == TimeRange(start: s(0), duration: s(8)) && c.source.start == s(102))
        #expect(starts(tl.tracks[1]) == [s(4)])
        #expect(captions(tl) == ["six@4-5", "nine@7-8"])
        #expect(tl.markers.map(\.time) == [s(4)])
        #expect(tl.inOut == TimeRange(start: s(4), end: s(7)))
    }

    @Test func headExtensionOpensAtTheEditPoint() throws {
        let a = clip(0, 8, src: 102, media: 200)
        var tl = timeline(try track([a, clip(8, 2)]), try track([clip(4, 2, src: 106)]))
        tl.captionTracks = [CaptionTrack(items: [cap("six", 4, 5), cap("nine", 7, 8)])]
        tl.addMarker(at: s(4))
        let moved = try tl.rippleTrim(a.id, edge: .head, by: s(-2))
        #expect(moved == s(-2))
        #expect(tl.tracks[0].clips[0].source == TimeRange(start: s(100), duration: s(10)))
        #expect(starts(tl.tracks[0]) == [s(0), s(10)])
        #expect(starts(tl.tracks[1]) == [s(6)])
        #expect(captions(tl) == ["six@6-7", "nine@9-10"])
        #expect(tl.markers.map(\.time) == [s(6)])
    }

    @Test func headTrimLimitedByStraddlingClipOnOtherTrack() throws {
        let a = clip(0, 10, media: 20)
        var tl = timeline(try track([a]), try track([clip(0, 3), clip(4, 2)]))
        let r = try tl.rippleTrimToPlayheadDetailed(.head, at: s(3), tracks: [tl.tracks[0].id])
        #expect(r.moved == s(1))
        #expect(r.limitedBy == tl.tracks[1].id)
        #expect(tl.tracks[0].clips[0].timeline.duration == s(9))
        #expect(starts(tl.tracks[1]) == [s(0), s(3)])
        #expect(tl.tracks.allSatisfy { $0.isConsistent })
    }

    @Test func tailTrimReportsLimitingTrack() throws {
        let a = clip(0, 4, media: 10)
        var tl = timeline(try track([a, clip(4, 2)]), try track([clip(0, 3), clip(4, 1)]))
        let r = try tl.rippleTrimToPlayheadDetailed(.tail, at: s(1), tracks: [tl.tracks[0].id])
        #expect(r.moved == s(-1) && r.limitedBy == tl.tracks[1].id)
        var free = timeline(try track([a, clip(4, 2)]), try track([clip(6, 1)]))
        let f = try free.rippleTrimToPlayheadDetailed(.tail, at: s(1), tracks: [free.tracks[0].id])
        #expect(f.moved == s(-3) && f.limitedBy == nil)
    }

    @Test func multiTrackHeadQShiftsOnce() throws {
        var tl = timeline(try track([clip(0, 10, media: 20), clip(10, 2)]),
                          try track([clip(0, 10, media: 20), clip(10, 2)]),
                          try track([clip(9, 3)]))
        tl.captionTracks = [CaptionTrack(items: [cap("nine", 9, 10)])]
        tl.addMarker(at: s(9))
        try tl.rippleTrimToPlayhead(.head, at: s(2), tracks: nil)
        #expect(starts(tl.tracks[0]) == [s(0), s(8)])
        #expect(starts(tl.tracks[1]) == [s(0), s(8)])
        #expect(starts(tl.tracks[2]) == [s(7)])
        #expect(captions(tl) == ["nine@7-8"])
        #expect(tl.markers.map(\.time) == [s(7)])
    }

    @Test func multiTrackTailWShiftsOnce() throws {
        var tl = timeline(try track([clip(0, 10, media: 20), clip(10, 2)]),
                          try track([clip(0, 10, media: 20), clip(10, 2)]))
        tl.captionTracks = [CaptionTrack(items: [cap("eleven", 11, 12)])]
        tl.addMarker(at: s(11))
        try tl.rippleTrimToPlayhead(.tail, at: s(8), tracks: nil)
        #expect(starts(tl.tracks[0]) == [s(0), s(8)])
        #expect(starts(tl.tracks[1]) == [s(0), s(8)])
        #expect(captions(tl) == ["eleven@9-10"])
        #expect(tl.markers.map(\.time) == [s(9)])
    }

    // Review round: picks with different amounts share ONE removal span (the nearest edit to the playhead).

    private func ranges(_ tl: Timeline) -> [Clip.ID: TimeRange] {
        Dictionary(uniqueKeysWithValues: tl.tracks.flatMap(\.clips).map { ($0.id, $0.timeline) })
    }

    @Test func differentAmountsShareOneSpan() throws {
        let v1 = clip(0, 10, media: 20), v2 = clip(3, 10, media: 20), au = clip(13, 2, kind: .audio)
        var tl = timeline(try track([v1]), try track([v2]), try track([au], kind: .audio))
        tl.captionTracks = [CaptionTrack(items: [cap("thirteen", 13, 14)])]
        tl.addMarker(at: s(13))
        let r = try tl.rippleTrimToPlayheadDetailed(.head, at: s(5), tracks: nil)
        #expect(r.moved == s(2))                                        // V2's head [3,5) is the span
        #expect(tl.tracks[0].clips[0].timeline == v1.timeline)          // V1 straddles, nothing after it
        #expect(tl.tracks[1].clips[0].timeline == TimeRange(start: s(3), duration: s(8)))
        #expect(tl.tracks[1].clips[0].source.start == s(2))
        #expect(starts(tl.tracks[2]) == [s(11)])                        // in sync with V2
        #expect(captions(tl) == ["thirteen@11-12"])
        #expect(tl.markers.map(\.time) == [s(11)])
    }

    @Test func differentAmountsAreOrderIndependent() throws {
        let v1 = clip(0, 10, media: 20), v2 = clip(3, 10, media: 20), au = clip(13, 2, kind: .audio)
        let t1 = try track([v1]), t2 = try track([v2]), t3 = try track([au], kind: .audio)
        var a = timeline(t1, t2, t3), b = timeline(t3, t2, t1)
        let ra = try a.rippleTrimToPlayheadDetailed(.head, at: s(5), tracks: nil)
        let rb = try b.rippleTrimToPlayheadDetailed(.head, at: s(5), tracks: nil)
        #expect(ra.moved == rb.moved)
        #expect(ranges(a) == ranges(b))
    }

    @Test func straddlingPickWithLaterClipBlocksEveryPick() throws {
        let v1 = clip(0, 10, media: 20), v2 = clip(3, 10, media: 20)
        var tl = timeline(try track([v1, clip(10, 2)]), try track([v2]))
        let before = ranges(tl)
        let r = try tl.rippleTrimToPlayheadDetailed(.head, at: s(5), tracks: nil)
        #expect(r.moved == .zero && r.limitedBy == tl.tracks[0].id)
        #expect(ranges(tl) == before)
    }

    @Test func playheadOnAnEditRipplesEverything() throws {
        let v1 = clip(4, 6), v2 = clip(0, 10, media: 20)
        var tl = timeline(try track([v1]), try track([v2]))              // V1's pick is first and has amount 0
        tl.captionTracks = [CaptionTrack(items: [cap("eight", 8, 9)])]
        tl.addMarker(at: s(8))
        tl.inOut = TimeRange(start: s(8), end: s(9))
        let moved = try tl.rippleTrimToPlayhead(.head, at: s(4), tracks: nil)
        #expect(moved == s(4))
        #expect(tl.tracks[1].clips[0].timeline == TimeRange(start: s(0), duration: s(6)))
        #expect(starts(tl.tracks[0]) == [s(0)])                          // V1 slides with V2's cut
        #expect(captions(tl) == ["eight@4-5"])
        #expect(tl.markers.map(\.time) == [s(4)])
        #expect(tl.inOut == TimeRange(start: s(4), end: s(5)))
    }

    @Test func straddlingClipLimitsAllPicks() throws {
        let v1 = clip(0, 10, media: 20), v2 = clip(0, 10, media: 20)
        var tl = timeline(try track([v1]), try track([v2]), try track([clip(1, 5), clip(6, 2)]))
        let before = ranges(tl)
        let r = try tl.rippleTrimToPlayheadDetailed(.head, at: s(2), tracks: [tl.tracks[0].id, tl.tracks[1].id])
        #expect(r.moved == .zero && r.limitedBy == tl.tracks[2].id)      // first pick clamped to 0: none trims
        #expect(ranges(tl) == before)
    }
}

@Suite struct TimelineInsertTests {
    @Test func insertSplitsAndPushesOtherTracksLockedStay() throws {
        let v1 = try track([clip(0, 10, src: 50)])
        let v2 = try track([clip(2, 6)])
        let locked = try track([clip(3, 1)], locked: true)
        var tl = timeline(v1, v2, locked)
        try tl.insert([(clip(0, 3), tl.tracks[0].id)], at: s(4))
        #expect(tl.tracks[0].clips.map(\.timeline) == [
            TimeRange(start: s(0), duration: s(4)), TimeRange(start: s(4), duration: s(3)), TimeRange(start: s(7), duration: s(6))])
        #expect(tl.tracks[1].clips.map(\.timeline) == [
            TimeRange(start: s(2), duration: s(2)), TimeRange(start: s(7), duration: s(4))])
        #expect(starts(tl.tracks[2]) == [s(3)])
        #expect(tl.tracks[1].clips[1].source.start == s(2))
    }
}

@Suite struct SoloVideoClipTests {
    @Test func hidesOtherVideoTracksAndKeepsAudio() throws {
        let a = clip(0, 2)
        let v1 = try track([a])
        let v2 = try track([clip(0, 2)])
        let a1 = try track([clip(0, 2, kind: .audio)], kind: .audio)
        let tl = timeline(v1, v2, a1).soloingVideoClip(a.id)
        #expect(tl.tracks[0].isVisible)
        #expect(!tl.tracks[1].isVisible)
        #expect(tl.tracks[2].isVisible)
        #expect(tl.tracks[0].clips == v1.clips)
    }

    @Test func unknownIdChangesNothing() throws {
        let tl = timeline(try track([clip(0, 2)]))
        #expect(tl.soloingVideoClip(UUID()) == tl)
    }
}
