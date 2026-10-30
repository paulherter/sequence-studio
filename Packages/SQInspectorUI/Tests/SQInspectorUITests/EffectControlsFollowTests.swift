import Foundation
import Testing
import SQCore
@testable import SQInspectorUI

private func s(_ n: Int64) -> Time { Time(n, 1) }

@MainActor @Suite struct EffectControlsFollowTests {
    private func rig() throws -> (EditorSession, EffectControlsModel, video: Clip, audio: Clip, other: Clip) {
        let link = UUID()
        let v = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(2)), start: .zero, link: link)
        let a = Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(2)), start: .zero, link: link)
        let o = Clip(name: "o", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(2)), start: s(2))
        var v1 = Track(kind: .video), a1 = Track(kind: .audio)
        try v1.overwrite(v); try v1.overwrite(o); try a1.overwrite(a)
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [v1, a1])
        let session = EditorSession(project: Project(name: "P", timelines: [t]))
        let model = EffectControlsModel()
        session.onChange = { [unowned session] c in model.sync(with: session, change: c) }
        return (session, model, v, a, o)
    }

    @Test func selectionDrivesTheModel() throws {
        let (session, model, v, a, o) = try rig()
        #expect(model.clip == nil)
        session.select(clips: [o.id])
        #expect(model.clip?.id == o.id)
        // A click on a clip with linked audio selects both: Effect Controls shows the video clip.
        session.select(clips: [v.id, a.id])
        #expect(model.clip?.id == v.id)
        // Unrelated clips: multi-select editing shows the first and edits all (EffectControlsMultiTests).
        session.select(clips: [v.id, o.id])
        #expect(model.clip?.id == v.id && model.peers.map(\.id) == [o.id])
        session.select(clips: [a.id])
        #expect(model.clip?.id == a.id && model.visibleSections == [.volume])
        session.select(clips: [])
        #expect(model.clip == nil)
    }

    @Test func undoRedoAndPlayheadUpdateTheModel() throws {
        let (session, model, v, _, _) = try rig()
        session.select(clips: [v.id])
        var edited = v
        edited.roundedCorners = .roundedCorners(radius: 12)
        model.onEdit = { c, name, co in session.replaceClip(c, name: name, continuesGesture: co) }
        model.onEdit?(edited, "Radius", false)
        #expect(model.clip?.roundedCorners?.parameters[ClipEffect.radiusKey]?.value == 12)
        session.undo()
        #expect(model.clip?.roundedCorners == nil)
        session.redo()
        #expect(model.clip?.roundedCorners?.parameters[ClipEffect.radiusKey]?.value == 12)
        session.seek(to: s(1))
        #expect(model.playhead == s(1))
    }

    @Test func sequenceSettingsIsOneUndoStepAndKeepsClips() throws {
        let (session, _, _, _, _) = try rig()
        let before = session.activeTimeline?.tracks
        let f = SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 30), audioSampleRate: 48_000)
        #expect(session.setSequenceFormat(f))
        #expect(session.activeTimeline?.format == f && session.activeTimeline?.tracks == before)
        #expect(!session.setSequenceFormat(f))
        session.undo()
        #expect(session.activeTimeline?.format.width == 1920)
    }

    @Test func newSequenceUsesGivenFormatAndName() throws {
        let (session, _, _, _, _) = try rig()
        let f = SequenceFormat(width: 2160, height: 3840, frameDuration: Time(1, 60))
        let id = session.addSequence(name: "Reel", format: f)
        #expect(session.activeTimelineID == id)
        #expect(session.activeTimeline?.name == "Reel" && session.activeTimeline?.format == f)
    }
}
