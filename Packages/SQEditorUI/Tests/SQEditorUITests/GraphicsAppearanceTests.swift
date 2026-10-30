import Foundation
import Testing
import SQCore
@testable import SQEditorUI
@testable import SQInspectorUI

/// Graphics panel Shape + Appearance: keyable shape parameters, the Shadow row, shape kind, the Outline wording.
@MainActor @Suite struct GraphicsAppearanceTests {
    private func editor() -> (EditorSession, GraphicsEditor) {
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [Track(kind: .video), Track(kind: .audio)])
        let s = EditorSession(project: Project(name: "P", timelines: [t]))
        let e = GraphicsEditor(session: s)
        e.newGraphicsClip()
        e.addShape(.rectangle)
        return (s, e)
    }

    @Test func shapeParametersAreKeyable() throws {
        let (s, e) = editor()
        let p = GraphicsEditor.Property.shape(ClipEffect.shapeStrokeWidthKey)
        #expect(!e.isKeyed(p))
        e.toggleKeyframing(p)
        #expect(e.isKeyed(p) && e.keyCount(p) == 1)
        #expect(s.undoName == "Animate Outline Width")
        s.seek(to: Time(1, 1))
        e.beginGesture()
        e.setValue(p, 20)
        #expect(e.keyCount(p) == 2)
        let fx = try #require(e.selectedLayer?.shapeEffect)
        #expect(fx.scalar(ClipEffect.shapeStrokeWidthKey, atLocal: Time(1, 1)) == 20)
        #expect(fx.scalar(ClipEffect.shapeStrokeWidthKey, atLocal: .zero) == 8)
        e.toggleKeyframing(p)
        #expect(!e.isKeyed(p))
    }

    private func shadows(_ e: GraphicsEditor) -> [ClipEffect] {
        e.selectedLayer?.effects.filter { $0.kind == ClipEffect.dropShadowKind } ?? []
    }

    @Test func shadowWithNoneAddsOneAndOffKeepsIt() {
        let (s, e) = editor()
        #expect(e.shadowState == false && shadows(e).isEmpty)
        let depth = s.undoDepth
        e.setShadow(false)                                                 // nothing to switch off: no step
        #expect(s.undoDepth == depth && shadows(e).isEmpty)
        e.setShadow(true)
        #expect(shadows(e).count == 1 && e.shadowState == true && s.undoDepth == depth + 1)
        e.setShadow(true)                                                  // already on: nothing changes
        #expect(shadows(e).count == 1 && s.undoDepth == depth + 1)
        let dist = GraphicsEditor.Property.effect(kind: ClipEffect.dropShadowKind, key: ClipEffect.shadowDistanceKey)
        e.setValue(dist, 30)
        e.setShadow(false)                                                 // off: switched off, settings kept
        #expect(shadows(e).count == 1 && shadows(e)[0].enabled == false && e.shadowState == false)
        #expect(e.value(dist) == 30)
        e.setShadow(true)
        #expect(shadows(e).count == 1 && shadows(e)[0].enabled && e.value(dist) == 30)
    }

    @Test func shadowRowTouchesOnlyTheFirstOfTwoShadows() throws {
        let (_, e) = editor()
        e.addEffect(ClipEffect.dropShadowKind)
        e.addEffect(ClipEffect.dropShadowKind)
        let second = try #require(shadows(e).last)
        e.setShadow(false)
        #expect(shadows(e).count == 2)
        #expect(shadows(e)[0].enabled == false)
        #expect(shadows(e)[1] == second)                                   // untouched
        #expect(e.shadowState == false)                                    // the row shows the first one
        e.setShadow(true)
        #expect(shadows(e)[0].enabled && shadows(e)[1] == second && e.shadowState == true)
    }

    @Test func shadowOffKeepsKeyframes() throws {
        let (s, e) = editor()
        e.setShadow(true)
        let p = GraphicsEditor.Property.effect(kind: ClipEffect.dropShadowKind, key: ClipEffect.shadowDistanceKey)
        e.toggleKeyframing(p)
        s.seek(to: Time(1, 1))
        e.beginGesture()
        e.setValue(p, 40)
        #expect(e.keyCount(p) == 2)
        e.setShadow(false)
        e.setShadow(true)
        #expect(e.keyCount(p) == 2)
        let fx = try #require(shadows(e).first)
        #expect(fx.scalar(ClipEffect.shadowDistanceKey, atLocal: Time(1, 1)) == 40)
    }

    @Test func shadowStateIsMixedAcrossLayers() {
        let (_, e) = editor()
        let first = e.selectedLayers
        e.setShadow(true)
        e.addShape(.ellipse)
        e.select(first.union(e.selectedLayers))
        #expect(e.shadowState == nil)
        e.setShadow(true)
        #expect(e.shadowState == true)
        #expect(e.targetLayers.allSatisfy { $0.effects.filter { $0.kind == ClipEffect.dropShadowKind }.count == 1 })
    }

    @Test func shapeKindChangesTheOutlineAndALineGetsAnOutline() {
        let (_, e) = editor()
        #expect(e.shapeKind == .rectangle)
        e.setShapeKind(.line)
        #expect(e.shapeKind == .line)
        #expect(e.shapeValue(ClipEffect.shapeStrokeKey) == 1)            // a line is drawn with its outline
        e.addShape(.ellipse)
        e.selectAllLayers()
        #expect(e.shapeKind == nil)                                         // mixed
    }

    @Test func shapeParamsSayOutline() {
        #expect(EffectCatalog.param(ClipEffect.shapeEffectKind, ClipEffect.shapeStrokeKey)?.title == "Outline")
        #expect(EffectCatalog.param(ClipEffect.shapeEffectKind, ClipEffect.shapeStrokeColorKey)?.title == "Outline Color")
        #expect(EffectCatalog.param(ClipEffect.shapeEffectKind, ClipEffect.shapeStrokeWidthKey)?.title == "Outline Width")
    }
}
