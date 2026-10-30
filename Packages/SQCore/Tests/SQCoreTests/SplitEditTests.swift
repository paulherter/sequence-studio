import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func clip(_ start: Int64, _ dur: Int64, kind: TrackKind, link: UUID? = nil, src: Int64 = 5) -> Clip {
    Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: s(src), duration: s(dur)), start: s(start), link: link)
}
private func track(_ clips: [Clip], kind: TrackKind) throws -> Track {
    var t = Track(kind: kind)
    for c in clips { try t.overwrite(c) }
    return t
}

/// V1 and A1 both cut at 10 s (video 0-10 | 10-20, audio the same), linked per side.
private func fixture() throws -> Timeline {
    let l1 = UUID(), l2 = UUID()
    return Timeline(name: "t", frameDuration: Time(1, 30), tracks: [
        try track([clip(0, 10, kind: .video, link: l1), clip(10, 10, kind: .video, link: l2)], kind: .video),
        try track([clip(0, 10, kind: .audio, link: l1), clip(10, 10, kind: .audio, link: l2)], kind: .audio),
    ])
}

@Suite struct SplitEditTests {
    @Test func audioLeadsTheCutAndVideoStaysPut() throws {
        var tl = try fixture()
        let moved = try tl.splitEdit(cut: s(10), side: .audio, to: s(8))
        #expect(moved == s(-2))
        #expect(tl.tracks[0].clips.map(\.start) == [s(0), s(10)])
        #expect(tl.tracks[0].clips.map(\.duration) == [s(10), s(10)])
        #expect(tl.tracks[1].clips.map(\.start) == [s(0), s(8)])
        #expect(tl.tracks[1].clips.map(\.duration) == [s(8), s(12)])
        // Source follows the head: the later clip starts 2 s earlier in the media.
        #expect(tl.tracks[1].clips[1].source.start == s(3))
        #expect(tl.tracks[1].clips.allSatisfy { $0.link != nil })
    }

    @Test func audioTrailsTheCut() throws {
        var tl = try fixture()
        try tl.splitEdit(cut: s(10), side: .audio, to: s(12))
        #expect(tl.tracks[1].clips.map(\.start) == [s(0), s(12)])
        #expect(tl.tracks[1].clips[0].duration == s(12))
        #expect(tl.tracks[0].clips.map(\.start) == [s(0), s(10)])
    }

    @Test func videoSideMovesOnlyVideo() throws {
        var tl = try fixture()
        try tl.splitEdit(cut: s(10), side: .video, to: s(11))
        #expect(tl.tracks[0].clips.map(\.start) == [s(0), s(11)])
        #expect(tl.tracks[1].clips.map(\.start) == [s(0), s(10)])
    }

    @Test func sequenceLengthAndConsistencyHold() throws {
        var tl = try fixture()
        let before = tl.tracks.map { $0.clips.last!.timeline.end }
        try tl.splitEdit(cut: s(10), side: .audio, to: s(7))
        #expect(tl.tracks.map { $0.clips.last!.timeline.end } == before)
        #expect(tl.tracks.allSatisfy { $0.isConsistent })
    }

    @Test func clampedByTheMediaHandle() throws {
        var tl = try fixture()                      // later clip has 5 s of head media
        let moved = try tl.splitEdit(cut: s(10), side: .audio, to: s(2))
        #expect(moved == s(-5))
        #expect(tl.tracks[1].clips[1].start == s(5))
    }

    @Test func clampedKeepsAFrameOnTheOtherSide() throws {
        var tl = try fixture()
        let moved = try tl.splitEdit(cut: s(10), side: .audio, to: s(30))
        #expect(moved < s(10))
        #expect(tl.tracks[1].clips[1].duration >= tl.frameDuration)
    }

    @Test func noCutOnThatSideThrowsAndChangesNothing() throws {
        var tl = try fixture()
        let before = tl
        #expect(throws: EditError.self) { try tl.splitEdit(cut: s(5), side: .audio, to: s(6)) }
        #expect(tl.tracks.map(\.clips) == before.tracks.map(\.clips))
    }

    @Test func lockedTrackRefuses() throws {
        var tl = try fixture()
        tl.tracks[1].isLocked = true
        #expect(throws: EditError.trackLocked) { try tl.splitEdit(cut: s(10), side: .audio, to: s(8)) }
    }

    @Test func nearestCutPicksTheClosestOnTheSide() throws {
        let tl = try fixture()
        #expect(tl.nearestCut(to: s(9), side: .audio) == s(10))
        #expect(tl.nearestCut(to: s(3), side: .video) == s(10))
        #expect(tl.nearestCut(to: s(3), side: .audio, tracks: [tl.tracks[0].id]) == nil)
    }
}
