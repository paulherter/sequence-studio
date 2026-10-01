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
