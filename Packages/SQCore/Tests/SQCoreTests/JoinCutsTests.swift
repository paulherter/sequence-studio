import Foundation
import Testing
@testable import SQCore

// Join Cuts: the leftover of a blade (a through edit) goes back into one clip.

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func clip(_ media: UUID, _ start: Int64, _ dur: Int64, src: Int64, kind: TrackKind = .video, link: UUID? = nil) -> Clip {
    Clip(name: "c", media: media, kind: kind, source: TimeRange(start: s(src), duration: s(dur)),
         start: s(start), link: link, mediaDuration: s(1000))
}
private func timeline(_ tracks: [Track]) -> Timeline { Timeline(name: "t", frameDuration: Time(1, 30), tracks: tracks) }
private func track(_ clips: [Clip], kind: TrackKind = .video) -> Track {
    var t = Track(kind: kind)
    for c in clips { try! t.overwrite(c) }
    return t
}

private extension Timeline {
    /// Blade on every track at `t`, like Cmd+K (one shared relink map).
    mutating func split(at t: Time) throws {
        var relinks: [UUID: UUID] = [:]
        for i in tracks.indices { try tracks[i].split(at: t, relinks: &relinks) }
    }
}

@Suite struct JoinCutsTests {
    @Test func joinsContiguousHalvesOfOneClip() throws {
        let m = UUID()
        var t = timeline([track([clip(m, 0, 20, src: 5)])])
        let original = t
        try t.split(at: s(8))
        #expect(t.throughEdits().count == 1)
        #expect(try t.joinThroughEdits() == 1)
        #expect(t.tracks[0].clips.count == 1)
        #expect(t.tracks[0].clips[0] == original.tracks[0].clips[0])
    }

    @Test func refusesNonContiguousSource() throws {
        let m = UUID()
        var t = timeline([track([clip(m, 0, 10, src: 0), clip(m, 10, 10, src: 50)])])
        let before = t
        #expect(try t.joinThroughEdits() == 0)
        #expect(t == before)
    }

    @Test func refusesGapAndOtherMedia() throws {
        var t = timeline([track([clip(UUID(), 0, 10, src: 0), clip(UUID(), 10, 10, src: 10)])])
        #expect(try t.joinThroughEdits() == 0)
        let m = UUID()
        var g = timeline([track([clip(m, 0, 10, src: 0), clip(m, 12, 10, src: 10)])])
        #expect(try g.joinThroughEdits() == 0)
    }

    @Test func refusesDifferentSpeedOrEffects() throws {
        let m = UUID()
        var t = timeline([track([clip(m, 0, 20, src: 0)])])
        try t.split(at: s(10))
        var slow = t
        var c = slow.tracks[0].clips[1]; c.speed = ClipSpeed(percent: 50)
        slow.tracks[0].replace(c)
        #expect(try slow.joinThroughEdits() == 0)
        var fx = t
        var d = fx.tracks[0].clips[1]; d.audioGainDB = 3
        fx.tracks[0].replace(d)
        #expect(try fx.joinThroughEdits() == 0)
    }

    @Test func keyframesStayIdenticalAfterSplitAndJoin() throws {
        let m = UUID()
        var c = clip(m, 0, 20, src: 0)
        c.animation.opacity.track = KeyframeTrack(keys: [
            Keyframe(time: .zero, value: 0.0, interpolation: .linear),
            Keyframe(time: s(15), value: 1.0, interpolation: .linear),
        ])
        var t = timeline([track([c])])
        let original = t
        try t.split(at: s(7))
        #expect(try t.joinThroughEdits() == 1)
        #expect(t.tracks[0].clips[0].animation == original.tracks[0].clips[0].animation)
    }

    @Test func linkedPairJoinsBoth() throws {
        let m = UUID(), l = UUID()
        var t = timeline([track([clip(m, 0, 20, src: 0, link: l)]), track([clip(m, 0, 20, src: 0, kind: .audio, link: l)], kind: .audio)])
        let original = t
        try t.split(at: s(9))
        #expect(try t.joinThroughEdits(selection: [t.tracks[0].clips[0].id]) == 2)
        #expect(t.tracks[0].clips.count == 1 && t.tracks[1].clips.count == 1)
        #expect(t.tracks[0].clips[0].link == t.tracks[1].clips[0].link)
        #expect(t == original)
    }

    @Test func linkedPairRefusesWhenPartnerDiffers() throws {
        let m = UUID(), l = UUID()
        var t = timeline([track([clip(m, 0, 20, src: 0, link: l)]), track([clip(m, 0, 20, src: 0, kind: .audio, link: l)], kind: .audio)])
        try t.split(at: s(9))
        var a = t.tracks[1].clips[1]; a.audioGainDB = 6
        t.tracks[1].replace(a)
        let before = t
        #expect(try t.joinThroughEdits() == 0)
        #expect(t == before)
    }

    @Test func selectionLimitsTheScopeAndChainsJoin() throws {
        let m = UUID()
        var t = timeline([track([clip(m, 0, 30, src: 0)])])
        try t.split(at: s(10)); try t.split(at: s(20))
        #expect(t.throughEdits().count == 2)
        #expect(try t.joinThroughEdits(selection: [UUID()]) == 0)   // nothing selected there
        #expect(try t.joinThroughEdits(selection: [t.tracks[0].clips[0].id]) == 2)   // the selected clip absorbs its neighbors
        #expect(t.tracks[0].clips.count == 1)
        #expect(t.tracks[0].clips[0].source.duration == s(30))
    }

    @Test func lockedTrackIsLeftAlone() throws {
        let m = UUID()
        var t = timeline([track([clip(m, 0, 20, src: 0)])])
        try t.split(at: s(5))
        t.tracks[0].isLocked = true
        #expect(try t.joinThroughEdits() == 0)
    }

    @Test func transitionOnTheCutRefusesAndTailTransitionMoves() throws {
        let m = UUID(), n = UUID()
        var t = timeline([track([clip(m, 0, 20, src: 0), clip(n, 20, 10, src: 0)])])
        try t.split(at: s(8))
        let (a, b, c) = (t.tracks[0].clips[0].id, t.tracks[0].clips[1].id, t.tracks[0].clips[2].id)
        var between = t
        between.tracks[0].transitions = [Transition(kind: .crossDissolve, duration: s(1), outgoing: a, incoming: b)]
        #expect(try between.joinThroughEdits() == 0)
        t.tracks[0].transitions = [Transition(kind: .crossDissolve, duration: s(1), outgoing: b, incoming: c)]
        #expect(try t.joinThroughEdits() == 1)
        #expect(t.tracks[0].transitions[0].outgoing == a)
    }

    // MARK: Follow-ups

    @Test func reversedHalvesJoinBackToOneReversedClip() throws {
        let m = UUID()
        var c = clip(m, 0, 20, src: 5); c.reversed = true
        var t = timeline([track([c])])
        let original = t
        try t.split(at: s(8))
        #expect(t.tracks[0].clips.count == 2)
        #expect(try t.joinThroughEdits() == 1)
        #expect(t == original)
    }

    @Test func reversedHalvesInWrongSourceOrderStay() throws {
        let m = UUID()
        var a = clip(m, 0, 10, src: 0); a.reversed = true
        var b = clip(m, 10, 10, src: 10); b.reversed = true   // plays forward in source order: a real edit when reversed
        var t = timeline([track([a, b])])
        #expect(try t.joinThroughEdits() == 0)
    }

    @Test func sameSpeedRetimedHalvesJoin() throws {
        let m = UUID()
        var c = clip(m, 0, 20, src: 0); c.speed = ClipSpeed(percent: 50)
        var t = timeline([track([c])])
        let original = t
        try t.split(at: s(8))
        #expect(t.tracks[0].clips.count == 2)
        #expect(try t.joinThroughEdits() == 1)
        #expect(t == original)
    }

    @Test func clipMarkersSurviveSplitAndJoin() throws {
        let m = UUID()
        var c = clip(m, 0, 20, src: 5)
        c.markers = [Marker(time: s(7), name: "a"), Marker(time: s(18), name: "b")]
        var t = timeline([track([c])])
        let original = t
        try t.split(at: s(8))
        #expect(try t.joinThroughEdits() == 1)
        #expect(t.tracks[0].clips[0].markers == original.tracks[0].clips[0].markers)
    }

    @Test func differingClipMarkersKeepTheCut() throws {
        let m = UUID()
        var t = timeline([track([clip(m, 0, 20, src: 0)])])
        try t.split(at: s(10))
        var r = t.tracks[0].clips[1]; r.markers = [Marker(time: s(15), name: "only right")]
        t.tracks[0].replace(r)
        // The right half owns a marker the left does not: the halves differ, so the cut stays.
        #expect(try t.joinThroughEdits() == 0)
        #expect(t.tracks[0].clips.count == 2)
        #expect(t.tracks[0].clips.flatMap { $0.markers ?? [] }.map(\.name).contains("only right"))
    }

    @Test func disabledHalvesJoinAndMixedEnabledStateStays() throws {
        let m = UUID()
        var c = clip(m, 0, 20, src: 0); c.isEnabled = false
        var t = timeline([track([c])])
        let original = t
        try t.split(at: s(8))
        #expect(try t.joinThroughEdits() == 1)
        #expect(t == original)

        var u = timeline([track([clip(m, 0, 20, src: 0)])])
        try u.split(at: s(8))
        var r = u.tracks[0].clips[1]; r.isEnabled = false
        u.tracks[0].replace(r)
        #expect(try u.joinThroughEdits() == 0)
    }

    @Test func selectingOnlyTheRightClipJoinsTheCut() throws {
        let m = UUID()
        var t = timeline([track([clip(m, 0, 20, src: 0)])])
        try t.split(at: s(8))
        #expect(try t.joinThroughEdits(selection: [t.tracks[0].clips[1].id]) == 1)
        #expect(t.tracks[0].clips.count == 1)
    }

    @Test func selectingOnlyOnePartnerJoinsBothLinkedTracks() throws {
        let m = UUID(), l = UUID()
        var t = timeline([track([clip(m, 0, 20, src: 0, link: l)]), track([clip(m, 0, 20, src: 0, kind: .audio, link: l)], kind: .audio)])
        try t.split(at: s(9))
        // Only the audio right half is selected (Linked Selection off): its video partner still joins.
        #expect(try t.joinThroughEdits(selection: [t.tracks[1].clips[1].id]) == 2)
        #expect(t.tracks[0].clips.count == 1 && t.tracks[1].clips.count == 1)
    }
}
