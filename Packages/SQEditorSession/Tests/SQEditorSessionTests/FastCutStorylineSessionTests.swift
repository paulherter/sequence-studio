import Foundation
import SQCore
import SQUIKit
import Testing
@testable import SQEditorSession

// Fast Cut storylines and the Position tool as session commands and gesture mappings.

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func clip(_ start: Int64, _ dur: Int64) -> Clip {
    Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: s(10), duration: s(dur)), start: s(start), mediaDuration: s(100))
}
private func find(_ t: Timeline?, _ id: Clip.ID) -> Clip? { t?.tracks.lazy.compactMap { $0.clips.first { $0.id == id } }.first }
private func span(_ t: Timeline?, _ id: Clip.ID) -> [Int64]? {
    guard let c = find(t, id) else { return nil }
    return [c.start.value / c.start.timescale, c.timeline.end.value / c.timeline.end.timescale]
}
private func row(_ t: Timeline?, _ id: Clip.ID) -> Int? { t?.tracks.firstIndex { $0.clips.contains { $0.id == id } } }

/// V1: A[0-4] B[4-8] C[8-12]. V2: S1[1-3] S2[3-5] S3[5-7] (a storyline). V3: U[8-10] (a lone attached clip).
@MainActor
struct FastCutStorylineSessionTests {
    let a = clip(0, 4), b = clip(4, 4), c = clip(8, 4)
    let s1 = clip(1, 2), s2 = clip(3, 2), s3 = clip(5, 2), u = clip(8, 2)

    private func session(_ mode: TimelineEditMode = .magnetic) -> EditorSession {
        var t = Timeline(name: "t", frameDuration: Time(1, 24),
                         tracks: [Track(kind: .video, clips: [a, b, c]), Track(kind: .video, clips: [s1, s2, s3]),
                                  Track(kind: .video, clips: [u])])
        t.setEditMode(mode)
        return EditorSession(project: Project(name: "P", timelines: [t]))
    }

    @Test func createStorylineMovesClipsOntoOneLaneInOneStep() throws {
        let ses = session()
        ses.select(clips: [s3.id, u.id])
        #expect(ses.fastCutCommandEnabled(.createStoryline))
        let before = try #require(ses.activeTimeline)
        let depth = ses.history.undoDepth
        _ = ses.createStoryline()
        #expect(ses.history.undoDepth == depth + 1)
        #expect(row(ses.activeTimeline, u.id) == row(ses.activeTimeline, s3.id))
        ses.undo()
        #expect(ses.activeTimeline == before)
    }

    @Test func createStorylineNeedsTwoAttachedClips() {
        let ses = session()
        ses.select(clips: [u.id])
        #expect(!ses.fastCutCommandEnabled(.createStoryline))
        ses.select(clips: [u.id, a.id])
        #expect(!ses.fastCutCommandEnabled(.createStoryline))
        let normal = session(.normal)
        normal.select(clips: [s1.id, s2.id])
        #expect(!normal.fastCutCommandEnabled(.createStoryline))
    }

    @Test func storylineRippleDeleteClosesTheRun() {
        let ses = session()
        ses.select(clips: [s2.id])
        #expect(ses.fastCutCommandEnabled(.storylineRippleDelete))
        let depth = ses.history.undoDepth
        _ = ses.storylineRippleDelete()
        #expect(ses.history.undoDepth == depth + 1)
        #expect(span(ses.activeTimeline, s1.id) == [1, 3])
        #expect(span(ses.activeTimeline, s3.id) == [3, 5])
        #expect(find(ses.activeTimeline, s2.id) == nil)
        #expect(span(ses.activeTimeline, b.id) == [4, 8])
    }

    @Test func storylineRippleDeleteIsOffOutsideAStoryline() {
        let ses = session()
        ses.select(clips: [u.id])
        #expect(!ses.fastCutCommandEnabled(.storylineRippleDelete))
        ses.select(clips: [b.id])
        #expect(!ses.fastCutCommandEnabled(.storylineRippleDelete))
    }

    @Test func draggingAStorylineClipAlongItsLaneRearranges() throws {
        var t = try #require(session().activeTimeline)
        let mapped = TimelineEdit.fastCut([.move(s3.id, to: s(1), track: nil)], in: t)
        #expect(mapped == [.fastCut(.storylineRearrange(s3.id, to: s(1)))])
        for e in mapped { try e.apply(to: &t) }
        #expect(span(t, s3.id) == [1, 3])
        #expect(span(t, s1.id) == [3, 5])
        #expect(span(t, s2.id) == [5, 7])
    }

    @Test func positionDragOverwritesAndLeavesAHole() throws {
        var t = try #require(session().activeTimeline)
        let mapped = TimelineEdit.fastCut([.move(b.id, to: s(8), track: nil)], in: t, position: true)
        #expect(mapped == [.fastCut(.positionMove(b.id, to: s(8), track: nil, partners: [:]))])
        for e in mapped { try e.apply(to: &t) }
        #expect(span(t, a.id) == [0, 4])
        #expect(span(t, b.id) == [8, 12])
        #expect(find(t, c.id) == nil)
    }

    @Test func positionToolIsItsOwnTool() {
        #expect(TimelineTool.position.effectiveTimelineTool == .position)
        #expect(TimelineTool(key: "v") == .selection)
    }

    @Test func newCommandsAreFastCutCommands() {
        #expect(EditorCommand.fastCutCommands.contains(.createStoryline))
        #expect(EditorCommand.fastCutCommands.contains(.storylineRippleDelete))
    }
}
