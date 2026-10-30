import Foundation
import Testing
import SQCore
@testable import SQEditorSession

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func r(_ a: Int64, _ d: Int64) -> TimeRange { TimeRange(start: s(a), duration: s(d)) }

@MainActor @Suite struct ProposedCutSessionTests {
    private func make() -> (EditorSession, Clip) {
        let link = UUID()
        let v = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(20)), start: .zero, link: link)
        let a = Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(20)), start: .zero, link: link)
        var vt = Track(kind: .video), at = Track(kind: .audio)
        try! vt.overwrite(v); try! at.overwrite(a)
        return (EditorSession(project: Project(name: "P", timelines: [Timeline(name: "T", frameDuration: Time(1, 30), tracks: [vt, at])])), a)
    }

    @Test func proposeThenAcceptAllIsTwoUndoSteps() {
        let (sess, _) = make()
        let depth = sess.undoDepth
        #expect(sess.proposeCuts([r(2, 1), r(6, 2)]))
        #expect(sess.activeTimeline!.proposedCuts.count == 2 && sess.undoDepth == depth + 1)
        #expect(sess.acceptProposedCuts(nil))
        #expect(sess.undoDepth == depth + 2)
        #expect(sess.activeTimeline!.tracks.map(\.end) == [s(17), s(17)] && sess.activeTimeline!.proposedCuts.isEmpty)
        sess.undo()
        #expect(sess.activeTimeline!.tracks.map(\.end) == [s(20), s(20)] && sess.activeTimeline!.proposedCuts.count == 2)
    }

    @Test func rejectOneKeepsTheRest() {
        let (sess, _) = make()
        sess.proposeCuts([r(2, 1), r(6, 2)])
        let first = sess.activeTimeline!.proposedCuts[0].id
        #expect(sess.rejectProposedCuts([first]))
        #expect(sess.activeTimeline!.proposedCuts.map(\.range) == [r(6, 2)])
        #expect(sess.activeTimeline!.tracks.map(\.end) == [s(20), s(20)])
    }

    @Test func playheadPicksTheProposalUnderOrAfterIt() {
        let (sess, _) = make()
        sess.proposeCuts([r(2, 1), r(6, 2)])
        sess.seek(to: s(7))
        #expect(sess.proposedCutAtPlayhead() == sess.activeTimeline!.proposedCuts[1].id)
        sess.seek(to: s(4))
        #expect(sess.proposedCutAtPlayhead() == sess.activeTimeline!.proposedCuts[1].id)
        sess.seek(to: s(19))
        #expect(sess.proposedCutAtPlayhead() == sess.activeTimeline!.proposedCuts[1].id)   // nothing after: nearest before
    }

    @Test func sceneProposalsRazorTheClipsAndAreOneUndoStep() {
        let (sess, _) = make()
        #expect(sess.proposeSceneCuts([s(5), s(9)]))
        #expect(sess.activeTimeline!.proposedCuts.map(\.kind) == [.scene, .scene])
        let depth = sess.undoDepth
        #expect(sess.acceptProposedCuts(nil))
        #expect(sess.undoDepth == depth + 1)
        let t = sess.activeTimeline!
        #expect(t.tracks.map { $0.clips.count } == [3, 3])
        #expect(t.tracks.map(\.end) == [s(20), s(20)] && t.proposedCuts.isEmpty)
        #expect(t.tracks[0].clips.map(\.start) == [s(0), s(5), s(9)])
        sess.undo()
        #expect(sess.activeTimeline!.tracks.map { $0.clips.count } == [1, 1] && sess.activeTimeline!.proposedCuts.count == 2)
    }

    @Test func rejectingSceneProposalDoesNotCut() {
        let (sess, _) = make()
        sess.proposeSceneCuts([s(5)])
        #expect(sess.rejectProposedCuts(nil))
        #expect(sess.activeTimeline!.tracks.map { $0.clips.count } == [1, 1])
    }

    @Test func sceneChangesOfAVideoClipBecomeProposals() async {
        let (sess, _) = make()
        let v = sess.activeTimeline!.tracks[0].clips[0]
        let n = await sess.findSceneChanges(in: [v]) { _ in [s(0), s(4), s(25)] }   // 0 and 25 are not inside the clip
        #expect(n == 1)
        #expect(sess.activeTimeline!.proposedCuts.map(\.range.start) == [s(4)])
    }

    @Test func sceneChangeTargetsAreTheSelectedVideoClips() {
        let (sess, a) = make()
        let v = sess.activeTimeline!.tracks[0].clips[0]
        sess.select(clips: [a.id, v.id])
        #expect(sess.sceneChangeTargets.map(\.id) == [v.id])
    }
}
