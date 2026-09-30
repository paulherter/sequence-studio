import Foundation
import Testing
import SSCore
@testable import SSEditorUI

@MainActor @Suite struct EffectControlsModelTests {
    /// Video clip on the timeline at 5 s, 10 s long.
    func makeModel(kind: TrackKind = .video, playhead: Time = Time(5, 1)) -> (EffectControlsModel, Log) {
        let clip = Clip(name: "c", media: UUID(), kind: kind,
                        source: TimeRange(start: .zero, duration: Time(10, 1)), start: Time(5, 1))
        let m = EffectControlsModel()
        let log = Log()
        m.onEdit = { c, name, coalescing in log.edits.append((c, name, coalescing)) }
        m.onSeek = { log.seeks.append($0) }
        m.setClip(clip)
        m.playhead = playhead
        return (m, log)
    }
    final class Log { var edits: [(Clip, String, Bool)] = []; var seeks: [Time] = [] }

    func t(_ s: Int64) -> Time { Time(s, 1) }   // seconds

    @Test func cornerRadiusWritesAppliedEffect() {
        let (m, _) = makeModel()
        #expect(!m.setValue(.cornerRadius, to: 24))          // not applied: nothing to edit
        #expect(m.clip!.effects.isEmpty)
        var c = m.clip!; c.roundedCorners = .roundedCorners(radius: 0); m.setClip(c)
        m.setValue(.cornerRadius, to: 24)
        #expect(m.clip!.roundedCorners!.parameters[ClipEffect.radiusKey]!.value(atLocal: .zero) == 24)
        #expect(m.scalarValue(.cornerRadius) == 24)
        #expect(m.toggleStopwatch(.cornerRadius) == .added)
        #expect(m.isAnimated(.cornerRadius))
    }

    // MARK: Sections
    @Test func sectionsByClipKind() {
        let (v, _) = makeModel()
        #expect(v.visibleSections == [.motion, .opacity])       // effects only once applied
        var c = v.clip!; c.roundedCorners = .roundedCorners(); v.setClip(c)
        #expect(v.visibleSections == [.motion, .opacity, .roundedCorners])
        let (a, _) = makeModel(kind: .audio)
        #expect(a.visibleSections == [.volume])
    }

    // MARK: Stopwatch
    @Test func stopwatchOnCreatesKeyFromStaticValue() {
        let (m, log) = makeModel(playhead: t(7))
        m.setValue(.opacity, to: 0.5)
        #expect(m.toggleStopwatch(.opacity) == .added)
        let tr = m.clip!.animation.opacity.track
        #expect(tr.keys.count == 1)
        #expect(tr.keys[0].time == t(2))
        #expect(tr.keys[0].value == 0.5)
        #expect(m.keyState(.opacity) == .onKey)
        #expect(log.edits.last?.1 == "Add Keyframe")
    }

    @Test func stopwatchOffNeedsConfirmationThenKeepsCurrentValue() {
        let (m, _) = makeModel(playhead: t(5))
        m.toggleStopwatch(.opacity)
        m.playhead = t(7)
        m.setValue(.opacity, to: 0.2)
        m.playhead = t(6)
        let shown = m.scalarValue(.opacity)
        #expect(m.toggleStopwatch(.opacity) == .needsConfirmation)
        #expect(m.isAnimated(.opacity))
        #expect(m.toggleStopwatch(.opacity, confirmRemoval: true) == .removed)
        #expect(!m.isAnimated(.opacity))
        #expect(m.clip!.animation.opacity.value == shown)
        #expect(m.keyState(.opacity) == .none)
    }

    @Test func stopwatchUnavailableOutsideClip() {
        let (m, log) = makeModel(playhead: t(1))
        #expect(m.toggleStopwatch(.rotation) == .unavailable)
        #expect(log.edits.isEmpty)
    }

    @Test func keyStateOnKeyBetween() {
        let (m, _) = makeModel(playhead: t(5))
        m.toggleStopwatch(.rotation)
        m.playhead = t(8)
        #expect(m.keyState(.rotation) == .between)
        m.playhead = t(5)
        #expect(m.keyState(.rotation) == .onKey)
    }

    // MARK: Editing values
    @Test func staticEditSetsValue() {
        let (m, log) = makeModel()
        m.setValue(.rotation, to: 45)
        #expect(m.clip!.animation.rotation.value == 45)
        #expect(m.clip!.animation.rotation.track.isEmpty)
        #expect(log.edits.last?.1 == "Change Rotation")
    }

    @Test func animatedEditAddsOrReplacesKeyAtPlayhead() {
        let (m, _) = makeModel(playhead: t(5))
        m.toggleStopwatch(.rotation)
        m.playhead = t(7)
        m.setValue(.rotation, to: 90)
        #expect(m.clip!.animation.rotation.track.keys.map(\.time) == [.zero, t(2)])
        m.setValue(.rotation, to: 30)
        #expect(m.clip!.animation.rotation.track.keys.count == 2)
        #expect(m.scalarValue(.rotation) == 30)
    }

    @Test func vectorComponentEditKeepsOtherComponent() {
        let (m, _) = makeModel()
        m.setValue(.position, component: .x, to: 10)
        m.setValue(.position, component: .y, to: -4)
        #expect(m.clip!.animation.position.value == Vec2(10, -4))
        m.setValue(.position, component: .x, to: 12)
        #expect(m.clip!.animation.position.value == Vec2(12, -4))
    }

    @Test func uniformScaleSetsBoth() {
        let (m, _) = makeModel()
        m.setValue(.scale, to: 1.5)
        #expect(m.clip!.animation.scale.value == Vec2(1.5, 1.5))
    }

    @Test func relativeMultiKeyEditShiftsSelectedKeys() {
        let (m, _) = makeModel(playhead: t(5))
        m.setValue(.opacity, to: 0.2)
        m.toggleStopwatch(.opacity)            // key at 0 s = 0.2
        m.playhead = t(9)
        m.setValue(.opacity, to: 0.6)          // key at 4 s = 0.6
        let ids = Set(m.clip!.animation.opacity.track.keys.map(\.id))
        m.select(ids.map { SummaryMember(property: EffectProperty.opacity.id, keyID: $0) }, extend: false)
        m.playhead = t(9)
        m.setValue(.opacity, to: 0.7)          // +0.1 on both
        let v = m.clip!.animation.opacity.track.keys.map(\.value)
        #expect(abs(v[0] - 0.3) < 1e-9 && abs(v[1] - 0.7) < 1e-9)
        #expect(m.clip!.animation.opacity.track.keys.count == 2)
    }

    @Test func relativeEditLeavesOtherPropertiesAlone() {
        let (m, _) = makeModel(playhead: t(5))
        m.toggleStopwatch(.opacity); m.toggleStopwatch(.rotation)
        let ok = m.clip!.animation.opacity.track.keys[0]
        m.select([SummaryMember(property: EffectProperty.opacity.id, keyID: ok.id)], extend: false)
        m.setValue(.rotation, to: 30)          // rotation has no selected key: replaces key at playhead
        #expect(m.clip!.animation.opacity.track.keys[0] == ok)
        #expect(m.clip!.animation.rotation.track.keys[0].value == 30)
    }

    // MARK: Gestures and undo coalescing
    @Test func gestureEmitsFirstUncoalescedThenCoalesced() {
        let (m, log) = makeModel()
        m.beginGesture()
        m.setValue(.rotation, to: 1); m.setValue(.rotation, to: 2); m.setValue(.rotation, to: 3)
        m.endGesture()
        #expect(log.edits.map(\.2) == [false, true, true])
        m.setValue(.rotation, to: 9)
        #expect(log.edits.last?.2 == false)
    }

    @Test func gestureComputesFromBaseNotFromPreviousStep() {
        let (m, _) = makeModel(playhead: t(5))
        m.toggleStopwatch(.opacity)
        m.playhead = t(9); m.setValue(.opacity, to: 0.5)
        let ids = m.clip!.animation.opacity.track.keys.map { SummaryMember(property: EffectProperty.opacity.id, keyID: $0.id) }
        m.select(ids, extend: false)
        m.beginGesture()
        m.setValue(.opacity, to: 0.8); m.setValue(.opacity, to: 0.4)   // net -0.1
        m.endGesture()
        let v = m.clip!.animation.opacity.track.keys.map(\.value)
        #expect(abs(v[0] - 0.9) < 1e-9 && abs(v[1] - 0.4) < 1e-9)
    }

    @Test func noEmitWhenNothingChanges() {
        let (m, log) = makeModel()
        m.setValue(.rotation, to: 0)
        #expect(log.edits.isEmpty)
    }

    // MARK: Key buttons
    @Test func toggleKeyAtPlayheadAddsAndRemoves() {
        let (m, _) = makeModel(playhead: t(5))
        m.toggleStopwatch(.opacity)
        m.playhead = t(8)
        #expect(m.toggleKeyAtPlayhead(.opacity) == .added)
        #expect(m.clip!.animation.opacity.track.keys.count == 2)
        #expect(m.toggleKeyAtPlayhead(.opacity) == .removed)
        #expect(m.clip!.animation.opacity.track.keys.count == 1)
    }

    @Test func removingLastKeyViaToggleKeepsValue() {
        let (m, _) = makeModel(playhead: t(6))
        m.setValue(.opacity, to: 0.4)
        m.toggleStopwatch(.opacity)
        _ = m.toggleKeyAtPlayhead(.opacity)
        #expect(!m.isAnimated(.opacity))
        #expect(m.clip!.animation.opacity.value == 0.4)
    }

    @Test func previousNextKeyNavigation() {
        let (m, log) = makeModel(playhead: t(6))
        m.toggleStopwatch(.opacity)            // local 1
        m.playhead = t(10); m.setValue(.opacity, to: 0.1)   // local 5
        m.playhead = t(8)
        #expect(m.previousKeyTime(.opacity) == t(6))
        #expect(m.nextKeyTime(.opacity) == t(10))
        m.goToPreviousKey(.opacity)
        #expect(log.seeks == [t(6)])
        m.playhead = t(6)
        #expect(m.previousKeyTime(.opacity) == nil)
    }

    // MARK: Selection, summary, move
    func twoPropModel() -> EffectControlsModel {
        let (m, _) = makeModel(playhead: t(5))
        m.toggleStopwatch(.opacity); m.toggleStopwatch(.rotation)
        m.playhead = t(7)
        m.setValue(.opacity, to: 0.5); m.setValue(.rotation, to: 10)
        return m
    }

    @Test func summaryGroupsAndSelection() {
        let m = twoPropModel()
        let groups = m.summaryKeys(.motion)
        #expect(groups.count == 2 && groups[0].time == .zero && groups[1].time == t(2))
        #expect(groups[0].members.count == 1)   // motion only contains rotation
        m.selectSummary(groups[1], extend: false)
        #expect(m.isSelected(groups[1]))
        #expect(!m.isSelected(groups[0]))
        m.selectSummary(groups[0], extend: true)
        #expect(m.selection.count == 2)
        m.selectSummary(groups[0], extend: true)      // toggles off
        #expect(m.selection.count == 1)
    }

    @Test func moveSelectionMovesAllMembersAndClampsToClip() {
        let m = twoPropModel()
        let opacityKeys = m.clip!.animation.opacity.track.keys
        let rotKeys = m.clip!.animation.rotation.track.keys
        m.select([.init(property: EffectProperty.opacity.id, keyID: opacityKeys[1].id),
                  .init(property: EffectProperty.rotation.id, keyID: rotKeys[1].id)], extend: false)
        let applied = m.moveSelection(by: t(3))
        #expect(applied == t(3))
        #expect(m.clip!.animation.opacity.track.keys[1].time == t(5))
        #expect(m.clip!.animation.rotation.track.keys[1].time == t(5))
        // clamp at clip end (10 s): key is at 5 s, delta 20 s -> 5 s
        #expect(m.moveSelection(by: t(20)) == t(5))
        #expect(m.clip!.animation.opacity.track.keys[1].time == t(10))
        _ = m.moveSelection(by: t(-30))               // stops at the unselected key at 0 and replaces it (moved key wins)
        #expect(m.clip!.animation.opacity.track.keys.count == 1)
        #expect(m.clip!.animation.opacity.track.keys[0].time == .zero)
    }

    @Test func moveInGestureUsesBase() {
        let m = twoPropModel()
        let k = m.clip!.animation.opacity.track.keys[1]
        m.select([.init(property: EffectProperty.opacity.id, keyID: k.id)], extend: false)
        m.beginGesture()
        _ = m.moveSelection(by: t(3)); _ = m.moveSelection(by: t(1))
        m.endGesture()
        #expect(m.clip!.animation.opacity.track.keys[1].time == t(3))
        #expect(m.clip!.animation.rotation.track.keys[1].time == t(2))
    }

    @Test func easingAppliesToSelectionOnly() {
        let m = twoPropModel()
        let k = m.clip!.animation.opacity.track.keys[0]
        m.select([.init(property: EffectProperty.opacity.id, keyID: k.id)], extend: false)
        m.applyEasing(.easeInOut, side: .both)
        #expect(m.clip!.animation.opacity.track.keys[0].interpolation == .bezier)
        #expect(m.clip!.animation.opacity.track.keys[1].interpolation == .linear)
        #expect(m.clip!.animation.rotation.track.keys[0].interpolation == .linear)
    }

    @Test func deleteSelectionRemovesKeysAndKeepsValueWhenEmpty() {
        let m = twoPropModel()
        let ids = m.clip!.animation.opacity.track.keys.map { SummaryMember(property: EffectProperty.opacity.id, keyID: $0.id) }
        m.select(ids, extend: false)
        m.playhead = t(7)
        m.deleteSelection()
        #expect(!m.isAnimated(.opacity))
        #expect(m.clip!.animation.opacity.value == 0.5)
        #expect(m.selection.isEmpty)
        #expect(m.isAnimated(.rotation))
    }

    @Test func marqueeSelectsKeysInRange() {
        let m = twoPropModel()
        m.selectKeys(in: .zero ... t(1), properties: [.opacity, .rotation], extend: false)
        #expect(m.selection.count == 2)
        m.selectKeys(in: t(1) ... t(3), properties: [.opacity], extend: false)
        #expect(m.selection.count == 1)
        m.selectKeys(in: t(1) ... t(3), properties: [.rotation], extend: true)
        #expect(m.selection.count == 2)
    }

    @Test func setClipPrunesSelectionAndResetsOnNewClip() {
        let m = twoPropModel()
        m.selectKeys(in: .zero ... t(3), properties: [.opacity], extend: false)
        var c = m.clip!
        c.animation.opacity.track = KeyframeTrack()
        m.setClip(c)
        #expect(m.selection.isEmpty)
        m.selectKeys(in: .zero ... t(3), properties: [.rotation], extend: false)
        m.setClip(Clip(name: "o", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: t(1)), start: .zero))
        #expect(m.selection.isEmpty)
    }

    // MARK: Graph projection
    @Test func graphEditMergesBackIntoVectorTrack() {
        let (m, _) = makeModel(playhead: t(5))
        m.setValue(.position, component: .x, to: 10); m.setValue(.position, component: .y, to: 20)
        m.toggleStopwatch(.position)
        m.playhead = t(9); m.setValue(.position, component: .x, to: 50)
        var gx = m.graphTrack(.position, component: .x)
        #expect(gx.keys.map(\.value) == [10, 50])
        gx.set(gx.keys[1].id, value: 70)
        m.applyGraphEdit(.position, component: .x, track: gx)
        let v = m.clip!.animation.position.track.keys.map(\.value)
        #expect(v == [Vec2(10, 20), Vec2(70, 20)])
    }

    @Test func uniformScaleGraphEditSetsBoth() {
        let (m, _) = makeModel(playhead: t(5))
        m.toggleStopwatch(.scale)
        var g = m.graphTrack(.scale, component: .x)
        g.set(g.keys[0].id, value: 2)
        m.applyGraphEdit(.scale, component: .x, track: g)
        #expect(m.clip!.animation.scale.track.keys[0].value == Vec2(2, 2))
    }

    @Test func graphEditCanAddAndRemoveKeys() {
        let (m, _) = makeModel(playhead: t(5))
        m.toggleStopwatch(.position)
        var g = m.graphTrack(.position, component: .y)
        g.insert(Keyframe(time: t(3), value: 9))
        m.applyGraphEdit(.position, component: .y, track: g)
        let keys = m.clip!.animation.position.track.keys
        #expect(keys.count == 2 && keys[1].time == t(3))
        #expect(keys[1].value == Vec2(0, 9))
        g = m.graphTrack(.position, component: .y)
        g.remove(g.keys[1].id)
        m.applyGraphEdit(.position, component: .y, track: g)
        #expect(m.clip!.animation.position.track.keys.count == 1)
    }

    // MARK: Display units
    @Test func displayConversion() {
        #expect(EffectProperty.opacity.display(0.5) == 50)
        #expect(EffectProperty.scale.native(fromDisplay: 150) == 1.5)
        #expect(abs(EffectProperty.volume.display(1) - 0) < 1e-9)
        #expect(abs(EffectProperty.volume.display(0.5) + 6.0206) < 1e-3)
        #expect(EffectProperty.volume.native(fromDisplay: -60) == 0)
        #expect(abs(EffectProperty.volume.native(fromDisplay: 0) - 1) < 1e-9)
        #expect(EffectProperty.volume.display(0) == -60)
    }
}

@MainActor @Suite struct EffectControlsResetTests {
    func rig() -> (EffectControlsModel, EffectControlsModelTests.Log) {
        var clip = Clip(name: "c", media: UUID(), kind: .video,
                        source: TimeRange(start: .zero, duration: Time(10, 1)), start: Time(5, 1))
        clip.roundedCorners = .roundedCorners(radius: 40)
        let m = EffectControlsModel(); let log = EffectControlsModelTests.Log()
        m.onEdit = { c, n, co in log.edits.append((c, n, co)) }
        m.setClip(clip); m.playhead = Time(6, 1)
        return (m, log)
    }

    @Test func graphModeDefaultsToSpeed() { #expect(EffectControlsModel().graphMode == .speed) }

    @Test func resetPropertyIsOneStepAndDropsKeys() {
        let (m, log) = rig()
        m.setValue(.opacity, to: 0.4)
        _ = m.toggleStopwatch(.opacity)
        #expect(!m.isDefault(.opacity))
        log.edits.removeAll()
        m.reset(.opacity)
        #expect(log.edits.count == 1 && log.edits[0].1 == "Reset Opacity")
        #expect(m.clip!.animation.opacity == ClipAnimation().opacity)
        #expect(m.isDefault(.opacity))
        m.reset(.opacity)                                   // already default: no edit
        #expect(log.edits.count == 1)
    }

    @Test func resetSectionResetsAllPropertiesAndReenablesEffect() {
        let (m, log) = rig()
        m.setValue(.rotation, to: 30)
        m.setValue(.scale, to: 2)
        log.edits.removeAll()
        m.resetSection(.motion)
        #expect(log.edits.count == 1)
        #expect(m.clip!.animation.rotation.value == 0 && m.clip!.animation.scale.value == Vec2(1, 1))
        m.setEffectEnabled(.roundedCorners, false)
        m.resetSection(.roundedCorners)
        #expect(m.clip!.roundedCorners!.enabled)
        #expect(m.clip!.roundedCorners!.parameters[ClipEffect.radiusKey]!.value == 24)
    }

    @Test func toggleAndRemoveEffect() {
        let (m, log) = rig()
        m.setEffectEnabled(.roundedCorners, false)
        #expect(!m.isEffectEnabled(.roundedCorners) && m.clip!.roundedCorners != nil)
        #expect(m.clip!.effects(at: Time(6, 1)) == ClipEffects.none)
        #expect(m.removeEffect(.roundedCorners))
        #expect(m.clip!.effects.isEmpty && !m.visibleSections.contains(.roundedCorners))
        #expect(!m.removeEffect(.motion))                   // built-in: not removable
        #expect(log.edits.last?.1 == "Remove Rounded Corners")
    }

    @Test func deleteKeyRemovesSelectedEffectWhenNoKeysSelected() {
        let (m, _) = rig()
        m.selectedSection = .roundedCorners
        m.deleteSelectionOrEffect()
        #expect(m.clip!.effects.isEmpty)
    }
}
