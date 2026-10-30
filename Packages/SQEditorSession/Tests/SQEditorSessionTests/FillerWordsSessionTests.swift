import Foundation
import Testing
import SQCore
@testable import SQEditorSession

private func s(_ n: Int64) -> Time { Time(n, 1) }
private let fd = Time(1, 30)

@MainActor @Suite struct FillerWordsSessionTests {
    private func make(captions: Bool = true) -> (EditorSession, Clip) {
        let a = Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(10)), start: .zero)
        var t1 = Track(kind: .audio)
        try! t1.overwrite(a)
        var tl = Timeline(name: "T", frameDuration: fd, tracks: [t1])
        func w(_ x: String, _ a: Int64, _ b: Int64) -> CaptionWord { CaptionWord(text: x, range: TimeRange(start: Time(a, 1000), end: Time(b, 1000))) }
        let item = CaptionItem(lines: ["so um yes uh ok"], range: TimeRange(start: .zero, duration: s(6)),
                               words: [w("so", 0, 400), w("um", 1_000, 1_500), w("yes", 2_000, 2_500), w("uh", 3_000, 3_500), w("ok", 4_000, 4_400)])
        if captions { tl.captionTracks = [CaptionTrack(items: [item])] }
        return (EditorSession(project: Project(name: "P", timelines: [tl])), a)
    }

    @Test func proposesFillersAsMarkersWithACount() {
        let (sess, _) = make()
        let scan = sess.proposeFillerWordCuts(language: "en-US")
        #expect(scan.count == 2)
        let proposals = sess.activeTimeline!.proposedCuts
        #expect(proposals.count == 2 && proposals.allSatisfy { $0.kind == .filler })
        #expect(sess.proposeFillerWordCuts(language: "en-US").count == 2)               // again: replaced, not doubled
        #expect(sess.activeTimeline!.proposedCuts.count == 2)
    }

    @Test func germanDoesNotCutUm() {
        let (sess, _) = make()
        #expect(sess.fillerScan(language: "de-DE").count == 1)
    }

    @Test func acceptingRipplesOnceAndShortensTheSequence() {
        let (sess, a) = make()
        sess.select(clips: [a.id], captions: [])
        let before = sess.activeTimeline!.tracks[0].end
        sess.proposeFillerWordCuts(language: "en-US")
        let depth = sess.undoDepth
        #expect(sess.acceptProposedCuts(nil))
        #expect(sess.undoDepth == depth + 1)
        #expect(sess.activeTimeline!.proposedCuts.isEmpty)
        #expect(sess.activeTimeline!.tracks[0].end == before - s(1))                     // two 0.5 s fillers
        sess.undo()
        #expect(sess.activeTimeline!.tracks[0].end == before)
    }

    @Test func nothingFoundChangesNothing() {
        let (sess, _) = make(captions: false)
        let depth = sess.undoDepth
        #expect(sess.proposeFillerWordCuts(language: "en-US").count == 0)
        #expect(sess.undoDepth == depth)
    }

    @Test func voicePresetGoesOntoTheAudioClipInOneUndoStep() {
        let (sess, a) = make()
        let depth = sess.undoDepth
        #expect(sess.addEffect(kind: AudioPresets.voiceID, to: [a.id]))
        #expect(sess.undoDepth == depth + 1)
        let c = sess.activeTimeline!.tracks.flatMap(\.clips).first { $0.id == a.id }!
        #expect(c.effects.first?.kind == ClipEffect.audioLowCutKind)
        #expect(c.effects.last?.kind == ClipEffect.audioLimiterKind)
    }
}
