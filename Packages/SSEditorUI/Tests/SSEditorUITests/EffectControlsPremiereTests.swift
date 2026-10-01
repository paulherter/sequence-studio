import Foundation
import Testing
import SSCore
@testable import SSEditorUI

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
        #expect(!m.pasteKeys())
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

    // MARK: Twirl memory per clip kind
    @Test func twirlStateIsRememberedPerClipKind() {
        let m = model(clip(.video))
        m.collapsedSections = [.motion]
        m.expanded = [.opacity]
        m.setClip(clip(.audio))
        #expect(m.collapsedSections.isEmpty && m.expanded.isEmpty)
        m.collapsedSections = [.volume]
        m.setClip(clip(.video))
        #expect(m.collapsedSections == [.motion] && m.expanded == [.opacity])
        m.setClip(clip(.audio))
        #expect(m.collapsedSections == [.volume])
    }

    @Test func twirlStatePersistsThroughDefaults() {
        let suite = UserDefaults(suiteName: "ec-twirl-test-\(UUID().uuidString)")!
        let a = EffectControlsModel(); a.twirlDefaults = suite
        a.setClip(clip(.video)); a.collapsedSections = [.opacity]
        let b = EffectControlsModel(); b.twirlDefaults = suite
        b.setClip(clip(.video))
        #expect(b.collapsedSections == [.opacity])
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

    // MARK: Effect copy / paste
    @Test func effectCopiesToAnotherClip() {
        var a = clip(); a.roundedCorners = .roundedCorners(radius: 40)
        let src = model(a)
        #expect(src.copyEffect(.roundedCorners))
        let dst = model(clip())
        dst.effectClipboard = src.effectClipboard
        #expect(dst.canPasteEffect)
        #expect(dst.pasteEffect())
        #expect(dst.scalarValue(.cornerRadius) == 40)
        #expect(dst.clip!.roundedCorners!.id != a.roundedCorners!.id)
    }
}

extension EffectControlsModel {
    @MainActor func pasteTargetsForTest() -> Bool? { canPasteKeys }
}
