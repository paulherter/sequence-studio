import Testing
import SQCore
@testable import SQEditorUI
@testable import SQInspectorUI

@MainActor @Suite struct GraphicsEditorTests {
    private func session() -> EditorSession {
        let t = Timeline(name: "Main", frameDuration: Time(1, 30),
                         tracks: [Track(kind: .video), Track(kind: .video), Track(kind: .audio)])
        return EditorSession(project: Project(name: "P", timelines: [t]))
    }

    @Test func newGraphicsClipIsSelectedAsOneUndoStep() throws {
        let s = session()
        let e = GraphicsEditor(session: s)
        let depth = s.undoDepth
        let id = try #require(e.newGraphicsClip())
        #expect(s.undoDepth == depth + 1)
        #expect(e.clip?.id == id)
        #expect(e.document?.layers.isEmpty == true)
    }

    @Test func deleteWithoutLayerSelectionKeepsTheClip() throws {
        let s = session()
        let e = GraphicsEditor(session: s)
        let id = try #require(e.newGraphicsClip())
        e.addShape(.rectangle)
        e.addShape(.ellipse)
        e.selectAllLayers()
        #expect(e.selectedLayers.count == 2)
        e.deleteSelected()
        #expect(e.document?.layers.isEmpty == true)
        #expect(e.clip?.id == id)          // the clip survives
        let depth = s.undoDepth
        e.deleteSelected()                 // nothing selected: no-op, no undo step
        #expect(s.undoDepth == depth)
        #expect(e.clip?.id == id)
    }

    @Test func addSelectsTheNewLayerAboveTheSelection() throws {
        let s = session()
        let e = GraphicsEditor(session: s)
        e.newGraphicsClip()
        e.addShape(.rectangle)
        let first = try #require(e.selectedLayers.first)
        e.addShape(.ellipse)
        let second = try #require(e.selectedLayers.first)
        #expect(e.document?.layers.map(\.id) == [first, second])
        e.select([first])
        e.addShape(.line)
        let third = try #require(e.selectedLayers.first)
        #expect(e.document?.layers.map(\.id) == [first, third, second])
        let depth = s.undoDepth
        e.deleteSelected()
        #expect(s.undoDepth == depth + 1 && e.selectedLayers.isEmpty)
        #expect(e.document?.layers.count == 2)
    }

    @Test func dragMergesIntoOneUndoStepPerGesture() throws {
        let s = session()
        let e = GraphicsEditor(session: s)
        e.newGraphicsClip()
        e.addShape(.rectangle)
        let id = try #require(e.selectedLayers.first)
        let depth = s.undoDepth
        e.beginGesture()
        e.translateSelected(by: Vec2(10, 0))
        e.translateSelected(by: Vec2(5, 5))
        #expect(s.undoDepth == depth + 1)
        #expect(e.document?.layer(id)?.animation.position.value == Vec2(15, 5))
        e.beginGesture()
        e.translateSelected(by: Vec2(1, 0))
        #expect(s.undoDepth == depth + 2)
    }

    @Test func keyNavigationAndToggleAtPlayhead() {
        let s = session()
        let e = GraphicsEditor(session: s)
        e.newGraphicsClip()
        e.addShape(.rectangle)
        #expect(e.keyCount(.opacity) == 0 && e.previousKeyTime(.opacity) == nil && e.nextKeyTime(.opacity) == nil)
        e.toggleKeyframing(.opacity)                        // key at 0
        #expect(e.keyCount(.opacity) == 1 && e.isKeyAtPlayhead(.opacity))
        s.seek(to: Time(1, 1))
        e.toggleKeyAtPlayhead(.opacity)                     // second key
        #expect(e.keyCount(.opacity) == 2 && e.isKeyAtPlayhead(.opacity))
        #expect(e.previousKeyTime(.opacity) == Time(0, 1) && e.nextKeyTime(.opacity) == nil)
        e.toggleKeyAtPlayhead(.opacity)                     // removes it again
        #expect(e.keyCount(.opacity) == 1 && !e.isKeyAtPlayhead(.opacity))
        #expect(e.previousKeyTime(.opacity) == Time(0, 1))
    }

    @Test func keyframeUndoNamesSayWhatAndWhich() {
        let s = session()
        let e = GraphicsEditor(session: s)
        e.newGraphicsClip()
        e.addShape(.rectangle)
        e.toggleKeyframing(.position)
        #expect(s.undoName == "Animate Position")
        s.seek(to: Time(1, 1))
        e.toggleKeyAtPlayhead(.position)
        #expect(s.undoName == "Add Position Keyframe")
        e.toggleKeyAtPlayhead(.position)
        #expect(s.undoName == "Remove Position Keyframe")
        e.toggleKeyframing(.position)
        #expect(s.undoName == "Stop Animating Position")
        #expect(GraphicsEditor.Property.opacity.title == "Opacity")
    }

    @Test func keyframeStateFollowsTheProperty() {
        let s = session()
        let e = GraphicsEditor(session: s)
        e.newGraphicsClip()
        e.addShape(.rectangle)
        #expect(e.keyframeState(.scale) == .off)
        e.toggleKeyframing(.scale)
        let st = e.keyframeState(.scale)
        #expect(st.ring == .onKey && st.showsNavigation && st.keyIsOn && !st.canGoPrevious && !st.canGoNext)
        s.seek(to: Time(1, 1))
        let between = e.keyframeState(.scale)
        #expect(between.ring == .between && between.canGoPrevious && !between.canGoNext && between.canToggleKey)
    }

    @Test func propertiesWriteKeysAtThePlayheadWhenAnimated() throws {
        let s = session()
        let e = GraphicsEditor(session: s)
        e.newGraphicsClip()
        e.addShape(.rectangle)
        e.toggleKeyframing(.opacity)
        #expect(e.isKeyed(.opacity))
        s.seek(to: Time(1, 1))
        e.beginGesture()
        e.setOpacity(0.25)
        let op = try #require(e.selectedLayer?.animation.opacity)
        #expect(op.track.keys.count == 2)
        #expect(op.value(atLocal: Time(1, 1)) == 0.25)
    }

    @Test func otherClipClearsTheLayerSelection() throws {
        let s = session()
        let e = GraphicsEditor(session: s)
        e.newGraphicsClip()
        e.addShape(.rectangle)
        #expect(!e.selectedLayers.isEmpty)
        s.select(clips: [])
        e.sync()
        #expect(e.selectedLayers.isEmpty && e.clip == nil)
    }

    @Test func canvasMappingRoundTrips() {
        var t = ClipTransform.identity
        t.position = Vec2(100, -50); t.scale = Vec2(0.5, 2); t.rotation = 30; t.anchor = Vec2(10, 20)
        let m = GraphicsCanvasMapping(transform: t)
        let q = Vec2(-300, 120)
        let back = m.canvasPoint(fromSequence: m.sequenceOffset(fromCanvas: q))
        #expect(abs(back.x - q.x) < 1e-9 && abs(back.y - q.y) < 1e-9)
        #expect(GraphicsCanvasMapping(transform: .identity).sequenceOffset(fromCanvas: q) == q)
    }

    @Test func textLayerAnimationIsKeptAndIsOneUndoStep() throws {
        let s = session()
        let e = GraphicsEditor(session: s)
        e.newGraphicsClip()
        e.addText("Hello")
        let before = try #require(e.textTemplate)
        #expect(e.textAnimations?.animationIn == nil)
        let m = TextInspectorModel()
        m.setInAnimation("fade")
        let depth = s.undoDepth
        e.updateTextAnimations("Text Animation", m.animations)
        #expect(s.undoDepth == depth + 1)
        #expect(e.textAnimations?.animationIn != nil)
        #expect(e.textTemplate?.style == before.style)
        #expect(e.textTemplate?.text == "Hello")
        // A later style edit keeps the animation.
        e.updateText("Text Style") { $0.style.size = 90 }
        #expect(e.textAnimations?.animationIn != nil)
    }

    @Test func effectDropAppendsToTheLayerAsOneUndoStep() throws {
        let s = session()
        let e = GraphicsEditor(session: s)
        e.newGraphicsClip()
        e.addShape(.rectangle)
        let first = try #require(e.selectedLayers.first)
        e.addShape(.ellipse)
        let depth = s.undoDepth
        // Dropped on the other (not selected) layer's row.
        #expect(e.addEffect(ClipEffect.gaussianBlurKind, to: first) == .added)
        #expect(s.undoDepth == depth + 1)
        #expect(e.document?.layer(first)?.effects.contains { $0.kind == ClipEffect.gaussianBlurKind } == true)
        #expect(e.addEffect(ClipEffect.gaussianBlurKind) == .added)      // selected layer
        #expect(s.undoDepth == depth + 2)
    }

    @Test func effectDropRefusesWhatALayerCannotTake() throws {
        let s = session()
        let e = GraphicsEditor(session: s)
        e.newGraphicsClip()
        e.addShape(.rectangle)
        let depth = s.undoDepth
        for kind in [ClipEffect.shapeEffectKind, "transition.crossDissolve", "nonsense", ClipEffect.audioGainKind] {
            guard case .refused = e.addEffect(kind) else { Issue.record("\(kind) was accepted"); continue }
        }
        #expect(s.undoDepth == depth)
        #expect(GraphicsEditor.layerEffectSpecs.allSatisfy { !HiddenCatalog.isHidden(effectKind: $0.kind) })
    }

    @Test func pointParameterTakesKeysAndValues() throws {
        let s = session()
        let e = GraphicsEditor(session: s)
        e.newGraphicsClip()
        e.addShape(.rectangle)
        let spec = try #require(GraphicsEditor.layerEffectSpecs.first { sp in sp.params.contains { if case .point = $0.kind { true } else { false } } })
        let param = try #require(spec.params.first { if case .point = $0.kind { true } else { false } })
        e.addEffect(spec.kind)
        let p = GraphicsEditor.Property.effectPoint(kind: spec.kind, key: param.key)
        e.setValue(p, axis: 0, 12)
        e.setValue(p, axis: 1, -7)
        #expect(e.value(p, axis: 0) == 12)
        #expect(e.value(p, axis: 1) == -7)
        e.toggleKeyframing(p)
        #expect(e.isKeyed(p))
        e.toggleKeyframing(p)
        #expect(!e.isKeyed(p))
    }

    @Test func easeOfALayerKeyIsStoredLikeAClipKeyAndIsOneUndoStep() throws {
        let s = session()
        let e = GraphicsEditor(session: s)
        e.newGraphicsClip()
        e.addShape(.rectangle)
        let id = try #require(e.selectedLayers.first)
        e.toggleKeyframing(.opacity)                       // key at the playhead
        let c = try #require(e.clip)
        s.seek(to: c.start + Time(1, 1))
        e.toggleKeyAtPlayhead(.opacity)                    // second key
        s.seek(to: c.start)
        let depth = s.undoDepth
        e.setKeyEase(.opacity, .easeIn)
        #expect(s.undoDepth == depth + 1)
        let keys = try #require(e.document?.layer(id)?.animation.opacity.track.keys)
        #expect(keys.count == 2)
        // Playhead sits on the first key: only that key changed.
        #expect(keys[0].outHandle == EasingCurve.easeIn.outHandle && keys[0].interpolation == EasingCurve.easeIn.interpolation)
        #expect(keys[0].inHandle == EasingCurve.easeIn.inHandle)
        #expect(keys[1].inHandle == .linear && keys[1].outHandle == .linear)   // the other key is untouched
        #expect(e.keyEaseName(.opacity) == EaseName.smoothIn)
        // Custom curve: shape stored as drawn, named Custom.
        let shape = EaseShape(interpolation: .bezier, out: EaseHandle(dx: 0.4, dy: 1.3), in: EaseHandle(dx: 0.2, dy: 0))
        e.setKeyEase(.opacity, EasingCurve(shape: shape, name: EaseName.custom))
        #expect(e.keyEaseShape(.opacity)?.out == shape.out)
        #expect(e.keyEaseName(.opacity) == EaseName.custom)
        // Playhead between keys: nothing is overwritten.
        s.seek(to: c.start + Time(1, 2))
        let before = e.document?.layer(id)?.animation.opacity.track.keys
        let dBetween = s.undoDepth
        e.setKeyEase(.opacity, .hold)
        #expect(e.document?.layer(id)?.animation.opacity.track.keys == before)
        #expect(s.undoDepth == dBetween)
        #expect(e.keyEaseName(.opacity) == nil)
        // Not animated: nothing happens.
        let d2 = s.undoDepth
        e.setKeyEase(.rotation, .hold)
        #expect(s.undoDepth == d2)
    }

    @Test func layerKeyTimesCoverMotionAndEffects() throws {
        let s = session()
        let e = GraphicsEditor(session: s)
        e.newGraphicsClip()
        e.addShape(.rectangle)
        let id = try #require(e.selectedLayers.first)
        #expect(LayerListLogic.keyTimes(try #require(e.document?.layer(id))).isEmpty)
        e.toggleKeyframing(.position)
        let c = try #require(e.clip)
        s.seek(to: c.start + Time(1, 1))
        e.toggleKeyframing(.opacity)
        let times = LayerListLogic.keyTimes(try #require(e.document?.layer(id)))
        #expect(times == [.zero, Time(1, 1)])
    }

    @Test func twoEffectsOfOneKindKeepTheirOwnKeyTracks() throws {
        let s = session()
        let e = GraphicsEditor(session: s)
        e.newGraphicsClip()
        e.addShape(.rectangle)
        let spec = try #require(GraphicsEditor.layerEffectSpecs.first { $0.kind == ClipEffect.mirrorKind })
        let param = try #require(spec.params.first { if case .point = $0.kind { true } else { false } })
        e.addEffect(spec.kind)
        e.addEffect(spec.kind)
        let layer = try #require(e.selectedLayer)
        let ids = layer.effects.filter { $0.kind == spec.kind }.map(\.id)
        #expect(ids.count == 2)
        let p1 = GraphicsEditor.Property.effectPoint(kind: spec.kind, key: param.key, id: ids[0])
        let p2 = GraphicsEditor.Property.effectPoint(kind: spec.kind, key: param.key, id: ids[1])
        e.setValue(p2, axis: 0, 33)
        e.toggleKeyframing(p2)
        #expect(e.isKeyed(p2))
        #expect(!e.isKeyed(p1))
        #expect(e.value(p2, axis: 0) == 33)
        #expect(e.value(p1, axis: 0) != 33)
    }

    @Test func folderDropIsOneUndoStepAndKeepsTheFirstRefusal() throws {
        let s = session()
        let e = GraphicsEditor(session: s)
        e.newGraphicsClip()
        e.addShape(.rectangle)
        let depth = s.undoDepth, had = e.selectedLayer?.effects.count ?? 0
        let r = e.addEffects(["transition.crossDissolve", ClipEffect.gaussianBlurKind, ClipEffect.mirrorKind, "nonsense"])
        #expect(r == .refused("Transitions go on the timeline, not on a layer."))
        #expect(s.undoDepth == depth + 1)
        #expect(e.selectedLayer?.effects.count == had + 2)
        #expect(e.addEffects([ClipEffect.gaussianBlurKind]) == .added)
    }

    @Test func lockedLayersAreSkippedByKeyEdits() throws {
        let s = session()
        let e = GraphicsEditor(session: s)
        e.newGraphicsClip()
        e.addShape(.rectangle)
        let a = try #require(e.selectedLayers.first)
        e.addShape(.ellipse)
        let b = try #require(e.selectedLayers.first { $0 != a })
        e.toggleKeyframing(.opacity)
        e.select([a, b])
        e.setLocked(a, true)
        e.setKeyEase(.opacity, .hold)
        let keysA = e.document?.layer(a)?.animation.opacity.track.keys ?? []
        #expect(keysA.allSatisfy { $0.interpolation != .hold })
    }

    @Test func addEffectMenuListsOnlyTheOfferedCatalog() {
        let kinds = GraphicsEditor.offeredEffects.map(\.kind)
        #expect(!kinds.isEmpty)
        #expect(kinds.allSatisfy { !HiddenCatalog.isHidden(effectKind: $0) && GraphicsEditor.refusalForEffect($0) == nil })
        #expect(!kinds.contains(ClipEffect.audioGainKind))
    }
}
