import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private let frame = Time(1, 30)

/// Talking head: linked V1/A1 over 0-10 s from one medium.
private func talkingHead(_ start: Int64 = 0, _ dur: Int64 = 10) -> (Clip, Clip) {
    let m = UUID(), link = UUID()
    let v = Clip(name: "v", media: m, kind: .video, source: TimeRange(start: .zero, duration: s(dur)), start: s(start), link: link)
    let a = Clip(name: "a", media: m, kind: .audio, source: TimeRange(start: .zero, duration: s(dur)), start: s(start), link: link)
    return (v, a)
}

private func clip(_ kind: TrackKind, _ start: Int64, _ dur: Int64, _ name: String = "x") -> Clip {
    Clip(name: name, media: UUID(), kind: kind,
         source: TimeRange(start: .zero, duration: s(dur)), start: s(start))
}

private func track(_ kind: TrackKind, _ clips: [Clip], syncLock: Bool = true, locked: Bool = false) throws -> Track {
    var t = Track(kind: kind, syncLock: syncLock)
    for c in clips { try t.overwrite(c) }
    t.isLocked = locked
    return t
}

private func r(_ a: Int64, _ d: Int64) -> TimeRange { TimeRange(start: s(a), duration: s(d)) }

@Suite struct SilenceRippleTests {
    @Test func linkedPiecesStayPairedAndInSync() throws {
        let (v, a) = talkingHead()
        var tl = Timeline(name: "t", frameDuration: frame, tracks: [try track(.video, [v]), try track(.audio, [a])])
        let removed = try tl.removeSilences([r(2, 1), r(6, 2)], around: [a.id])
        #expect(removed == s(3))
        let vs = tl.tracks[0].clips, as_ = tl.tracks[1].clips
        #expect(vs.count == 3 && as_.count == 3)
        #expect(vs.map(\.start) == as_.map(\.start))
        #expect(vs.map(\.source) == as_.map(\.source))
        #expect(as_.map(\.source.start) == [.zero, s(3), s(8)])
        // Each picture piece is linked to the sound piece at the same place, and only to it.
        for (pv, pa) in zip(vs, as_) { #expect(pv.link != nil && pv.link == pa.link) }
        #expect(Set(vs.compactMap(\.link)).count == 3)
    }

    @Test func otherSyncLockedTracksAreCutThrough() throws {
        let (v, a) = talkingHead()
        let music = clip(.audio, 0, 12, "music")
        let broll = clip(.video, 7, 2, "broll")       // spans the second cut (6-8)
        let late = clip(.video, 10, 2, "late")        // after both cuts
        var tl = Timeline(name: "t", frameDuration: frame, tracks: [
            try track(.video, [v]), try track(.video, [broll, late]), try track(.audio, [a]), try track(.audio, [music]),
        ])
        try tl.removeSilences([r(2, 1), r(6, 2)], around: [a.id])
        // Music loses exactly the cut ranges and ends 3 s earlier: it stays under the same words.
        let mus = tl.tracks[3].clips
        #expect(mus.map(\.source.start) == [.zero, s(3), s(8)])
        #expect(tl.tracks[3].end == s(9))
        // B-roll lost its part inside the cut (7-8) and now starts where the cut was.
        let v2 = tl.tracks[1].clips
        #expect(v2.first { $0.name == "broll" }!.start == s(5) && v2.first { $0.name == "broll" }!.duration == s(1))
        #expect(v2.first { $0.name == "late" }!.start == s(7))
        #expect(tl.tracks[0].end == s(7) && tl.tracks[2].end == s(7))
    }

    @Test func trackWithoutSyncLockIsUntouched() throws {
        let (v, a) = talkingHead()
        let free = clip(.audio, 0, 12, "free")
        var tl = Timeline(name: "t", frameDuration: frame, tracks: [try track(.video, [v]), try track(.audio, [a]),
                                                                   try track(.audio, [free], syncLock: false)])
        let before = tl.tracks[2]
        try tl.removeSilences([r(2, 1)], around: [a.id])
        #expect(tl.tracks[2] == before)
        #expect(tl.tracks[1].end == s(9))
    }

    @Test func linkedPartnerOnTrackWithoutSyncLockIsStillCut() throws {
        let (v, a) = talkingHead()
        var tl = Timeline(name: "t", frameDuration: frame, tracks: [try track(.video, [v], syncLock: false), try track(.audio, [a])])
        try tl.removeSilences([r(2, 1)], around: [a.id])
        #expect(tl.tracks[0].end == s(9) && tl.tracks[1].end == s(9))
        #expect(tl.tracks[0].clips.map(\.start) == tl.tracks[1].clips.map(\.start))
    }

    /// B-roll on a sync-locked V2 linked to its own sound on A3 (sync lock off).
    private func brollTimeline(brollAt start: Int64, a3Locked: Bool = false, extra: [Clip] = []) throws -> (Timeline, Clip) {
        let (v, a) = talkingHead()
        let m = UUID(), link = UUID()
        let bv = Clip(name: "bv", media: m, kind: .video, source: TimeRange(start: .zero, duration: s(3)), start: s(start), link: link)
        let ba = Clip(name: "ba", media: m, kind: .audio, source: TimeRange(start: .zero, duration: s(3)), start: s(start), link: link)
        let tl = Timeline(name: "t", frameDuration: frame, tracks: [
            try track(.video, [v]), try track(.video, [bv]), try track(.audio, [a]),
            try track(.audio, [ba] + extra, syncLock: false, locked: a3Locked),
        ])
        return (tl, a)
    }

    @Test func brollPartnerOnTrackWithoutSyncLockIsCutWithIt() throws {
        var (tl, a) = try brollTimeline(brollAt: 2)        // B-roll 2-5 runs over the 1 s cut at 3-4
        try tl.removeSilences([r(3, 1)], around: [a.id])
        let bv = tl.tracks[1].clips, ba = tl.tracks[3].clips
        #expect(bv.count == 2 && ba.count == 2)
        #expect(bv.map(\.start) == ba.map(\.start) && bv.map(\.source) == ba.map(\.source))
        for (pv, pa) in zip(bv, ba) { #expect(pv.link != nil && pv.link == pa.link) }
        #expect(tl.tracks[3].end == s(4))
    }

    @Test func brollPartnerAfterACutMovesWithIt() throws {
        var (tl, a) = try brollTimeline(brollAt: 5)        // B-roll 5-8, wholly after the cut at 3-4
        try tl.removeSilences([r(3, 1)], around: [a.id])
        #expect(tl.tracks[1].clips[0].start == s(4) && tl.tracks[3].clips[0].start == s(4))
    }

    @Test func unrelatedTrackWithoutSyncLockStaysWhenItsPartnerIsBeforeTheCuts() throws {
        var (tl, a) = try brollTimeline(brollAt: 0, extra: [clip(.audio, 6, 2, "free")])   // B-roll 0-3, cut 4-5
        let before = tl.tracks[3]
        try tl.removeSilences([r(4, 1)], around: [a.id])
        #expect(tl.tracks[3] == before)
    }

    @Test func brollPartnerOnLockedTrackRefuses() throws {
        var (tl, a) = try brollTimeline(brollAt: 2, a3Locked: true)
        let before = tl
        #expect(throws: EditError.trackLocked) { try tl.removeSilences([r(3, 1)], around: [a.id]) }
        #expect(tl == before)
    }

    @Test func lockedOtherTrackStaysAndSourceTrackLockedRefuses() throws {
        let (v, a) = talkingHead()
        let music = clip(.audio, 0, 12, "music")
        var tl = Timeline(name: "t", frameDuration: frame, tracks: [try track(.video, [v]), try track(.audio, [a]),
                                                                   try track(.audio, [music], locked: true)])
        try tl.removeSilences([r(2, 1)], around: [a.id])
        #expect(tl.tracks[2].clips == [music])

        var locked = Timeline(name: "t", frameDuration: frame, tracks: [try track(.video, [v]), try track(.audio, [a], locked: true)])
        let before = locked
        #expect(throws: EditError.self) { try locked.removeSilences([r(2, 1)], around: [a.id]) }
        #expect(locked == before)
    }

    @Test func edgeRangesAtStartAndEnd() throws {
        let (v, a) = talkingHead()
        var tl = Timeline(name: "t", frameDuration: frame, tracks: [try track(.video, [v]), try track(.audio, [a])])
        // Leading pause, trailing pause, and a range past the end of everything.
        let removed = try tl.removeSilences([r(0, 1), r(9, 1), r(20, 5)], around: [a.id])
        #expect(removed == s(2))   // the range past the end of all content removes nothing
        for t in tl.tracks {
            #expect(t.clips.count == 1)
            #expect(t.clips[0].start == .zero && t.clips[0].source == r(1, 8))
        }
    }

    @Test func cutsAreSortedMergedAndClampedToZero() {
        let n = SilenceRemoval.normalized([r(6, 2), TimeRange(start: s(-1), duration: s(2)), r(7, 2), r(3, 0)])
        #expect(n == [r(0, 1), r(6, 3)])
    }

    @Test func unsortedOverlappingCutsRemoveTheirUnion() throws {
        let (v, a) = talkingHead()
        var tl = Timeline(name: "t", frameDuration: frame, tracks: [try track(.video, [v]), try track(.audio, [a])])
        let removed = try tl.removeSilences([r(6, 2), r(2, 1), r(7, 2)], around: [a.id])
        #expect(removed == s(4))
        #expect(tl.tracks[1].clips.map(\.source.start) == [.zero, s(3), s(9)])
        #expect(tl.tracks[0].end == s(6))
    }

    @Test func nothingToCutIsANoOp() throws {
        let (v, a) = talkingHead()
        var tl = Timeline(name: "t", frameDuration: frame, tracks: [try track(.video, [v]), try track(.audio, [a])])
        let before = tl
        #expect(try tl.removeSilences([], around: [a.id]) == .zero)
        #expect(tl == before)
    }

    @Test func markersAfterACutMoveWithTheContent() throws {
        let (v, a) = talkingHead()
        var tl = Timeline(name: "t", frameDuration: frame, tracks: [try track(.video, [v]), try track(.audio, [a])])
        let early = tl.addMarker(at: s(1)), late = tl.addMarker(at: s(8))
        try tl.removeSilences([r(2, 1), r(5, 1)], around: [a.id])
        #expect(tl.markers.first { $0.id == early }!.time == s(1))
        #expect(tl.markers.first { $0.id == late }!.time == s(6))
    }
}
