import Foundation
import Testing
import SQCore
import SQText
@testable import SQEditorUI
@testable import SQInspectorUI

// Dragging a corner handle of a text layer inside a Graphic changes its font size; Scale stays. Shapes keep scaling.

@MainActor @Suite struct GraphicsTextResizeTests {
    private func setup() throws -> (EditorSession, GraphicsEditor, text: UUID, shape: UUID) {
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [Track(kind: .video), Track(kind: .audio)])
        let s = EditorSession(project: Project(name: "P", timelines: [t]))
        let e = GraphicsEditor(session: s)
        try #require(e.newGraphicsClip() != nil)
        e.addShape(.rectangle)
        let shape = try #require(e.selectedLayers.first)
        let ref = try TextGenerator.makeRef(
            template: TextTemplate(name: "T", text: "Hello", style: TextStyle(size: 80, lineSpacing: 4, tracking: 2)),
            animations: AnimationSet(in: nil, out: nil))
        let layer = GraphicsLayer.text(ref)
        var c = try #require(e.clip)
        var doc = try #require(c.graphics)
        doc.layers.append(layer)
        c.graphics = doc
        s.replaceClip(c, name: "Add Text", continuesGesture: false)
        e.sync()
        return (s, e, layer.id, shape)
    }

    private func template(_ e: GraphicsEditor, _ id: UUID) throws -> TextTemplate {
        guard case .text(let ref) = try #require(e.document?.layer(id)).content else { throw CocoaError(.fileReadUnknown) }
        return try TextGenerator.decode(ref).0
    }

    @Test func cornerDragChangesFontSizeAndKeepsScaleAndOppositeCorner() throws {
        let (s, e, text, _) = try setup()
        let layer = try #require(e.document?.layer(text))
        let cs = try #require(layer.corners(atLocal: e.localTime, text: e.textMeasure))
        let scale0 = layer.animation.scale.value(atLocal: e.localTime)
        let depth = s.undoDepth
        let tl = cs[0], br = cs[2]
        let target = Vec2(tl.x + (br.x - tl.x) * 1.5, tl.y + (br.y - tl.y) * 1.5)
        e.beginGesture()
        e.resize(text, corner: .bottomRight, to: target, keepAspect: false)
        e.endGesture()
        let t = try template(e, text)
        #expect(abs(t.style.size - 120) < 0.5)
        #expect(abs(t.style.tracking - 3) < 0.05)
        let after = try #require(e.document?.layer(text))
        #expect(after.animation.scale.value(atLocal: e.localTime) == scale0)
        let cs2 = try #require(after.corners(atLocal: e.localTime, text: e.textMeasure))
        #expect(abs(cs2[0].x - tl.x) < 0.5 && abs(cs2[0].y - tl.y) < 0.5)
        #expect(s.undoDepth == depth + 1)
        #expect(s.undoName == "Resize Text")
    }

    @Test func aDragOfSeveralStepsIsOneUndoStep() throws {
        let (s, e, text, _) = try setup()
        let layer = try #require(e.document?.layer(text))
        let cs = try #require(layer.corners(atLocal: e.localTime, text: e.textMeasure))
        let depth = s.undoDepth
        e.beginGesture()
        for k in [1.1, 1.3, 1.6] {
            e.resize(text, corner: .bottomRight,
                     to: Vec2(cs[0].x + (cs[2].x - cs[0].x) * k, cs[0].y + (cs[2].y - cs[0].y) * k), keepAspect: false)
        }
        e.endGesture()
        #expect(s.undoDepth == depth + 1)
        #expect(try template(e, text).style.size > 120)
        _ = s.undo()
        #expect(try template(e, text).style.size == 80)
    }

    @Test func shapesKeepScaling() throws {
        let (_, e, _, shape) = try setup()
        let l = try #require(e.document?.layer(shape))
        let cs = try #require(l.corners(atLocal: e.localTime, text: e.textMeasure))
        e.beginGesture()
        e.resize(shape, corner: .bottomRight, to: Vec2(cs[2].x + 50, cs[2].y + 50), keepAspect: false)
        e.endGesture()
        let after = try #require(e.document?.layer(shape))
        let a = try #require(after.corners(atLocal: e.localTime, text: e.textMeasure))
        #expect(a[2].x > cs[2].x + 40)
    }
}
