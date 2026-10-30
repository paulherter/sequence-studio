import Foundation
import Testing
import SQCore
import SQText
@testable import SQEditorUI
@testable import SQInspectorUI

/// Create tools and the Type tool: where a new item goes and what a click or drag does.
@MainActor @Suite struct CreateToolDecisionTests {
    private let template = TextTemplate(name: "Text", text: "Hello", style: TextStyle(fontName: "Helvetica-Bold", size: 80, color: .white))

    private func make() -> (EditorSession, GraphicsEditor, Track.ID) {
        let v = Track(kind: .video)
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [v, Track(kind: .audio)])
        let s = EditorSession(project: Project(name: "P", timelines: [t]))
        return (s, GraphicsEditor(session: s), v.id)
    }

    private func rectangle(_ map: GraphicsCanvasMapping, _ canvas: Vec2) -> GraphicsLayer? {
        GraphicsLayer.shape(.rectangle, canvasWidth: Int(canvas.x), canvasHeight: Int(canvas.y))
    }

    // MARK: Shape with an old text clip selected

    @Test func aShapeWithAnOldTextClipSelectedBecomesALayerOfThatClipInOneUndoStep() throws {
        let (s, g, _) = make()
        let id = try #require(s.addTextClip(template: template, position: .zero))
        s.select(clips: [id])
        s.seek(to: Time(1, 1))
        let clips = s.project.timelines[0].tracks.flatMap(\.clips).count
        let depth = s.undoDepth
        #expect(g.addCreatedItem(named: "Add Rectangle", rectangle))
        #expect(s.project.timelines[0].tracks.flatMap(\.clips).count == clips)   // no new clip
        let doc = try #require(s.project.graphicsClip(id)?.graphics)
        #expect(doc.layers.count == 2)
        #expect(s.undoDepth == depth + 1 && s.history.undoName == "Add Rectangle")
        s.undo()
        #expect(s.project.graphicsClip(id) == nil)   // back to the text clip
    }

    @Test func aShapeWithoutAGraphicOrTextClipSelectedMakesNoLayer() {
        let (s, g, _) = make()
        let depth = s.undoDepth
        #expect(!g.addCreatedItem(named: "Add Rectangle", rectangle))
        #expect(s.undoDepth == depth)
    }

    // MARK: Type tool decision

    @Test func aClickOnEmptyCanvasWithoutAGraphicStartsANewGraphic() {
        let (_, g, _) = make()
        let out = g.typeToolOutcome(at: Vec2(10, 20), box: nil, textClipHit: nil, hitIsPointText: false)
        #expect(out == .newGraphic(at: Vec2(10, 20), box: nil))
    }

    @Test func aDragOnEmptyCanvasWithoutAGraphicKeepsTheBox() {
        let (_, g, _) = make()
        let box = TextBox(width: 300, height: 120)
        let out = g.typeToolOutcome(at: .zero, box: box, textClipHit: nil, hitIsPointText: false)
        #expect(out == .newGraphic(at: .zero, box: box))
    }

    @Test func oldTextClipsAreEditedByClickAndByADragOverPointTextOnly() {
        let (_, g, _) = make()
        let hit = Clip.ID()
        let box = TextBox(width: 100, height: 50)
        #expect(g.typeToolOutcome(at: .zero, box: nil, textClipHit: hit, hitIsPointText: false) == .editTextClip(hit))
        #expect(g.typeToolOutcome(at: .zero, box: box, textClipHit: hit, hitIsPointText: true) == .editTextClip(hit))
        #expect(g.typeToolOutcome(at: .zero, box: box, textClipHit: hit, hitIsPointText: false) == .newGraphic(at: .zero, box: box))
    }

    @Test func insideASelectedGraphicAClickAddsALayerAndADragAddsAreaText() throws {
        let (s, g, _) = make()
        let id = try #require(s.addGraphicsClip())
        s.select(clips: [id])
        g.sync()
        s.seek(to: Time(1, 1))
        let click = g.typeToolOutcome(at: Vec2(40, -30), box: nil, textClipHit: nil, hitIsPointText: false)
        #expect(click == .addLayer(at: Vec2(40, -30), box: nil))
        let box = TextBox(width: 400, height: 150)
        let drag = g.typeToolOutcome(at: Vec2(40, -30), box: box, textClipHit: nil, hitIsPointText: false)
        #expect(drag == .addLayer(at: Vec2(40, -30), box: box))   // the box must survive: area text
    }

    @Test func aDragOverATextLayerEditsItLikeAClick() throws {
        let (s, g, _) = make()
        let id = try #require(s.addGraphicsClip())
        s.select(clips: [id])
        g.sync()
        s.seek(to: Time(1, 1))
        let layer = try #require(g.addText(at: .zero))
        let click = g.typeToolOutcome(at: .zero, box: nil, textClipHit: nil, hitIsPointText: false)
        let drag = g.typeToolOutcome(at: .zero, box: TextBox(width: 50, height: 50), textClipHit: nil, hitIsPointText: false)
        #expect(click == .editLayer(layer) && drag == .editLayer(layer))
    }

    // MARK: Click on existing graphic text

    @Test func textOfAnUnselectedGraphicIsFoundAndAEmptySpotIsNot() throws {
        let (s, g, _) = make()
        let clip = try #require(s.addGraphicsClip(duration: Time(5, 1), neverOverwrite: true))
        g.sync()
        let id = try #require(g.addText(at: Vec2(200, -100)))
        s.select(clips: [])
        g.sync()
        #expect(g.clip == nil)
        let hit = try #require(g.textLayerHit(atSequence: Vec2(200, -100)))
        #expect(hit.clip == clip && hit.layer == id)
        #expect(g.textLayerHit(atSequence: Vec2(-800, 450)) == nil)
    }

    @Test func aNewTextIsReadyForInlineEditingAfterCreation() throws {
        let (s, g, _) = make()
        let depth = s.undoDepth
        _ = try #require(s.addGraphicsClip(duration: Time(5, 1), neverOverwrite: true))
        g.sync()
        let id = try #require(g.addText(at: .zero))
        s.seek(to: s.playhead)
        g.select([id])
        #expect(g.isEditingValid(layer: id, clip: try #require(g.clip).id))
        #expect(g.textEditTarget(for: id) != nil)
        #expect(g.textTemplate != nil)
        #expect(s.undoDepth > depth)
    }
}
