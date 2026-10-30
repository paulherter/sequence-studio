import Foundation
import SQCore
import Testing
@testable import SQEditorSession

private let fd = Time(1, 30)
private func f(_ n: Int64) -> Time { fd * n }

@MainActor
@Suite struct SpeedPointSessionTests {
    private func make() -> (EditorSession, Clip) {
        let c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: f(150)), start: .zero, mediaDuration: f(4000))
        var t = Track(kind: .video)
        try! t.overwrite(c)
        let tl = Timeline(name: "T", frameDuration: fd, tracks: [t])
        return (EditorSession(project: Project(name: "P", timelines: [tl])), c)
    }
    private func clip(_ s: EditorSession, _ id: Clip.ID) -> Clip { s.activeTimeline!.tracks.flatMap(\.clips).first { $0.id == id }! }

    @Test func addsANoChangePointAtThePlayheadInOneUndoStep() {
        let (ses, c) = make()
        #expect(!ses.canAddSpeedPoint)                       // nothing selected
        ses.select(clips: [c.id], captions: [])
        ses.seek(to: f(60))
        #expect(ses.canAddSpeedPoint)
        let depth = ses.undoDepth
        #expect(ses.addSpeedPointAtPlayhead())
        #expect(ses.undoDepth == depth + 1)
        let k = clip(ses, c.id).speedKeys
        #expect(k?.boundaries == [.zero, f(60), f(150)])
        #expect(clip(ses, c.id).duration == f(150))
        #expect(!ses.canAddSpeedPoint)                       // already a point on this frame
        #expect(!ses.addSpeedPointAtPlayhead())
        ses.undo()
        #expect(clip(ses, c.id).speedKeys == nil)
    }

    @Test func noPointAtTheClipEdge() {
        let (ses, c) = make()
        ses.select(clips: [c.id], captions: [])
        ses.seek(to: .zero)
        #expect(!ses.canAddSpeedPoint && !ses.addSpeedPointAtPlayhead())
    }

    @Test func easeOnAPointOpensAndCurvesATransition() {
        let (ses, c) = make()
        ses.select(clips: [c.id], captions: [])
        ses.seek(to: f(60))
        // a no-change point has nothing to ease
        #expect(!ses.easeSpeedPointAtPlayhead(.easeInOut, side: .both))
        ses.addSpeedPointAtPlayhead()
        #expect(!ses.easeSpeedPointAtPlayhead(.easeInOut, side: .both))
        // make the span before it faster, then ease the point
        let k = clip(ses, c.id).speedKeys!
        let fast = k.retimingKey(atBoundary: 1, by: .zero - f(30), frameDuration: fd)!
        #expect(fast.segments[0].from.percent == 200)
        ses.applySpeedEdit(SpeedEdit(clip: c.id, keys: fast, phase: .began, keepingKeys: true))
        ses.applySpeedEdit(SpeedEdit(clip: c.id, keys: fast, phase: .changed, keepingKeys: true))
        ses.seek(to: f(30))
        let depth = ses.undoDepth
        #expect(ses.easeSpeedPointAtPlayhead(.easeInOut, side: .both))
        #expect(ses.undoDepth == depth + 1)
        let e = clip(ses, c.id).speedKeys!
        #expect(e.segments.contains { $0.isRamp && $0.ease != nil })
    }

    @Test func escDuringABandDragRestoresTheStartAndDropsTheStep() {
        let (ses, c) = make()
        let start = ses.activeTimeline!
        let depth = ses.undoDepth
        let k = SpeedKeys.of(clip(ses, c.id))
        let fast = k.addingKey(at: f(60), frameDuration: fd)!.keys
        ses.applySpeedEdit(SpeedEdit(clip: c.id, keys: k, phase: .began, keepingKeys: true))
        ses.applySpeedEdit(SpeedEdit(clip: c.id, keys: fast, phase: .changed, keepingKeys: true))
        #expect(ses.undoDepth == depth + 1)
        ses.cancelSpeedEdit(clip: c.id, restoring: start)
        #expect(ses.activeTimeline == start)
        #expect(ses.undoDepth == depth)
        // a cancel before any change leaves nothing behind either
        ses.applySpeedEdit(SpeedEdit(clip: c.id, keys: k, phase: .began, keepingKeys: true))
        ses.cancelSpeedEdit(clip: c.id, restoring: start)
        #expect(ses.undoDepth == depth)
    }
}
