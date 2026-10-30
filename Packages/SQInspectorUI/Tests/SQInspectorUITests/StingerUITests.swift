import AppKit
import Foundation
import Testing
import SQCore
@testable import SQInspectorUI

// N6b Stinger: picking the clip and the cut point from Effect Controls (session + controls).

private let fd = Time(1, 30)
private func f(_ n: Int64) -> Time { fd * n }

@MainActor @Suite struct StingerUITests {
    private func makeSession() throws -> (EditorSession, Transition.ID, MediaRef) {
        var v = Track(kind: .video, name: "V1")
        let a = Clip(name: "A", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: f(60)), start: .zero, mediaDuration: f(60))
        let b = Clip(name: "B", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: f(60)), start: f(60), mediaDuration: f(60))
        try v.overwrite(a); try v.overwrite(b)
        var t = Timeline(name: "Main", format: SequenceFormat(width: 1920, height: 1080, frameDuration: fd), tracks: [v])
        let id = try t.addTransition(kind: .stinger, track: v.id, outgoing: a.id, incoming: b.id, duration: f(30))
        let video = VideoTrackInfo(width: 1920, height: 1080, codec: "ap4h", bitDepth: 12, chroma: "4:4:4",
                                   nominalFrameDuration: fd, isVariableFrameRate: false)
        let stinger = MediaRef(name: "Logo Sting", path: "/s.mov", fingerprint: MediaFingerprint(size: 1), duration: f(40),
                               info: MediaInfo(duration: f(40), video: video))
        let still = MediaRef(name: "Still", path: "/s.png", fingerprint: MediaFingerprint(size: 1),
                             info: MediaInfo(duration: f(1), video: video, isStill: true))
        let ses = EditorSession(project: Project(name: "P", media: [stinger, still], timelines: [t]), engine: StubProgramEngine())
        return (ses, id, stinger)
    }

    @Test func candidatesAreVideoClipsWithoutStills() throws {
        let (ses, _, stinger) = try makeSession()
        #expect(ses.stingerCandidates.map(\.id) == [stinger.id])
    }

    @Test func pickingAClipTakesItsLengthAndIsOneUndoStep() throws {
        let (ses, id, stinger) = try makeSession()
        ses.setTransitionStinger(id, media: stinger.id)
        var tr = try #require(ses.activeTimeline?.transition(id)?.transition)
        #expect(tr.stinger?.media == stinger.id && tr.duration == f(40) && tr.stinger?.scale == 1)
        ses.setTransitionStinger(id, media: stinger.id, cutFraction: 0.25)
        tr = try #require(ses.activeTimeline?.transition(id)?.transition)
        #expect(tr.stinger?.cutFraction == 0.25 && tr.duration == f(40))
        ses.setTransitionStinger(id, media: nil)
        #expect(ses.activeTimeline?.transition(id)?.transition.stinger == nil)
        #expect(ses.undo())
        #expect(ses.activeTimeline?.transition(id)?.transition.stinger?.cutFraction == 0.25)
    }

    @Test func controlsShowTheClipMenuOnlyForAStinger() throws {
        let (ses, id, stinger) = try makeSession()
        ses.setTransitionStinger(id, media: stinger.id, cutFraction: 0.6)
        let info = try #require(ses.transitionInfo(id))
        let c = TransitionControlsView()
        var picked: UUID??
        c.onStingerMedia = { picked = $0 }
        c.update(transition: info.transition, resolved: info.resolved, frameDuration: fd,
                 stingerMedia: ses.stingerCandidates.map { (id: $0.id, name: $0.name) })
        #expect(c.stingerPopUp.itemTitles == ["None", "Logo Sting"])
        #expect(c.stingerPopUp.titleOfSelectedItem == "Logo Sting")
        #expect(c.stingerCutSlider.doubleValue == 60)
        c.stingerPopUp.selectItem(at: 0)
        _ = c.stingerPopUp.target?.perform(c.stingerPopUp.action, with: c.stingerPopUp)
        #expect(picked == .some(nil))
    }
}
