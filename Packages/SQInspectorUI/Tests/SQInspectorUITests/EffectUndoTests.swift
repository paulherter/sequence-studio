import Foundation
import SQCore
import Testing
@testable import SQInspectorUI

/// Adding an effect (drop, double-click) and removing it in Effect Controls are undo steps of the session.
@MainActor
@Suite struct EffectUndoTests {
    private func setup() throws -> (EditorSession, EffectControlsModel, Clip.ID) {
        let c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(5, 1)), start: .zero,
                     mediaDuration: Time(60, 1))
        var tr = Track(kind: .video)
        try tr.overwrite(c)
        let session = EditorSession(project: Project(name: "P", timelines: [Timeline(name: "T", frameDuration: Time(1, 30), tracks: [tr])]))
        let model = EffectControlsModel()
        model.onEdit = { [weak session] clip, name, coalescing in
            session?.replaceDisplayedClip(clip, name: name, continuesGesture: coalescing)
        }
        session.onChange = { [unowned session] ch in model.sync(with: session, change: ch) }
        session.select(clips: [c.id])
        return (session, model, c.id)
    }

    private func effects(_ s: EditorSession, _ id: Clip.ID) -> [ClipEffect] {
        s.activeTimeline?.tracks.flatMap(\.clips).first { $0.id == id }?.effects ?? []
    }

    @Test func addEffectUndoesAndRedoes() throws {
        let (s, _, id) = try setup()
        #expect(s.addEffect(kind: ClipEffect.colorKind, to: [id]))
        #expect(effects(s, id).count == 1)
        #expect(s.undo())
        #expect(effects(s, id).isEmpty)
        #expect(s.redo())
        #expect(effects(s, id).count == 1)
    }

    @Test func removeEffectInControlsUndoesToTheEffect() throws {
        let (s, m, id) = try setup()
        #expect(s.addEffect(kind: ClipEffect.colorKind, to: [id]))
        let section = try #require(m.visibleSections.first { $0.effectID != nil })
        let depth = s.undoStepDepth
        #expect(m.removeEffect(section))
        #expect(effects(s, id).isEmpty)
        #expect(s.undoStepDepth == depth + 1)
        #expect(s.undo())
        #expect(effects(s, id).count == 1)
        #expect(s.activeTimeline?.tracks.flatMap(\.clips).contains { $0.id == id } == true)
    }
}
