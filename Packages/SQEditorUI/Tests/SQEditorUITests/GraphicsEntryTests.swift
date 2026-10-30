import Foundation
import Testing
import SQCore
@testable import SQEditorUI
@testable import SQInspectorUI

/// Graphics G7: the way from Controls into the Graphics panel, the panel's empty states and Intro and Outro.
@MainActor @Suite struct GraphicsEntryTests {
    private func session() -> EditorSession {
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [Track(kind: .video), Track(kind: .audio)])
        return EditorSession(project: Project(name: "P", timelines: [t]))
    }

    private func clip(_ kind: String?) -> Clip {
        Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: .zero,
             generator: kind.map { GeneratorRef(kind: $0, payload: Data()) })
    }

    @Test func graphicsClipGetsTheGraphicSectionInControls() throws {
        let s = session()
        let e = GraphicsEditor(session: s)
        e.newGraphicsClip()
        e.addShape(.rectangle)
        e.addText()
        let c = try #require(e.clip)
        #expect(ClipSectionMode.resolve(c) == .graphic)
        #expect(ClipSectionMode.graphic.title == "Graphic")
        #expect(ClipSectionMode.layerSummary(c) == "2 layers")
        #expect(ClipSectionMode.resolve(clip(GeneratorRef.text)) == .text)    // text and shape clips keep their sections
        #expect(ClipSectionMode.resolve(clip(GeneratorRef.shape)) == .shape)
    }

    @Test func layerSummaryCountsOne() throws {
        let s = session()
        let e = GraphicsEditor(session: s)
        e.newGraphicsClip()
        e.addShape(.ellipse)
        #expect(ClipSectionMode.layerSummary(try #require(e.clip)) == "1 layer")
    }

    @Test func panelHeaderShowsNameAndLayerCount() throws {
        let s = session()
        let e = GraphicsEditor(session: s)
        let panel = GraphicsPanelView(editor: e)
        e.newGraphicsClip()
        e.addShape(.rectangle)
        panel.sync([.project, .selection])
        let c = try #require(e.clip)
        #expect(panel.headerBar.summary == "\(c.name) · 1 layer")
    }

    @Test func emptyStateFollowsTheSelectedClip() {
        #expect(GraphicsEmptyState.resolve(nil) == .noGraphic)
        #expect(GraphicsEmptyState.resolve(clip(nil)) == .noGraphic)
        #expect(GraphicsEmptyState.resolve(clip(GeneratorRef.text)) == .editedInControls)
        #expect(GraphicsEmptyState.resolve(clip(GeneratorRef.shape)) == .editedInControls)
        #expect(GraphicsEmptyState.resolve(clip(GeneratorRef.graphics)) == nil)
        #expect(GraphicsEmptyState.editedInControls.title == "Edited in Controls")
    }
}
