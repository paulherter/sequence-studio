import Foundation
import Testing
import SQCore
import SQText
@testable import SQInspectorUI

/// G10: template fields of a graphics clip (Save as Template slots and the Graphics panel's field list).
@MainActor @Suite struct TemplateFieldsGraphicsTests {
    private func session() throws -> (EditorSession, Clip.ID, [UUID]) {
        let tracks = Timeline.defaultTracks(video: 2, audio: 1)
        let tl = Timeline(name: "T", format: SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 30)), tracks: tracks)
        var p = Project(name: "P", timelines: [tl])
        func text(_ s: String) throws -> GraphicsLayer {
            let ref = try TextGenerator.makeRef(template: TextTemplate(name: s, text: s, style: TextStyle(fontName: "Helvetica-Bold", size: 90, color: .white)), animations: nil)
            return GraphicsLayer(name: s, content: .text(ref: ref))
        }
        let a = try text("Title"), b = try text("Sub")
        let id = try p.addGraphicsClip(in: tl.id, at: .zero, track: tracks[0].id, duration: Time(5, 1),
                                       layers: [a, GraphicsLayer(name: "Box", content: .shape(kind: .rectangle)), b])
        return (EditorSession(project: p), id, [a.id, b.id])
    }

    @Test func saveMakesTextAndStyleSlotsAddressingTheLayers() throws {
        let (s, id, layers) = try session()
        s.select(clips: [id])
        let t = try #require(s.titleTemplateFromSelection(name: "G"))
        #expect(t.slots.map(\.kind) == [.text, .text, .color, .font, .number])
        #expect(t.slots.map(\.graphicsLayer) == [layers[0], layers[1], layers[0], layers[0], layers[0]])
        #expect(t.slots[3].value == .font("Helvetica-Bold"))
        #expect(t.slots[4].value == .number(90))
        // Every slot applies without a missing-path error.
        var p = s.project
        let tl = try #require(s.activeTimelineID)
        let track = try #require(s.activeTimeline?.tracks[1].id)
        _ = try p.applyTitleTemplate(t, in: tl, track: track, at: Time(10, 1), values: Dictionary(uniqueKeysWithValues: t.slots.map { ($0.id, $0.value) }))
    }

    @Test func panelListsTheFields() throws {
        let (s, id, _) = try session()
        let clip = try #require(s.activeTimeline?.tracks.lazy.flatMap(\.clips).first { $0.id == id })
        let f = TemplateFieldsLogic.fields(of: clip)
        #expect(f.map(\.title) == ["Text 1", "Text 2", "Color", "Font", "Size"])
        #expect(f[0].value == "Title")
        #expect(f[3].value == "Helvetica-Bold")
        #expect(TemplateFieldsLogic.fields(of: Clip(name: "c", media: UUID(), kind: .video,
                                                     source: TimeRange(start: .zero, duration: Time(1, 1)), start: .zero)).isEmpty)
    }
}
