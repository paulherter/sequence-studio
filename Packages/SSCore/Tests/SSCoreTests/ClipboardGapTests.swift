import Foundation
import Testing
@testable import SSCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func clip(_ start: Int64, _ dur: Int64, kind: TrackKind = .video, link: UUID? = nil) -> Clip {
    Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: s(0), duration: s(dur)), start: s(start), link: link)
}
private func track(_ clips: [Clip], kind: TrackKind = .video, targeted: Bool = false) -> Track {
    var t = Track(kind: kind, isTargeted: targeted)
    for c in clips { try! t.overwrite(c) }
    return t
}
private func timeline(_ tracks: [Track]) -> Timeline { Timeline(name: "t", frameDuration: Time(1, 30), tracks: tracks) }
private func starts(_ t: Track) -> [Int64] { t.clips.map { $0.start.value / $0.start.timescale } }

@Suite struct ClipboardTests {
    @Test func copyIsRelativeAndLaneBased() {
        let a = clip(10, 5), b = clip(20, 5)
        let tl = timeline([track([a]), track([b]), track([], kind: .audio)])
        let cb = tl.clipboard(copying: [a.id, b.id])!
        #expect(cb.entries.map(\.offset) == [s(0), s(10)])
        #expect(cb.entries.map(\.lane) == [0, 1])
        #expect(cb.duration == s(15))
    }

    @Test func pasteOverwritesAtPlayheadOnOriginalLaneAndGivesNewIDs() throws {
        let a = clip(0, 10)
        var tl = timeline([track([a])])
        let cb = tl.clipboard(copying: [a.id])!
        let ids = try tl.paste(cb, at: s(20))
        #expect(starts(tl.tracks[0]) == [0, 20])
        #expect(ids.count == 1 && ids[0] != a.id)
    }

    @Test func pasteLandsOnTargetedTrack() throws {
        let a = clip(0, 10)
        var tl = timeline([track([a]), track([], targeted: true)])
        let cb = tl.clipboard(copying: [a.id])!
        try tl.paste(cb, at: s(5))
        #expect(starts(tl.tracks[0]) == [0])
        #expect(starts(tl.tracks[1]) == [5])
    }

    @Test func pasteOverwritesCoveredClips() throws {
        let a = clip(0, 10), b = clip(20, 10)
        var tl = timeline([track([a, b])])
        let cb = tl.clipboard(copying: [a.id])!
        try tl.paste(cb, at: s(25))
        #expect(starts(tl.tracks[0]) == [0, 20, 25])
        #expect(tl.tracks[0].clips[1].timeline.duration == s(5))
    }

    @Test func insertPasteRipplesLaterClips() throws {
        let a = clip(0, 10), b = clip(10, 10)
        var tl = timeline([track([a, b])])
        let cb = tl.clipboard(copying: [a.id])!
        try tl.paste(cb, at: s(10), insert: true)
        #expect(starts(tl.tracks[0]) == [0, 10, 20])
    }

    @Test func linkedPairKeepsAFreshLinkAndLoneClipsLoseIt() throws {
        let l = UUID()
        let v = clip(0, 10, link: l), a = clip(0, 10, kind: .audio, link: l)
        var tl = timeline([track([v]), track([a], kind: .audio)])
        let both = tl.clipboard(copying: [v.id, a.id])!
        try tl.paste(both, at: s(20))
        let nv = tl.tracks[0].clips[1], na = tl.tracks[1].clips[1]
        #expect(nv.link != nil && nv.link == na.link && nv.link != l)
        let lone = tl.clipboard(copying: [v.id])!
        try tl.paste(lone, at: s(40))
        #expect(tl.tracks[0].clips[2].link == nil)
    }

    @Test func pasteIntoLockedTrackIsRefusedAndMissingLaneThrows() throws {
        let a = clip(0, 10)
        var locked = track([a]); locked.isLocked = true
        var tl = timeline([locked])
        let cb = tl.clipboard(copying: [a.id])!
        #expect(throws: EditError.trackLocked) { try tl.paste(cb, at: s(20)) }
        #expect(throws: EditError.clipNotFound) { try tl.paste(cb, at: s(20), lanes: [.video: 3]) }
    }
}

@Suite struct GapTests {
    @Test func gapIsBetweenNeighboursAndNilAfterTheLastClip() {
        let a = clip(0, 10), b = clip(30, 10)
        let tl = timeline([track([a, b])])
        let id = tl.tracks[0].id
        #expect(tl.gap(on: id, at: s(15)) == TimeRange(start: s(10), end: s(30)))
        #expect(tl.gap(on: id, at: s(5)) == nil)
        #expect(tl.gap(on: id, at: s(45)) == nil)
    }

    @Test func gapBeforeTheFirstClipStartsAtZero() {
        let tl = timeline([track([clip(8, 4)])])
        #expect(tl.gap(on: tl.tracks[0].id, at: s(2)) == TimeRange(start: .zero, end: s(8)))
    }

    @Test func closeGapShiftsTheTrackAndSyncLockedTracks() throws {
        let a = clip(0, 10), b = clip(30, 10), x = clip(30, 5, kind: .audio)
        var tl = timeline([track([a, b]), track([x], kind: .audio)])
        let closed = try tl.closeGap(on: tl.tracks[0].id, at: s(15))
        #expect(closed == s(20))
        #expect(starts(tl.tracks[0]) == [0, 10])
        #expect(starts(tl.tracks[1]) == [10])
    }

    @Test func closeGapStopsWhereASyncLockedTrackWouldCollide() throws {
        let a = clip(0, 10), b = clip(30, 10), x = clip(0, 25, kind: .audio), y = clip(30, 5, kind: .audio)
        var tl = timeline([track([a, b]), track([x, y], kind: .audio)])
        let closed = try tl.closeGap(on: tl.tracks[0].id, at: s(15))
        #expect(closed == s(5))
        #expect(starts(tl.tracks[0]) == [0, 25])
    }
}

@Suite struct LinkAndNudgeTests {
    @Test func linkAndUnlink() throws {
        let v = clip(0, 10), a = clip(0, 10, kind: .audio)
        var tl = timeline([track([v]), track([a], kind: .audio)])
        try tl.link([v.id, a.id])
        #expect(tl.tracks[0].clips[0].link != nil && tl.tracks[0].clips[0].link == tl.tracks[1].clips[0].link)
        try tl.unlink([a.id])
        #expect(tl.tracks[1].clips[0].link == nil && tl.tracks[0].clips[0].link == nil)
        #expect(throws: EditError.clipNotFound) { try tl.link([v.id]) }
    }

    @Test func nudgeMovesGroupAndClampsAtZero() throws {
        let l = UUID()
        let v = clip(2, 10, link: l), a = clip(2, 10, kind: .audio, link: l)
        var tl = timeline([track([v]), track([a], kind: .audio)])
        #expect(try tl.nudge([v.id], by: s(3)) == s(3))
        #expect(starts(tl.tracks[0]) == [5] && starts(tl.tracks[1]) == [5])
        #expect(try tl.nudge([v.id], by: s(-9)) == s(-5))
        #expect(starts(tl.tracks[0]) == [0])
    }

    @Test func nudgeOverlappingItsOwnSelectionKeepsAllClips() throws {
        let a = clip(0, 10), b = clip(10, 10)
        var tl = timeline([track([a, b])])
        try tl.nudge([a.id, b.id], by: s(1))
        #expect(starts(tl.tracks[0]) == [1, 11])
        #expect(tl.tracks[0].clips.allSatisfy { $0.timeline.duration == s(10) })
    }

    @Test func copyMoveKeepsOriginalsAndOverwritesDestination() throws {
        let l = UUID()
        let v = clip(0, 10, link: l), a = clip(0, 10, kind: .audio, link: l)
        var tl = timeline([track([v]), track([a], kind: .audio)])
        let spec = CopySpec(ids: [v.id: UUID()], link: UUID())
        try tl.move(v.id, to: s(20), copy: spec)
        #expect(starts(tl.tracks[0]) == [0, 20] && starts(tl.tracks[1]) == [0, 20])
        #expect(tl.tracks[0].clips[1].id == spec.ids[v.id])
        #expect(tl.tracks[0].clips[1].link == spec.link && tl.tracks[1].clips[1].link == spec.link)
        #expect(tl.tracks[0].clips[0].link == l)
    }

    @Test func copyMoveOverlappingItselfCutsTheOriginal() throws {
        let v = clip(0, 10)
        var tl = timeline([track([v])])
        try tl.move(v.id, to: s(4), copy: CopySpec())
        #expect(starts(tl.tracks[0]) == [0, 4])
        #expect(tl.tracks[0].clips[0].timeline.duration == s(4))
    }
}
