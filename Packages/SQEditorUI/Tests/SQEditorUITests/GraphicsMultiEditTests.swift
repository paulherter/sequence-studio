import Foundation
import Testing
import SQCore
@testable import SQEditorUI
@testable import SQInspectorUI

/// Graphics panel Arrange + Transform: several layers at once, mixed values, anchor, non-uniform scale, align to frame.
@MainActor @Suite struct GraphicsMultiEditTests {
    private func editor() -> (EditorSession, GraphicsEditor, [UUID]) {
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [Track(kind: .video), Track(kind: .audio)])
        let s = EditorSession(project: Project(name: "P", timelines: [t]))
        let e = GraphicsEditor(session: s)
        e.newGraphicsClip()
        e.addShape(.rectangle)
        e.addShape(.ellipse)
        let ids = e.document?.layers.map(\.id) ?? []
        return (s, e, ids)
    }

    @Test func equalValuesShowMixedValuesAreNil() {
        let (_, e, ids) = editor()
        e.select([ids[0]])
        e.setValue(.position, axis: 0, 100)
        e.select(Set(ids))
        #expect(e.value(.position, axis: 0) == nil)              // 100 vs 0: mixed
        #expect(e.value(.position, axis: 1) == 0)                // both 0
        #expect(e.value(.opacity) == 1)
        #expect(e.blendMode == .normal)
    }

    @Test func oneEditSetsEverySelectedLayerInOneStep() {
        let (s, e, ids) = editor()
        e.select([ids[0]])
        e.setValue(.position, axis: 1, 40)
        e.select(Set(ids))
        let depth = s.undoDepth
        e.beginGesture()
        e.setValue(.position, axis: 0, -200)                      // X only: each layer keeps its own Y
        e.setValue(.position, axis: 0, -250)
        #expect(s.undoDepth == depth + 1)
        #expect(e.document?.layer(ids[0])?.animation.position.value == Vec2(-250, 40))
        #expect(e.document?.layer(ids[1])?.animation.position.value == Vec2(-250, 0))
        e.beginGesture()
        e.setBlendMode(.screen)
        #expect(e.document?.layers.allSatisfy { $0.blendMode == .screen } == true)
        #expect(s.undoDepth == depth + 2)
    }

    @Test func anchorIsEditableAndKeyable() {
        let (s, e, ids) = editor()
        e.select([ids[0]])
        e.setValue(.anchor, axis: 0, 12)
        #expect(e.document?.layer(ids[0])?.animation.anchor.value == Vec2(12, 0))
        e.toggleKeyframing(.anchor)
        #expect(e.isKeyed(.anchor) && s.undoName == "Animate Anchor")
        s.seek(to: Time(1, 1))
        e.beginGesture()
        e.setValue(.anchor, axis: 1, 30)
        #expect(e.keyCount(.anchor) == 2)
        #expect(e.document?.layer(ids[0])?.animation.anchor.value(atLocal: Time(1, 1)) == Vec2(12, 30))
    }

    @Test func scaleIsNonUniformAndLinkKeepsEachRatio() {
        let (_, e, ids) = editor()
        e.select([ids[0]])
        e.setValue(.scale, axis: 0, 2)                            // X only
        #expect(e.document?.layer(ids[0])?.animation.scale.value == Vec2(2, 1))
        e.select(Set(ids))
        e.setScaleLinked(axis: 0, 4)                              // both X to 4, Y in each layer's ratio
        #expect(e.document?.layer(ids[0])?.animation.scale.value == Vec2(4, 2))
        #expect(e.document?.layer(ids[1])?.animation.scale.value == Vec2(4, 4))
        #expect(e.value(.scale, axis: 0) == 4 && e.value(.scale, axis: 1) == nil)
    }

    @Test func keyButtonsKeyEverySelectedLayer() {
        let (s, e, ids) = editor()
        e.select(Set(ids))
        e.toggleKeyframing(.rotation)
        #expect(e.document?.layers.allSatisfy { $0.animation.rotation.isAnimated } == true)
        #expect(e.isKeyed(.rotation))
        s.seek(to: Time(1, 1))
        e.toggleKeyAtPlayhead(.rotation)
        #expect(e.document?.layers.allSatisfy { $0.animation.rotation.track.keys.count == 2 } == true)
        e.toggleKeyframing(.rotation)                              // off for all
        #expect(e.document?.layers.allSatisfy { !$0.animation.rotation.isAnimated } == true)
    }

    @Test func alignToFrameMovesEachLayerToTheEdge() throws {
        let (_, e, ids) = editor()
        e.select([ids[0]])
        e.setValue(.position, axis: 0, 300)
        e.select(Set(ids))
        e.align(.left, toFrame: true)
        let d = try #require(e.document)
        let a = try #require(d.bounds(of: ids[0], atLocal: .zero)), b = try #require(d.bounds(of: ids[1], atLocal: .zero))
        #expect(a.minX == -e.canvas.x / 2 && b.minX == -e.canvas.x / 2)
    }

    @Test func editsOnAnotherSelectionAreTheirOwnUndoStep() {
        let (s, e, ids) = editor()
        e.select([ids[0]])
        let depth = s.undoDepth
        e.setValue(.rotation, 10)
        e.setValue(.rotation, 20)                                          // same selection, same gesture: one step
        #expect(s.undoDepth == depth + 1)
        e.select([ids[1]])
        e.setValue(.rotation, 30)                                          // another layer: its own step
        #expect(s.undoDepth == depth + 2)
        e.setBlendMode(.screen)
        e.select([ids[0]])
        e.setBlendMode(.multiply)
        #expect(s.undoDepth == depth + 4)
        _ = s.undo()
        #expect(e.document?.layer(ids[1])?.blendMode == .screen)
    }
}
