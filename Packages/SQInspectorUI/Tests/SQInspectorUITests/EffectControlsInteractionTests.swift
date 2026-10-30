import Foundation
import Testing
import SQCore
@testable import SQInspectorUI

// WP-B (INTERACTION-AUDIT §2, §3): Esc cancel keeps the gesture's undo name, keyframe control state per property.

@MainActor @Suite struct EffectControlsInteractionTests {
    private func model() -> EffectControlsModel {
        let c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero)
        let m = EffectControlsModel()
        m.setClip(c)
        return m
    }

    @Test func escCancelReusesTheGestureNameNeverCancel() {
        let m = model()
        var log: [(String, Bool)] = []
        m.onEdit = { _, n, co in log.append((n, co)) }
        let before = m.clip
        m.beginGesture()
        _ = m.setValue(.opacity, to: 0.4)
        _ = m.setValue(.opacity, to: 0.3)
        m.cancelGesture()
        #expect(m.clip == before)
        #expect(!log.map(\.0).contains("Cancel"))
        #expect(Set(log.map(\.0)).count == 1)
        #expect(log.last?.1 == true)      // coalesced into the gesture's step, which History then drops
    }

    @Test func escCancelThroughTheSessionLeavesNoUndoStep() {
        var h = History(1)
        // What the session does with the model's emits: first edit opens a step, the rest coalesce.
        h.commit("Change Opacity", coalescing: "ec") { $0 = 40 }
        h.commit("Change Opacity", coalescing: "ec") { $0 = 30 }
        h.commit("Change Opacity", coalescing: "ec") { $0 = 1 }
        #expect(!h.canUndo && h.current == 1)
    }

    @Test func propertyKeyframeStateComesFromTheModel() {
        let m = model()
        #expect(m.keyframeControlState(.opacity) == .off)
        m.toggleStopwatch(.opacity)                    // first key at the playhead (0)
        let s = m.keyframeControlState(.opacity)
        #expect(s.ring == .onKey && s.showsNavigation && s.keyIsOn && !s.canGoPrevious && !s.canGoNext)
    }

    @Test func maskPathKeyButtonsAddRemoveAndNavigate() {
        var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero)
        c.masks = [ClipMask(path: .rectangle(Vec2(0, 0), Vec2(0.5, 0.5)))]
        let id = c.masks[0].id
        let m = EffectControlsModel()
        m.setClip(c)
        var names: [String] = []
        m.onEdit = { _, n, _ in names.append(n) }
        var seeks: [Time] = []
        m.onSeek = { seeks.append($0) }
        #expect(m.maskPathKeyframeState(id) == .off)
        m.setMaskPathAnimated(id, true)                // key at 0
        #expect(m.maskPathKeyframeState(id).ring == .onKey)
        m.playhead = Time(2, 1)
        let between = m.maskPathKeyframeState(id)
        #expect(between.ring == .between && between.canGoPrevious && !between.canGoNext && !between.keyIsOn)
        m.toggleMaskPathKeyAtPlayhead(id)
        #expect(m.maskPathKeyframeState(id).keyIsOn)
        m.goToPreviousMaskPathKey(id)
        #expect(seeks == [.zero])
        m.toggleMaskPathKeyAtPlayhead(id)
        #expect(!m.maskPathKeyframeState(id).keyIsOn)
        #expect(names == ["Animate Mask Path", "Add Mask Path Keyframe", "Remove Mask Path Keyframe"])
    }

    @Test func lanesShowTheNoKeysHintOnlyWithoutKeys() {
        let m = model()
        let lanes = EffectKeyframeLanesView(model: m)
        #expect(lanes.showsNoKeysHint)
        m.toggleStopwatch(.opacity)
        #expect(!lanes.showsNoKeysHint)
        m.setClip(nil)
        #expect(!lanes.showsNoKeysHint)
    }

    @Test func keyframeCursorRule() {
        #expect(KeyframeCursor.cursor(overGrip: true, dragging: false) == .arrow)
        #expect(KeyframeCursor.cursor(overGrip: true, dragging: true) == .arrow)
        #expect(KeyframeCursor.cursor(overGrip: false, dragging: false) == .arrow)
        #expect(KeyframeGraphView.isGrip(.key(UUID())) && !KeyframeGraphView.isGrip(.empty))
    }

    @Test func keyframeStateFollowsTheModel() {
        #expect(KeyframeControlState.resolve(animated: false, onKey: false, hasPrevious: false, hasNext: false,
                                             playheadInRange: true) == .off)
        let s = KeyframeControlState.resolve(animated: true, onKey: true, hasPrevious: false, hasNext: true,
                                             playheadInRange: true)
        #expect(s.ring == .onKey && s.keyIsOn && s.canGoNext && !s.canGoPrevious)
    }
}
