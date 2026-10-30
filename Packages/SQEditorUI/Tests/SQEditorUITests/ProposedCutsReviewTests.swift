import AppKit
import Foundation
import Testing
import SQCore
@testable import SQEditorUI
@testable import SQUIKit

private func s(_ n: Int64) -> Time { Time(n, 1) }

@MainActor @Suite struct ProposedCutsReviewTests {
    private func session() -> (EditorSession, Clip) {
        let link = UUID()
        let v = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(20)), start: .zero, link: link)
        let a = Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(20)), start: .zero, link: link)
        var vt = Track(kind: .video), at = Track(kind: .audio)
        try! vt.overwrite(v); try! at.overwrite(a)
        let sess = EditorSession(project: Project(name: "P", timelines: [Timeline(name: "T", frameDuration: Time(1, 30), tracks: [vt, at])]))
        return (sess, a)
    }

    @Test func reviewCutsCheckedRejectsTheRestInOneUndoStep() {
        let (sess, a) = session()
        sess.select(clips: [a.id])
        #expect(sess.proposeCuts([TimeRange(start: s(2), duration: s(1)), TimeRange(start: s(6), duration: s(2)), TimeRange(start: s(12), duration: s(2))]))
        let ps = sess.activeTimeline!.proposedCuts
        let depth = sess.undoDepth
        #expect(sess.reviewProposedCuts(accepted: [ps[1].id]))               // only the 6-8 s pause
        #expect(sess.undoDepth == depth + 1)
        let tl = sess.activeTimeline!
        #expect(tl.proposedCuts.isEmpty)
        #expect(tl.tracks[1].end == s(18))
        // The join is softened by one frame on both sides.
        let audio = tl.tracks[1].clips
        #expect(audio.count == 2 && audio[0].audioFadeOut == Time(1, 30) && audio[1].audioFadeIn == Time(1, 30))
        sess.undo()
        #expect(sess.activeTimeline!.proposedCuts.count == 3 && sess.activeTimeline!.tracks[1].end == s(20))
    }

    @Test func nothingCheckedRejectsAll() {
        let (sess, a) = session()
        sess.select(clips: [a.id])
        #expect(sess.proposeCuts([TimeRange(start: s(2), duration: s(1))]))
        #expect(sess.reviewProposedCuts(accepted: []))
        #expect(sess.activeTimeline!.proposedCuts.isEmpty && sess.activeTimeline!.tracks[1].end == s(20))
    }

    @Test func crossfadeCanBeSwitchedOff() {
        let (sess, a) = session()
        sess.select(clips: [a.id])
        #expect(sess.removeSilences(cuts: [TimeRange(start: s(2), duration: s(1))], from: [a], crossfade: false))
        #expect(sess.activeTimeline!.tracks[1].clips.allSatisfy { $0.audioFadeIn == .zero && $0.audioFadeOut == .zero })
    }

    @Test func listShowsOneRowPerCutAndCountsTheChecked() {
        var tl = Timeline(name: "T", frameDuration: Time(1, 30), tracks: [])
        tl.proposeCuts([TimeRange(start: Time(125, 10), duration: Time(14, 10)), TimeRange(start: s(70), duration: s(2))], kind: .silence)
        let cuts = tl.proposedCuts
        let c = ProposedCutsReviewDialog.ReviewController(cuts: cuts)
        #expect(c.labels == ["0:12.5   1.4 s", "1:10.0   2.0 s", "2 of 2 checked, 3.4 s will be removed."])
        #expect(c.checkedIDs == Set(cuts.map(\.id)))
        c.boxes[0].state = .off
        c.refresh()
        #expect(c.checkedIDs == [cuts[1].id])
        #expect(c.labels.last == "1 of 2 checked, 2.0 s will be removed.")
    }
}
