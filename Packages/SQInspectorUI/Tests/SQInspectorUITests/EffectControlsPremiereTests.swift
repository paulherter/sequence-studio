import Foundation
import Testing
import SQCore
@testable import SQInspectorUI

@MainActor @Suite struct EffectControlsPremiereTests {
    func clip(_ kind: TrackKind = .video, start: Int64 = 5) -> Clip {
        Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: .zero, duration: Time(10, 1)), start: Time(start, 1))
    }
    func model(_ c: Clip, playhead: Int64 = 5) -> EffectControlsModel {
        let m = EffectControlsModel()
        m.onEdit = { c, _, _ in m.setClip(c) }       // the owner applies the edit and hands the clip back
        m.setClip(c); m.playhead = Time(playhead, 1)
        return m
    }
    func t(_ s: Int64) -> Time { Time(s, 1) }
    func selectAll(_ m: EffectControlsModel, _ p: EffectProperty) {
        let ids = m.track(p)?.keyIDs ?? []
        m.select(ids.map { SummaryMember(property: p.id, keyID: $0) }, extend: false)
    }

    /// Opacity animated with keys at local 0, 2 and 4 s.
    func animatedOpacity(start: Int64 = 5) -> EffectControlsModel {
        let m = model(clip(start: start), playhead: start)
        m.setValue(.opacity, to: 0.1); m.toggleStopwatch(.opacity)
        m.playhead = t(start + 2); m.setValue(.opacity, to: 0.5)
        m.playhead = t(start + 4); m.setValue(.opacity, to: 0.9)
        return m
    }

    // MARK: Stopwatch with value edits
    @Test func valueEditWithStopwatchOnAddsKeyAtPlayhead() {
        let m = model(clip(), playhead: 5)
        m.toggleStopwatch(.rotation)
        m.playhead = t(8)
        m.setValue(.rotation, to: 15)
        #expect(m.clip!.animation.rotation.track.keys.map(\.time) == [.zero, t(3)])
    }

    // MARK: Copy / paste keys
    @Test func copyPasteKeysAtPlayheadKeepsRelativeSpacing() {
        let m = animatedOpacity()
        selectAll(m, .opacity)
        #expect(m.copyKeys())
        m.clearSelection()
        m.playhead = t(5 + 5)
        #expect(m.pasteKeys())
        let times = m.clip!.animation.opacity.track.keys.map(\.time)
        #expect(times == [.zero, t(2), t(4), t(5), t(7), t(9)])
        #expect(m.selectedKeyIDs(.opacity).count == 3)
    }

    @Test func pastingPastTheClipEndDropsThoseKeys() {
        let m = animatedOpacity()
        selectAll(m, .opacity); m.copyKeys()
        m.playhead = t(5 + 8)
        m.pasteKeys()
        #expect(m.clip!.animation.opacity.track.keys.map(\.time) == [.zero, t(2), t(4), t(8), t(10)])
    }

    @Test func pasteAcrossClips() {
        let src = animatedOpacity()
        selectAll(src, .opacity); src.copyKeys()
        let other = model(clip(start: 20), playhead: 21)
        other.keyClipboard = src.keyClipboard
        #expect(other.pasteKeys())
        #expect(other.clip!.animation.opacity.track.keys.map(\.time) == [t(1), t(3), t(5)])
        #expect(other.clip!.animation.opacity.track.keys[2].value == 0.9)
    }

    @Test func singlePropertyPastesOntoFocusedPropertyOfTheSameType() {
        let m = animatedOpacity()
        selectAll(m, .opacity); m.copyKeys()
        m.focusedProperty = .rotation
        m.playhead = t(5)
        #expect(m.pasteKeys())
        #expect(m.clip!.animation.rotation.track.keys.count == 3)
        #expect(m.clip!.animation.rotation.track.keys[1].value == 0.5)
        // a vector property cannot take scalar keys
        m.focusedProperty = .position
        #expect(m.pasteTargetsForTest() != nil)      // falls back to the original property, never position
        #expect(m.clip!.animation.position.track.isEmpty)
    }

    @Test func pasteNeedsPlayheadInsideClip() {
        let m = animatedOpacity()
        selectAll(m, .opacity); m.copyKeys()
        m.playhead = t(100)
        var notice: String?
        m.onNotice = { notice = $0 }
        #expect(!m.pasteKeys())
        #expect(notice != nil)
    }

    // MARK: Interpolation choices
    @Test func easyEaseOnSelectedKeyChangesBothSides() {
        let m = animatedOpacity()
        let id = m.track(.opacity)!.keyIDs[1]
        m.selectKey(.opacity, id: id, extend: false)
        m.applyInterpolation(.easyEase)
        guard case .scalar(let tr)? = m.track(.opacity) else { return }
        #expect(tr.keys[1].inHandle.dy == 0 && tr.keys[1].outHandle.dy == 0)
        #expect(tr.keys[0].outHandle == .linear)
    }

    @Test func easeInChangesOnlyTheIncomingSide() {
        let m = animatedOpacity()
        let id = m.track(.opacity)!.keyIDs[1]
        m.selectKey(.opacity, id: id, extend: false)
        m.applyInterpolation(.easeIn)
        guard case .scalar(let tr)? = m.track(.opacity) else { return }
        #expect(tr.keys[1].inHandle.dy == 0)
        #expect(tr.keys[1].outHandle == .linear)
    }

    // MARK: Option-drag duplicate and Shift snap
    @Test func optionDragDuplicatesKeys() {
        let m = animatedOpacity()
        let ids = m.track(.opacity)!.keyIDs
        m.selectKey(.opacity, id: ids[0], extend: false)
        m.beginGesture()
        let applied = m.moveSelection(by: t(1), duplicate: true)
        m.endGesture()
        #expect(applied == t(1))
        let times = m.clip!.animation.opacity.track.keys.map(\.time)
        #expect(times == [.zero, t(1), t(2), t(4)])
    }

    @Test func keysMayLeaveTheClipOnBothSides() {
        let m = animatedOpacity()
        let ids = m.track(.opacity)!.keyIDs
        m.selectKey(.opacity, id: ids[0], extend: false)
        m.beginGesture()
        #expect(m.moveSelection(by: t(-3)) == t(-3))
        m.endGesture()
        #expect(m.clip!.animation.opacity.track.keys.first?.time == t(-3))
        m.selectKey(.opacity, id: m.track(.opacity)!.keyIDs.last!, extend: false)
        m.beginGesture()
        let far = m.clip!.duration + t(10)
        #expect(m.moveSelection(by: t(10)) == t(10))
        m.endGesture()
        #expect(m.clip!.animation.opacity.track.keys.last!.time > m.clip!.duration || far > m.clip!.duration)
    }

    @Test func snapSticksToPlayheadAndNeighbourKeys() {
        let m = animatedOpacity()
        let ids = m.track(.opacity)!.keyIDs
        m.selectKey(.opacity, id: ids[1], extend: false)       // key at 2 s local
        m.playhead = t(5 + 3)                                  // playhead at 3 s local
        m.beginGesture()
        let snapped = m.snappedMoveDelta(Time(9, 10), thresholdSeconds: 0.2)   // lands at 2.9 s: within 0.2 of 3 s
        #expect(snapped == t(1))
        #expect(m.snappedMoveDelta(Time(5, 10), thresholdSeconds: 0.2) == Time(5, 10))   // 2.5 s: nothing near
        m.endGesture()
    }

    // MARK: Twirl memory per clip (session only)
    @Test func twirlStateIsRememberedPerClip() {
        let v = clip(.video), a = clip(.audio)
        let m = model(v)
        #expect(m.collapsedSections == Set(m.visibleSections.dropFirst()))     // Transform open, the rest closed
        m.collapsedSections = [.motion]
        m.expanded = [.opacity]
        m.setClip(a)
        #expect(m.collapsedSections == Set(m.visibleSections.dropFirst()) && m.expanded.isEmpty)
        m.collapsedSections = [.volume]
        m.setClip(v)
        #expect(m.collapsedSections == [.motion] && m.expanded == [.opacity])
        m.setClip(a)
        #expect(m.collapsedSections == [.volume])
    }

    @Test func twoClipsOfOneKindKeepSeparateState() {
        let a = clip(.video), b = clip(.video)
        let m = model(a)
        m.expanded = [.opacity]
        m.setClip(b)
        #expect(m.expanded.isEmpty)
        m.setClip(a)
        #expect(m.expanded == [.opacity])
    }

    @Test func aSplitHalfStartsWithTheDefaultNotTheSourceState() {
        let a = clip(.video)
        let m = model(a)
        m.expanded = [.opacity]
        m.collapsedSections = []
        var half = a; half.id = UUID()                    // what a split produces: same content, new id
        m.setClip(half)
        #expect(m.expanded.isEmpty && m.collapsedSections == Set(m.visibleSections.dropFirst()))
    }

    @Test func twirlStateIsNotPersistedAcrossModels() {
        let a = EffectControlsModel()
        let c = clip(.video)
        a.setClip(c); a.expanded = [.opacity]
        let b = EffectControlsModel()
        b.setClip(c)
        #expect(b.expanded.isEmpty)
    }

    // MARK: Uniform scale
    @Test func nonUniformScaleEditsOneComponent() {
        let m = model(clip())
        m.setUniformScale(false)
        m.setValue(.scale, component: .x, to: 2)
        m.setValue(.scale, component: .y, to: 0.5)
        #expect(m.clip!.animation.scale.value == Vec2(2, 0.5))
        m.setUniformScale(true)
        #expect(m.clip!.animation.scale.value == Vec2(2, 2))
        m.setValue(.scale, to: 1.2)
        #expect(m.clip!.animation.scale.value == Vec2(1.2, 1.2))
    }

    @Test func clipWithUnequalScaleOpensUnchecked() {
        var c = clip(); c.animation.scale.value = Vec2(1, 2)
        let m = model(c)
        #expect(!m.uniformScale)
    }

    @Test func blendRowFollowsTheVisibleTransformSwitch() {
        var c = clip(); c.motionEnabled = false; c.opacityEnabled = true
        let m = model(c)
        #expect(!m.isBlendGroupEnabled)
        m.setEffectEnabled(.motion, true)
        #expect(m.isBlendGroupEnabled)
        #expect(m.clip!.motionEnabled && m.clip!.opacityEnabled)
    }

    // MARK: Review fixes
    @Test func undoOfUniformCheckKeepsCheckboxOffAndHeights() {
        let m = model(clip())
        m.setUniformScale(false)
        m.setValue(.scale, component: .x, to: 0.5)
        m.setValue(.scale, component: .y, to: 0.8)
        let before = m.clip!
        var notice: String?
        m.onNotice = { notice = $0 }
        m.setUniformScale(true)
        #expect(m.clip!.animation.scale.value == Vec2(0.5, 0.5))
        #expect(notice?.contains("Height set to Width") == true)
        m.setClip(before)                                    // undo hands the old clip back
        #expect(!m.uniformScale)
        #expect(m.clip!.animation.scale.value == Vec2(0.5, 0.8))
        #expect(m.uniformScale == false)
    }

    @Test func externalNonUniformScaleSwitchesCheckboxOffButNeverOn() {
        let m = model(clip())
        var c = m.clip!; c.animation.scale.value = Vec2(1, 2); m.setClip(c)
        #expect(!m.uniformScale)
        c.animation.scale.value = Vec2(1, 1); m.setClip(c)
        #expect(!m.uniformScale)
    }

    @Test func pastingOntoAShortClipExplainsDroppedKeys() {
        let m = animatedOpacity()
        selectAll(m, .opacity); m.copyKeys()
        var c = clip(start: 5); c.source = TimeRange(start: .zero, duration: Time(1, 1))
        let short = model(c, playhead: 5)
        short.keyClipboard = m.keyClipboard
        var notice: String?
        short.onNotice = { notice = $0 }
        #expect(short.pasteKeys())                            // keys at 0, 2, 4 s: only the first fits a 1 s clip
        #expect(short.clip!.animation.opacity.track.keys.count == 1)
        #expect(short.selectedKeyIDs(.opacity).count == 1)
        #expect(notice?.contains("2 keyframes past the end") == true)
    }

    @Test func cutNeedsSomethingRemovable() {
        let m = model(clip())
        m.selectedSection = .motion
        #expect(!m.canCutFocused)
        var c = m.clip!; c.roundedCorners = .roundedCorners(); m.setClip(c)
        m.selectedSection = .roundedCorners(of: c)
        #expect(m.canCutFocused)
    }

    @Test func editRoutingFallsThroughWhenNothingToDo() {
        typealias R = EffectControlsEditRouting
        #expect(R.effectControlsHandles(responderInside: true, panelFocused: true, canAct: false))
        #expect(!R.effectControlsHandles(responderInside: false, panelFocused: true, canAct: false))
        #expect(R.effectControlsHandles(responderInside: false, panelFocused: true, canAct: true))
        #expect(!R.effectControlsHandles(responderInside: false, panelFocused: false, canAct: true))
    }

    @Test func easeInAndOutTouchOnlyTheirSide() {
        let m = animatedOpacity()
        let id = m.track(.opacity)!.keyIDs[1]
        m.selectKey(.opacity, id: id, extend: false)
        guard case .scalar(let t0)? = m.track(.opacity) else { return }
        m.applyInterpolation(.easeOut)
        guard case .scalar(let t1)? = m.track(.opacity) else { return }
        #expect(t1.keys[1].inHandle == t0.keys[1].inHandle)
        #expect(t1.keys[1].outHandle != t0.keys[1].outHandle)
        m.applyInterpolation(.easeIn)
        guard case .scalar(let t2)? = m.track(.opacity) else { return }
        #expect(t2.keys[1].outHandle == t1.keys[1].outHandle)
        #expect(t2.keys[1].inHandle != t1.keys[1].inHandle)
    }

    @Test func presetIDsAreUnique() {
        let ids = (EasingCurve.builtIns + [EasingCurve.bezierHandles]).map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    // MARK: Effect copy / paste
    @Test func effectCopiesToAnotherClip() {
        var a = clip(); a.roundedCorners = .roundedCorners(radius: 40)
        let src = model(a)
        #expect(src.copyEffect(.roundedCorners(of: a)))
        let dst = model(clip())
        dst.effectClipboard = src.effectClipboard
        #expect(dst.canPasteEffect)
        #expect(dst.pasteEffect())
        #expect(dst.scalarValue(.radius(of: dst.clip!)) == 40)
        #expect(dst.clip!.roundedCorners!.id != a.roundedCorners!.id)
    }

    /// Re-review: a pasted Color effect goes behind the Color effects (before a blur), never onto text/nested clips.
    @Test func pastedColourStaysFirstAndOnlyOnColourClips() throws {
        var a = clip()
        let added = a.addEffect(kind: ClipEffect.colorKind)
        let colorID = try #require(added)
        let fx = try #require(a.effects.first { $0.id == colorID })
        var b = clip()
        _ = b.addEffect(kind: ClipEffect.gaussianBlurKind)
        let dst = model(b)
        dst.effectClipboard = fx
        #expect(dst.canPasteEffect)
        #expect(dst.pasteEffect())
        #expect(dst.clip?.effects.map(\.isColor) == [true, false])
        var text = clip(); text.generator = GeneratorRef.solid(rgb: [1, 2, 3])
        var nested = clip(); nested.sequence = UUID()
        for c in [text, nested] {
            let m = model(c)
            m.effectClipboard = fx
            #expect(!m.canPasteEffect)
            #expect(!m.pasteEffect())
            #expect(m.clip?.effects.contains { $0.isColor } == false)
        }
    }

    // MARK: Built-in effects as a whole (Transform, Blend, Volume)
    @Test func copiedTransformReplacesValuesAndKeyframesOnAnotherClip() {
        var src = clip()
        src.animation.scale = AnimatedProperty(Vec2(0.5, 0.5), track: KeyframeTrack(keys: [
            Keyframe(time: .zero, value: Vec2(0.5, 0.5)), Keyframe(time: t(2), value: Vec2(0.25, 0.25))]))
        let a = model(src)
        a.selectedSection = .motion
        #expect(a.canCopyEffect(.motion) && a.canCopyFocused)
        #expect(a.copyFocused())
        #expect(!a.canCopyEffect(.volume))                       // a video clip has no Volume
        let b = model(clip(start: 20), playhead: 20)
        b.builtInCopy = a.builtInCopy
        b.lastCopyWasKeys = false
        var other = b.clip!
        other.animation.scale = AnimatedProperty(Vec2(2, 2), track: KeyframeTrack(keys: []))
        b.setClip(other)
        #expect(b.canPasteFocused && b.pasteFocused())
        #expect(b.clip!.animation.scale.track.keys.map(\.time) == [.zero, t(2)])
        #expect(b.clip!.animation.scale.track.keys.last?.value == Vec2(0.25, 0.25))
    }

    @Test func aBuiltInHeaderStaysSelectedAcrossClipUpdates() {
        let c = clip()
        let m = model(c)
        m.selectedSection = .motion
        m.setClip(c)
        #expect(m.selectedSection == .motion && m.isSectionSelected(.motion))
        m.deleteSelectionOrEffect()
        #expect(m.clip != nil)                                    // Delete never removes a built-in effect
    }
}

extension EffectControlsModel {
    @MainActor func pasteTargetsForTest() -> Bool? { canPasteKeys }
}

@MainActor @Suite struct EffectControlsFocusedEditKeysTests {
    /// Cmd-C on a property's keys, then a row click, then Cmd-V pastes keyframes in Effect Controls whether or not the
    /// lanes were focused; Cmd-V typed into a value field stays with the field.
    @Test func commandCAndVStayInEffectControlsAfterARowClick() {
        let c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: Time(5, 1))
        let m = EffectControlsModel()
        m.onEdit = { c, _, _ in m.setClip(c) }
        m.setClip(c); m.playhead = Time(5, 1)
        m.setValue(.opacity, to: 0.1); m.toggleStopwatch(.opacity)
        m.playhead = Time(7, 1); m.setValue(.opacity, to: 0.5)
        m.select(m.track(.opacity)!.keyIDs.map { SummaryMember(property: EffectProperty.opacity.id, keyID: $0) }, extend: false)
        let v = EffectControlsDrawView(model: m)
        v.size = CGSize(width: 420, height: 600)
        #expect(!v.lanesFocused)
        #expect(v.key(.character("c"), modifiers: .command))
        m.clearSelection()
        m.focusedProperty = .rotation
        m.playhead = Time(6, 1)
        #expect(v.key(.character("v"), modifiers: .command))
        #expect(m.clip!.animation.rotation.track.keys.count == 2)
    }
}
