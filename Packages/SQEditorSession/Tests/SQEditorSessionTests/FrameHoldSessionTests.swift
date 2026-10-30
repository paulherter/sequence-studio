import Foundation
import SQCore
import Testing
@testable import SQEditorSession

// Add Frame Hold / Insert Frame Hold Segment at session level: one undo step, the playhead frame is the held frame,
// nothing around the clip moves (Add) or the tail ripples by the held length (Insert, Fast Cut keeps V1 gapless).

private func s(_ n: Int64) -> Time { Time(n, 1) }

@MainActor
struct FrameHoldSessionTests {
    private func session(_ mode: TimelineEditMode) -> (EditorSession, Clip, Clip) {
        let a = Clip(name: "a", media: UUID(), kind: .video, source: TimeRange(start: s(10), duration: s(8)), start: .zero,
                     mediaDuration: s(100))
        let b = Clip(name: "b", media: UUID(), kind: .video, source: TimeRange(start: s(10), duration: s(4)), start: s(8),
                     mediaDuration: s(100))
        var t = Timeline(name: "t", frameDuration: Time(1, 24), tracks: [Track(kind: .video, clips: [a, b])])
        t.setEditMode(mode)
        return (EditorSession(project: Project(name: "P", timelines: [t])), a, b)
    }

    @Test func addFrameHoldFreezesTheTailAndIsOneUndoStep() throws {
        let (ses, a, b) = session(.normal)
        ses.seek(to: s(3))
        let before = try #require(ses.activeTimeline)
        let depth = ses.history.undoDepth
        #expect(ses.addFrameHold())
        #expect(ses.history.undoDepth == depth + 1)
        let clips = try #require(ses.activeTimeline).tracks[0].clips
        #expect(clips.count == 3)
        #expect(clips[0].timeline == TimeRange(start: .zero, end: s(3)) && clips[0].holdFrame == nil)
        #expect(clips[1].timeline == TimeRange(start: s(3), end: s(8)) && clips[1].holdFrame != nil)
        #expect(clips[1].sourceTime(at: s(5), frameDuration: Time(1, 24)) == s(13))   // the frame under the playhead
        #expect(clips[2].id == b.id && clips[2].start == s(8))
        _ = a
        ses.undo()
        #expect(ses.activeTimeline == before)
    }

    @Test func insertFrameHoldRipplesTheRestAndKeepsFastCutGapless() throws {
        let (ses, _, b) = session(.magnetic)
        ses.seek(to: s(3))
        let depth = ses.history.undoDepth
        #expect(ses.insertFrameHold(duration: s(2)))
        #expect(ses.history.undoDepth == depth + 1)
        let t = try #require(ses.activeTimeline)
        let clips = t.tracks[0].clips
        #expect(clips.count == 4)
        var end = Time.zero
        for c in clips { #expect(c.start == end); end = c.timeline.end }        // no gap, no overlap
        #expect(clips.last?.id == b.id && clips.last?.start == s(10))
    }

    @Test func addFrameHoldOutsideAnyClipDoesNothing() throws {
        let (ses, _, _) = session(.normal)
        ses.seek(to: s(50))
        let before = ses.activeTimeline
        let depth = ses.history.undoDepth
        #expect(!ses.addFrameHold())
        #expect(ses.history.undoDepth == depth)
        #expect(ses.activeTimeline == before)
    }
}
