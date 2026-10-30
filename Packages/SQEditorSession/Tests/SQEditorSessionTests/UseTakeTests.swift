import Foundation
import Testing
import SQCore
@testable import SQEditorSession

private func s(_ n: Int64) -> Time { Time(n, 1) }

@MainActor @Suite struct UseTakeTests {
    private func make(takes: Int) -> (EditorSession, [Clip]) {
        var clips: [Clip] = []
        var tracks: [Track] = []
        for _ in 0..<takes {
            let c = Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(10)), start: .zero)
            var t = Track(kind: .audio)
            try! t.overwrite(c)
            clips.append(c); tracks.append(t)
        }
        var tl = Timeline(name: "T", frameDuration: Time(1, 30), tracks: tracks)
        tl.inOut = TimeRange(start: s(2), duration: s(3))
        return (EditorSession(project: Project(name: "P", timelines: [tl])), clips)
    }

    @Test func undoRestoresTimelineAndLeavesBounds() {
        let (sess, c) = make(takes: 2)
        sess.select(clips: [c[1].id], captions: [])
        let before = sess.activeTimeline
        let bounds = sess.bounds
        #expect(sess.useSelectedTakeForRange())
        #expect(sess.activeTimeline != before)
        #expect(sess.bounds == bounds)
        #expect(sess.undo())
        #expect(sess.activeTimeline == before)
        #expect(sess.bounds == bounds)
    }

    @Test func refusedWithoutOtherTake() {
        let (sess, c) = make(takes: 1)
        sess.select(clips: [c[0].id], captions: [])
        #expect(!sess.useSelectedTakeForRange())
    }
}
