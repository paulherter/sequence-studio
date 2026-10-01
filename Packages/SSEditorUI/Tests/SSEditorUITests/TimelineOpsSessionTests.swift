import Foundation
import Testing
import SSCore
@testable import SSEditorUI

private let fd = Time(1, 30)
private func s(_ n: Int64) -> Time { Time(n, 1) }
private func clip(_ start: Int64, _ dur: Int64, kind: TrackKind = .video, link: UUID? = nil) -> Clip {
    Clip(name: "c\(start)", media: UUID(), kind: kind, source: TimeRange(start: .zero, duration: s(dur)), start: s(start), link: link)
}

@MainActor private func makeSession(_ tracks: [Track]) -> EditorSession {
    let t = Timeline(name: "Main", frameDuration: fd, tracks: tracks)
    return EditorSession(project: Project(name: "P", timelines: [t]), engine: StubProgramEngine())
}

private func track(_ clips: [Clip], kind: TrackKind = .video) -> Track {
    var t = Track(kind: kind)
    for c in clips { try! t.overwrite(c) }
    return t
}

@MainActor @Suite struct TimelineOpsSessionTests {
    @Test func copyPasteAtPlayheadSelectsThePaste() {
        let a = clip(0, 2)
        let ses = makeSession([track([a])])
        ses.select(clips: [a.id])
        #expect(ses.copySelection())
        ses.seek(to: s(5))
        ses.pasteClipboard()
        #expect(ses.activeTimeline!.tracks[0].clips.map(\.start) == [s(0), s(5)])
        #expect(ses.selection == [ses.activeTimeline!.tracks[0].clips[1].id])
        #expect(ses.undo())
        #expect(ses.activeTimeline!.tracks[0].clips.count == 1)
    }

    @Test func cutLeavesAGapAndPasteInsertRipples() {
        let a = clip(0, 2), b = clip(2, 2)
        let ses = makeSession([track([a, b])])
        ses.select(clips: [a.id])
        ses.cutSelection()
        #expect(ses.activeTimeline!.tracks[0].clips.map(\.start) == [s(2)])
        ses.seek(to: s(2))
        ses.pasteClipboard(insert: true)
        #expect(ses.activeTimeline!.tracks[0].clips.map(\.start) == [s(2), s(4)])
    }

    @Test func linkToggleAndNudge() {
        let v = clip(1, 2), a = clip(1, 2, kind: .audio)
        let ses = makeSession([track([v]), track([a], kind: .audio)])
        ses.select(clips: [v.id, a.id])
        ses.toggleLinkSelection()
        #expect(ses.activeTimeline!.tracks[0].clips[0].link != nil)
        ses.nudgeSelection(frames: 3)
        #expect(ses.activeTimeline!.tracks[0].clips[0].start == s(1) + fd * 3)
        #expect(ses.activeTimeline!.tracks[1].clips[0].start == s(1) + fd * 3)
        ses.toggleLinkSelection()
        #expect(ses.activeTimeline!.tracks[0].clips[0].link == nil)
    }

    @Test func keyboardTrimAndExtendUseTheSelectedEdge() {
        let a = clip(0, 4)
        let ses = makeSession([track([a])])
        let tail = EdgeSelection(edges: [EdgeRef(clip: a.id, edge: .tail)])
        ses.trimEdges(tail, frames: -5)
        #expect(ses.activeTimeline!.tracks[0].clips[0].timeline.end == s(4) - fd * 5)
        ses.seek(to: s(3))
        ses.extendEdit(tail)
        #expect(ses.activeTimeline!.tracks[0].clips[0].timeline.end == s(3))
    }

    @Test func closeGapAndMarkSelectionAndMarkers() {
        let a = clip(0, 2), b = clip(5, 2)
        let ses = makeSession([track([a, b])])
        let tid = ses.activeTimeline!.tracks[0].id
        ses.closeGap(GapSelection(track: tid, range: TimeRange(start: s(2), end: s(5))))
        #expect(ses.activeTimeline!.tracks[0].clips.map(\.start) == [s(0), s(2)])
        ses.select(clips: [b.id])
        ses.markSelection()
        #expect(ses.activeTimeline!.inOut == TimeRange(start: s(2), end: s(4)))
        ses.seek(to: s(1)); ses.addMarkerAtPlayhead()
        ses.seek(to: s(3)); ses.addMarkerAtPlayhead()
        ses.seek(to: s(2))
        ses.goToNextMarker()
        #expect(ses.playhead == s(3))
        ses.goToPreviousMarker(); ses.goToPreviousMarker()
        #expect(ses.playhead == s(1))
    }
}
