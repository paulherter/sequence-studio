import Foundation
import Testing
import SQCore
@testable import SQEditorSession

private let fd = Time(1, 30)
private func s(_ n: Int64) -> Time { Time(n, 1) }
private func clip(_ start: Int64, _ dur: Int64, kind: TrackKind = .video, src: Int64 = 0) -> Clip {
    Clip(name: "c\(start)", media: UUID(), kind: kind, source: TimeRange(start: s(src), duration: s(dur)), start: s(start))
}
private func track(_ clips: [Clip], kind: TrackKind = .video) -> Track {
    var t = Track(kind: kind)
    for c in clips { try! t.overwrite(c) }
    return t
}
@MainActor private func makeSession(_ tracks: [Track]) -> EditorSession {
    let t = Timeline(name: "Main", frameDuration: fd, tracks: tracks)
    let ses = EditorSession(project: Project(name: "P", timelines: [t]), engine: StubProgramEngine())
    ses.setSelectionFollowsPlayhead(false)
    return ses
}

/// Q / W and the Shift / Option variants (trim to playhead), Slide and Slip keyboard verbs at session level.
@MainActor @Suite struct PlayheadTrimSessionTests {
    @Test func plainTrimSkipsHiddenAndLockedTracks() {
        var hidden = track([clip(0, 10)]); hidden.isVisible = false
        var locked = track([clip(0, 10)]); locked.isLocked = true
        let ses = makeSession([track([clip(0, 10)]), hidden, locked])
        ses.seek(to: s(5))
        ses.trimToPlayhead(.tail, mode: .plain)
        let t = ses.activeTimeline!
        #expect(t.tracks[0].clips[0].timeline.end == s(5))
        #expect(t.tracks[1].clips[0].timeline.end == s(10))
        #expect(t.tracks[2].clips[0].timeline.end == s(10))
        #expect(ses.undoName == "Trim Next Edit")
        #expect(ses.undo())
        #expect(ses.activeTimeline!.tracks[0].clips[0].timeline.end == s(10))
    }

    @Test func rippleTrimSkipsMutedAudio() {
        var muted = track([clip(0, 10, kind: .audio)], kind: .audio); muted.isMuted = true
        let ses = makeSession([track([clip(0, 10)]), muted])
        ses.seek(to: s(4))
        ses.trimToPlayhead(.tail, mode: .ripple)
        let t = ses.activeTimeline!
        #expect(t.tracks[0].clips[0].timeline.end == s(4))
        #expect(t.tracks[1].clips[0].timeline.end == s(10))
    }

    @Test func allTracksStillTrimWhenNoneIsSwitchedOff() {
        let ses = makeSession([track([clip(0, 10)]), track([clip(0, 10, kind: .audio)], kind: .audio)])
        ses.seek(to: s(6))
        ses.trimToPlayhead(.tail, mode: .plain)
        #expect(ses.activeTimeline!.tracks.map { $0.clips[0].timeline.end } == [s(6), s(6)])
    }

    @Test func rollTrimMovesTheCutToThePlayheadAndKeepsTheLength() {
        let ses = makeSession([track([clip(0, 5), clip(5, 5)])])
        ses.seek(to: s(7))
        ses.trimToPlayhead(.head, mode: .roll)
        let cs = ses.activeTimeline!.tracks[0].clips
        #expect(cs[0].timeline.end == s(7))
        #expect(cs[1].start == s(7))
        #expect(cs[1].timeline.end == s(10))
        #expect(ses.undoName == "Roll Trim Previous Edit")
    }

    @Test func rollTrimWithoutNeighborChangesNothing() {
        let a = clip(0, 10)
        let ses = makeSession([track([a])])
        ses.seek(to: s(4))
        ses.trimToPlayhead(.head, mode: .roll)
        #expect(ses.activeTimeline!.tracks[0].clips == [a])
    }

    @Test func slideFiveFramesMovesTheClipBetweenItsNeighbors() {
        let a = clip(0, 4), m = clip(4, 4, src: 10), b = clip(8, 4, src: 20)
        let ses = makeSession([track([a, m, b])])
        ses.select(clips: [m.id])
        ses.slideSelection(frames: 5)
        var cs = ses.activeTimeline!.tracks[0].clips
        #expect(cs[1].start == s(4) + fd * 5)
        #expect(cs[1].source == m.source)
        #expect(cs[0].timeline.end == s(4) + fd * 5)
        #expect(cs[2].start == s(8) + fd * 5)             // the next clip gives the time
        ses.slideSelection(frames: -5)
        cs = ses.activeTimeline!.tracks[0].clips
        #expect(cs[1].start == s(4))
        #expect(ses.undoName == "Slide")
    }

    @Test func slipKeyframesStayLeavesKeysOnTheTimeline() {
        var c = clip(10, 10, src: 5)
        c.mediaDuration = s(100)
        c.animation.opacity.track = KeyframeTrack(keys: [Keyframe(time: s(2), value: 0.5, interpolation: .linear)])
        let ses = makeSession([track([c])])
        ses.select(clips: [c.id])
        ses.slipSelection(frames: 30, keyframes: .stay)
        var n = ses.activeTimeline!.tracks[0].clips[0]
        #expect(n.source.start == s(6))
        #expect(n.animation.opacity.track.keys[0].time == s(2))
        ses.slipSelection(frames: 30)                       // default: keys follow the content
        n = ses.activeTimeline!.tracks[0].clips[0]
        #expect(n.source.start == s(7))
        #expect(n.animation.opacity.track.keys[0].time == s(1))
    }
}
