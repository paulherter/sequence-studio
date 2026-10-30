import Foundation
import Testing
import SQCore
@testable import SQEditorSession

@MainActor @Suite struct VoiceChainSessionTests {
    @Test func voiceChainSetsTheDialogueRoleInOneUndoStepAndToggles() {
        let a = Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero)
        let b = Clip(name: "b", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero)
        var t1 = Track(kind: .audio), t2 = Track(kind: .audio)
        try! t1.overwrite(a); try! t2.overwrite(b)
        let sess = EditorSession(project: Project(name: "P", timelines: [Timeline(name: "T", frameDuration: Time(1, 30), tracks: [t1, t2])]))
        sess.select(clips: [a.id], captions: [])
        let depth = sess.undoDepth
        #expect(sess.toggleVoiceChain())
        #expect(sess.undoDepth == depth + 1)
        #expect(sess.activeTimeline!.tracks[0].audioRole == .dialogue && sess.activeTimeline!.tracks[1].audioRole == nil)
        #expect(sess.voiceChainActive)
        #expect(sess.toggleVoiceChain())
        #expect(sess.activeTimeline!.tracks[0].audioRole == nil)
        sess.undo()
        #expect(sess.activeTimeline!.tracks[0].audioRole == .dialogue)
    }

    @Test func readoutIsNilWhenNothingIsMeasurable() async {
        let a = Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero)
        var t1 = Track(kind: .audio)
        try! t1.overwrite(a)
        let sess = EditorSession(project: Project(name: "P", timelines: [Timeline(name: "T", frameDuration: Time(1, 30), tracks: [t1])]))
        sess.select(clips: [a.id], captions: [])
        let depth = sess.undoDepth
        let r = await sess.voiceChainReadout()
        #expect(r == nil)
        #expect(sess.undoDepth == depth)
    }
}
