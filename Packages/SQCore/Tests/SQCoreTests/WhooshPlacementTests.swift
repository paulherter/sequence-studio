import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func clip(_ start: Int64, _ dur: Int64, kind: TrackKind) -> Clip {
    Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: .zero, duration: s(dur)), start: s(start))
}
private func track(_ clips: [Clip], kind: TrackKind) throws -> Track {
    var t = Track(kind: kind)
    for c in clips { try t.overwrite(c) }
    return t
}
private func sfx(_ dur: Int64) -> Clip { clip(0, dur, kind: .audio) }

@Suite struct WhooshPlacementTests {
    @Test func centresOnEachCutOnAFreeTrack() throws {
        var tl = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [
            try track([clip(0, 10, kind: .video), clip(10, 10, kind: .video)], kind: .video),
            try track([clip(0, 20, kind: .audio)], kind: .audio),
        ])
        let ids = try tl.placeCentred(sfx(2), onCuts: [s(10)])
        #expect(ids.count == 1)
        #expect(tl.tracks.count == 3)                       // A1 is busy: a new audio track
        let c = tl.tracks[2].clips[0]
        #expect(c.start == s(9) && c.duration == s(2))
        #expect(c.link == nil)
    }

    @Test func reusesAFreeTrackAndPacksSeveralCuts() throws {
        var tl = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [
            try track([clip(0, 30, kind: .audio)], kind: .audio),
            try track([], kind: .audio),
        ])
        let ids = try tl.placeCentred(sfx(2), onCuts: [s(10), s(20)])
        #expect(ids.count == 2)
        #expect(tl.tracks.count == 2)
        #expect(tl.tracks[1].clips.map(\.start) == [s(9), s(19)])
    }

    @Test func closeCutsSpillToASecondTrack() throws {
        var tl = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [try track([], kind: .audio)])
        try tl.placeCentred(sfx(4), onCuts: [s(10), s(11)])
        #expect(tl.tracks.count == 2)
        #expect(tl.tracks.allSatisfy { $0.isConsistent })
    }

    @Test func clampsToTheSequenceStart() throws {
        var tl = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [try track([], kind: .audio)])
        try tl.placeCentred(sfx(4), onCuts: [s(1)])
        #expect(tl.tracks[0].clips[0].start == .zero)
    }

    @Test func skipsLockedTracksAndNeverTouchesVideo() throws {
        var locked = try track([], kind: .audio); locked.isLocked = true
        var tl = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [try track([], kind: .video), locked])
        try tl.placeCentred(sfx(2), onCuts: [s(5)])
        #expect(tl.tracks[0].clips.isEmpty && tl.tracks[1].clips.isEmpty)
        #expect(tl.tracks[2].clips.count == 1)
    }

    @Test func videoClipOrNoCutsIsRefused() throws {
        var tl = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [try track([], kind: .audio)])
        #expect(throws: EditError.self) { try tl.placeCentred(clip(0, 2, kind: .video), onCuts: [s(5)]) }
        #expect(throws: EditError.self) { try tl.placeCentred(sfx(2), onCuts: []) }
    }

    @Test func cutsOfSelectedClipsFindsTouchingPairs() throws {
        let a = clip(0, 10, kind: .video), b = clip(10, 10, kind: .video), c = clip(25, 5, kind: .video)
        let tl = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [try track([a, b, c], kind: .video)])
        #expect(tl.cuts(ofClips: [a.id]) == [s(10)])
        #expect(tl.cuts(ofClips: [a.id, b.id]) == [s(10)])
        #expect(tl.cuts(ofClips: [c.id]) == [])
    }
}
