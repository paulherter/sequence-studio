import Foundation
import Testing
import SQCore
@testable import SQEditorSession

// W6.1: Cmd+K, Up/Down and X share one rule (selection > targeted > all); ripple clamps show in the status line.

private let fd = Time(1, 30)
private func s(_ n: Int64) -> Time { Time(n, 1) }
private func clip(_ start: Int64, _ dur: Int64) -> Clip {
    Clip(name: "c\(start)", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(dur)), start: s(start))
}
private func track(_ clips: [Clip], targeted: Bool = false) -> Track {
    var t = Track(kind: .video, isTargeted: targeted)
    for c in clips { try! t.overwrite(c) }
    return t
}

/// V1 [0,4) [4,8), V2 [1,3) [3,6) (targeted when `target`), V3 [2,7).
@MainActor private struct Rig {
    let session: EditorSession
    let v3: Clip
    init(target: Bool = false) {
        let v3 = clip(2, 5)
        let t = Timeline(name: "Main", frameDuration: fd,
                         tracks: [track([clip(0, 4), clip(4, 4)]), track([clip(1, 2), clip(3, 3)], targeted: target), track([v3])])
        session = EditorSession(project: Project(name: "P", timelines: [t]), engine: StubProgramEngine())
        session.setSelectionFollowsPlayhead(false)     // these tests set the selection by hand and then move the playhead
        self.v3 = v3
    }
    var counts: [Int] { session.activeTimeline!.tracks.map(\.clips.count) }
}

@MainActor @Suite struct EditTargetRulesSessionTests {
    // Cmd+K
    @Test func addEditFollowsSelection() {
        let r = Rig(target: true)
        r.session.select(clips: [r.v3.id]); r.session.seek(to: s(5))
        r.session.addEditAtPlayhead()
        #expect(r.counts == [2, 2, 2])
    }

    @Test func addEditFollowsTargetsWithoutSelection() {
        let r = Rig(target: true)
        r.session.seek(to: s(5)); r.session.addEditAtPlayhead()
        #expect(r.counts == [2, 3, 1])
    }

    @Test func addEditCutsAllWithoutSelectionOrTargets() {
        let r = Rig()
        r.session.seek(to: s(5)); r.session.addEditAtPlayhead()
        #expect(r.counts == [3, 3, 2])
    }

    @Test func addEditAllTracksIgnoresTheRule() {
        let r = Rig(target: true)
        r.session.select(clips: [r.v3.id]); r.session.seek(to: s(5))
        r.session.addEditAtPlayhead(allTracks: true)
        #expect(r.counts == [3, 3, 2])
    }

    // Up / Down
    @Test func editNavigationFollowsSelection() {
        let r = Rig(target: true)
        r.session.select(clips: [r.v3.id])
        r.session.goToNextEditPoint()
        #expect(r.session.playhead == s(2))
        r.session.goToNextEditPoint()
        #expect(r.session.playhead == s(7))
        r.session.goToPreviousEditPoint()
        #expect(r.session.playhead == s(2))
    }

    @Test func editNavigationFollowsTargetsWithoutSelection() {
        let r = Rig(target: true)
        r.session.goToNextEditPoint()
        #expect(r.session.playhead == s(1))
        r.session.goToNextEditPoint()
        #expect(r.session.playhead == s(3))
    }

    @Test func editNavigationCoversAllWithoutSelectionOrTargets() {
        let r = Rig()
        r.session.goToNextEditPoint()
        #expect(r.session.playhead == s(1))
        r.session.goToNextEditPoint()
        #expect(r.session.playhead == s(2))
    }

    // X
    @Test func markClipFollowsSelection() {
        let r = Rig(target: true)
        r.session.select(clips: [r.v3.id]); r.session.seek(to: s(5))
        r.session.markClip()
        #expect(r.session.activeTimeline?.inOut == TimeRange(start: s(2), end: s(7)))
    }

    @Test func markClipFollowsTargetsWithoutSelection() {
        let r = Rig(target: true)
        r.session.seek(to: s(5)); r.session.markClip()
        #expect(r.session.activeTimeline?.inOut == TimeRange(start: s(3), end: s(6)))
    }

    @Test func markClipCoversAllWithoutSelectionOrTargets() {
        let r = Rig()
        r.session.seek(to: s(5)); r.session.markClip()
        #expect(r.session.activeTimeline?.inOut == TimeRange(start: s(2), end: s(8)))
    }

    // Q / W unchanged: all unlocked tracks, selection and targets ignored.
    @Test func rippleTrimStillTrimsAllTracks() {
        let v3 = clip(0, 8)
        let t = Timeline(name: "Main", frameDuration: fd,
                         tracks: [track([clip(0, 8)]), track([clip(0, 8)], targeted: true), track([v3])])
        let ss = EditorSession(project: Project(name: "P", timelines: [t]), engine: StubProgramEngine())
        ss.select(clips: [v3.id]); ss.seek(to: s(5))
        ss.rippleTrimToPlayhead(.tail)
        let ends = ss.activeTimeline!.tracks.map { $0.clips.map(\.timeline.end) }
        #expect(ends == [[s(5)], [s(5)], [s(5)]])
    }
}

@MainActor @Suite struct RippleClampStatusTests {
    private func session(_ tracks: [Track]) -> EditorSession {
        EditorSession(project: Project(name: "P", timelines: [Timeline(name: "Main", frameDuration: fd, tracks: tracks)]),
                      engine: StubProgramEngine())
    }

    @Test func clampedRippleDeleteSaysWhichTrack() {
        let a = clip(0, 2)
        let ss = session([track([a, clip(2, 2)]), track([clip(0, 1), clip(2, 1)])])
        ss.select(clips: [a.id])
        ss.deleteSelection(ripple: true)
        #expect(ss.activeTimeline!.tracks[0].clips.map(\.start) == [s(1)])
        #expect(ss.lastError == "Ripple Delete limited by clip on V2")
        #expect(ss.undoName == "Ripple Delete")
    }

    @Test func committedRippleDeleteSaysWhichTrack() throws {
        let a = clip(0, 2)
        let ss = session([track([a, clip(2, 2)]), track([clip(0, 1), clip(2, 1)])])
        var out = ss.activeTimeline!
        try out.rippleDelete([a.id])
        ss.commit(TimelineCommit(timeline: out, edits: [.rippleDelete([a.id])], undoName: "Ripple Delete", selection: []))
        #expect(ss.lastError == "Ripple Delete limited by clip on V2")
        ss.undo()
        #expect(ss.activeTimeline!.tracks[0].clips.map(\.start) == [s(0), s(2)])
    }

    @Test func unclampedRippleDeleteSaysNothing() {
        let a = clip(0, 2)
        let ss = session([track([a, clip(2, 2)]), track([clip(5, 1)])])
        ss.select(clips: [a.id])
        ss.deleteSelection(ripple: true)
        #expect(ss.activeTimeline!.tracks[0].clips.map(\.start) == [s(0)])
        #expect(ss.lastError == nil)
    }

    @Test func liftAndExtractWithoutInOutSayWhy() {
        let ss = session([track([clip(0, 8)])])
        ss.liftRange()
        #expect(ss.lastError == "Set In and Out first.")
        ss.clearError()
        ss.extractRange()
        #expect(ss.lastError == "Set In and Out first.")
        #expect(ss.activeTimeline!.tracks[0].clips.count == 1)
    }

    @Test func clampedExtractSaysWhichTrack() throws {
        let ss = session([track([clip(0, 8)], targeted: true), track([clip(0, 3), clip(4, 2)])])
        try ss.performTimeline("In/Out") { $0.setMarkedRange(TimeRange(start: s(2), end: s(4))) }
        ss.extractRange()
        #expect(ss.lastError == "Delete Range limited by clip on V2")
    }

    @Test func clampedRippleTrimSaysWhichTrack() {
        let ss = session([track([clip(0, 10)]), track([clip(0, 3), clip(4, 2)])])
        ss.seek(to: s(3))
        ss.rippleTrimToPlayhead(.head)
        #expect(ss.lastError == "Trim limited by clip on V2")
    }
}
