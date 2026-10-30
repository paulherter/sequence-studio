import Foundation
import Testing
import SQCore
@testable import SQEditorSession

@MainActor @Suite struct QuickApplyApplyTests {
    private let fd = Time(1, 30)
    private func make() -> (EditorSession, Clip) {
        let c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(seconds: 10)), start: .zero,
                     mediaDuration: Time(seconds: 10))
        var t = Track(kind: .video); try! t.overwrite(c)
        let ses = EditorSession(project: Project(name: "P", timelines: [Timeline(name: "T", frameDuration: fd, tracks: [t])]), engine: StubProgramEngine())
        return (ses, c)
    }
    private func row(_ a: QuickApplyItem.Action, _ title: String = "Row") -> QuickApplyItem {
        QuickApplyItem(id: "x", title: title, category: "Effect", action: a)
    }

    @Test func effectRowAddsTheEffectToTheSelectedClip() {
        let (ses, c) = make()
        ses.select(clips: [c.id], captions: [])
        let out = ses.applyQuickApply(row(.effect(ClipEffect.gaussianBlurKind)), presets: [], timelineEdges: nil)
        #expect(out == .status(nil, seconds: 4))
        #expect(ses.activeTimeline?.tracks[0].clips[0].effects.contains { $0.kind == ClipEffect.gaussianBlurKind } == true)
    }

    @Test func effectRowWithoutSelectionIsRefused() {
        let (ses, _) = make()
        ses.select(clips: [], captions: [])
        let out = ses.applyQuickApply(row(.effect(ClipEffect.gaussianBlurKind), "Gaussian Blur"), presets: [], timelineEdges: nil)
        #expect(out == .status("Select a video clip to apply Gaussian Blur.", seconds: 3))
    }

    @Test func commandsSheetsAndMacrosAreHandedBackToTheHost() {
        let (ses, c) = make()
        ses.select(clips: [c.id], captions: [])
        #expect(ses.applyQuickApply(row(.command(.videoFadeIn)), presets: [], timelineEdges: nil) == .command(.videoFadeIn))
        #expect(ses.applyQuickApply(row(.saveStackAsPreset), presets: [], timelineEdges: nil) == .saveStackAsPreset)
        #expect(ses.applyQuickApply(row(.macro("cleanVoice")), presets: [], timelineEdges: nil) == .macro(QuickApplyMacro.builtIn[0]))
    }

    @Test func transitionClipsAreTheSelectedClipsOfThatTrackKind() {
        let (ses, c) = make()
        ses.select(clips: [c.id], captions: [])
        #expect(ses.quickApplyTransitionClips(for: row(.transition(.crossDissolve))) == [c.id])
        #expect(ses.quickApplyTransitionClips(for: row(.effect(ClipEffect.gaussianBlurKind))).isEmpty)
        #expect(ses.quickApplyTransitionClips(for: nil).isEmpty)
    }
}
