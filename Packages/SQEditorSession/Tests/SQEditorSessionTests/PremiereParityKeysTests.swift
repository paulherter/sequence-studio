import Foundation
import Testing
import SQCore
@testable import SQEditorSession

private let fd = Time(1, 30)
private func s(_ n: Int64) -> Time { Time(n, 1) }
private func clip(_ start: Int64, _ dur: Int64, src: Int64 = 0) -> Clip {
    Clip(name: "c\(start)", media: UUID(), kind: .video, source: TimeRange(start: s(src), duration: s(dur)), start: s(start))
}
private func track(_ clips: [Clip]) -> Track {
    var t = Track(kind: .video)
    for c in clips { try! t.overwrite(c) }
    return t
}
@MainActor private func makeSession(_ tracks: [Track]) -> EditorSession {
    let t = Timeline(name: "Main", frameDuration: fd, tracks: tracks)
    return EditorSession(project: Project(name: "P", timelines: [t]), engine: StubProgramEngine())
}

@MainActor @Suite struct PremiereParityKeysTests {
    @Test func selectAdjacentClipWalksTheTrack() {
        let a = clip(0, 2), b = clip(2, 2), c = clip(4, 2)
        let ses = makeSession([track([a, b, c])])
        ses.select(clips: [b.id])
        #expect(ses.selectAdjacentClip(forward: true))
        #expect(ses.selection == [c.id])
        #expect(!ses.selectAdjacentClip(forward: true))
        #expect(ses.selection == [c.id])
        #expect(ses.selectAdjacentClip(forward: false))
        #expect(ses.selection == [b.id])
    }

    @Test func selectAdjacentClipNeedsASelection() {
        let ses = makeSession([track([clip(0, 2), clip(2, 2)])])
        #expect(!ses.selectAdjacentClip(forward: true))
    }

    @Test func goToSelectedClipEdges() {
        let a = clip(0, 2), b = clip(5, 3)
        let ses = makeSession([track([a, b])])
        #expect(!ses.goToSelectedClipEdge(end: false))
        ses.select(clips: [b.id])
        #expect(ses.goToSelectedClipEdge(end: false))
        #expect(ses.playhead == s(5))
        #expect(ses.goToSelectedClipEdge(end: true))
        #expect(ses.playhead == s(8))
    }

    @Test func clearMarkerAtPlayheadIsUndoable() {
        let ses = makeSession([track([clip(0, 4)])])
        ses.seek(to: s(1)); ses.addMarkerAtPlayhead()
        ses.seek(to: s(2)); #expect(!ses.clearMarkerAtPlayhead())
        ses.seek(to: s(1)); #expect(ses.clearMarkerAtPlayhead())
        #expect(ses.activeTimeline!.markers.isEmpty)
        #expect(ses.undo())
        #expect(ses.activeTimeline!.markers.count == 1)
    }

    @Test func clearAllMarkersReportsCount() {
        let ses = makeSession([track([clip(0, 4)])])
        #expect(ses.clearAllMarkers() == 0)
        ses.seek(to: s(1)); ses.addMarkerAtPlayhead()
        ses.seek(to: s(2)); ses.addMarkerAtPlayhead()
        #expect(ses.clearAllMarkers() == 2)
        #expect(ses.activeTimeline!.markers.isEmpty)
    }

    @Test func slideSelectionMovesTheClipAndKeepsItsSource() {
        let a = clip(0, 4, src: 0), b = clip(4, 4, src: 10), c = clip(8, 4, src: 20)
        let ses = makeSession([track([a, b, c])])
        ses.select(clips: [b.id])
        ses.slideSelection(frames: 6)
        let t = ses.activeTimeline!.tracks[0].clips
        #expect(t[1].start == s(4) + fd * 6)
        #expect(t[1].source == b.source)
        #expect(t[0].duration == s(4) + fd * 6)          // previous clip's tail follows
        #expect(ses.undo())
        #expect(ses.activeTimeline!.tracks[0].clips[1].start == s(4))
    }

    @Test func newKeysAreBoundAndDoNotCollide() {
        let m = CommandMap.premiereDefault
        #expect(m.duplicates.isEmpty)
        func cmd(_ k: Key, _ mod: KeyModifiers, _ f: PanelID?) -> EditorCommand? { m.command(for: KeyBinding(k, mod), focus: f) }
        #expect(cmd(.char("m"), .option, .timeline) == .clearMarker)
        #expect(cmd(.char("m"), [.control, .option], .timeline) == .clearAllMarkers)
        #expect(cmd(.char("m"), [.command, .option], .timeline) == .quickExport)
        #expect(cmd(.down, .command, .timeline) == .selectNextClip)
        #expect(cmd(.up, .command, .timeline) == .selectPreviousClip)
        #expect(cmd(.home, .shift, .timeline) == .goToSelectedClipStart)
        #expect(cmd(.char(","), .option, .timeline) == .slideLeft)
        #expect(cmd(.char("."), [.option, .shift], .timeline) == .slideRight5)
        #expect(cmd(.left, [.command, .option], .timeline) == .slipLeft)
        #expect(cmd(.right, [.command, .option], .timeline) == .slipRight)
        #expect(cmd(.left, [.command, .option, .shift], .timeline) == .slipLeft5)
        #expect(cmd(.right, [.command, .option, .shift], .timeline) == .slipRight5)
        #expect(cmd(.pageUp, .command, .project) == .projectListView)
        #expect(cmd(.pageDown, .command, .project) == .projectIconView)
        #expect(cmd(.char("]"), .command, .project) == .projectThumbnailLarger)
        #expect(cmd(.pageUp, .command, .timeline) == nil)
    }
}
