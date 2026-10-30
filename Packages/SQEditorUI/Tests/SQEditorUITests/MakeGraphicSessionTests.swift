import Foundation
import Testing
import SQCore
import SQText
@testable import SQEditorUI
@testable import SQInspectorUI

/// Make Graphic (G9): session command, context menu entry and the Graphics panel button.
@MainActor @Suite struct MakeGraphicSessionTests {
    private func session() -> (EditorSession, Clip.ID) {
        let v = Track(kind: .video)
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [v, Track(kind: .audio)])
        var p = Project(name: "P", timelines: [t])
        let id = try! p.addShapeClip(.ellipse, in: t.id, at: .zero, track: v.id, duration: Time(3, 1))
        let s = EditorSession(project: p)
        s.select(clips: [id])
        return (s, id)
    }

    @Test func makeGraphicIsOneUndoStep() throws {
        let (s, id) = session()
        #expect(s.makeGraphic())
        #expect(s.project.graphicsClip(id)?.graphics?.layers.count == 1)
        #expect(s.selection == [id])
        s.undo()
        #expect(s.project.graphicsClip(id) == nil)
        #expect(!s.project.timelines[0].tracks[0].clips.isEmpty)
    }

    @Test func makeGraphicRefusesOtherSelections() {
        let (s, id) = session()
        s.makeGraphic()
        #expect(!s.makeGraphic())          // already a graphic
        s.select(clips: [])
        #expect(!s.makeGraphic())
        _ = id
    }

    @Test func contextMenuOffersMakeGraphicForOneTextOrShapeClip() throws {
        let (s, id) = session()
        let tl = try #require(s.activeTimeline)
        func item(_ sel: Set<Clip.ID>, _ t: Timeline) -> TimelineMenuItem? {
            TimelineContextMenu.items(timeline: t, selection: sel, clipboardHasClips: false).first { $0.action == .makeGraphic }
        }
        #expect(item([id], tl)?.isEnabled == true)
        #expect(item([], tl)?.isEnabled == false)
        s.makeGraphic()
        #expect(item([id], try #require(s.activeTimeline))?.isEnabled == false)
    }

    @Test func panelButtonConvertsTheSelectedClip() throws {
        let (s, id) = session()
        let panel = GraphicsPanelView(editor: GraphicsEditor(session: s))
        panel.onMakeGraphic = { s.makeGraphic() }
        panel.sync([.project, .selection])
        panel.onMakeGraphic?()
        panel.sync([.project, .selection])
        #expect(panel.editor.clip?.id == id)
    }

    @Test func realTextPayloadIsCopiedAndRendersTheSame() throws {
        let v = Track(kind: .video)
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [v])
        var p = Project(name: "P", timelines: [t])
        let ref = try TextGenerator.makeRef(template: TextTemplate(name: "T", text: "Hello",
                                            style: CaptionPresetLibrary.builtIn.style(for: "title")), animations: nil)
        let id = try p.addGeneratorClip(kind: ref.kind, payload: ref.payload, payloadVersion: ref.payloadVersion, name: "Title",
                                        in: t.id, at: .zero, track: v.id, duration: Time(3, 1))
        let before = p.timeline(t.id)!.videoLayers(at: Time(1, 1))
        try p.convertToGraphics(clipID: id)
        let c = try #require(p.graphicsClip(id))
        guard case .text(let r) = c.graphics!.layers[0].content else { Issue.record("not text"); return }
        #expect(r == ref)
        let after = p.timeline(t.id)!.videoLayers(at: Time(1, 1))
        #expect(after[0].generator == before[0].generator && after[0].localTime == before[0].localTime)
        #expect(after[0].groups[0].transform == before[0].transform && after[0].groups[0].effects == before[0].effects)
    }
}
