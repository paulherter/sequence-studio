import Foundation
import Testing
import SQCore
@testable import SQInspectorUI

/// P4: the Transform effect shows Position and Anchor as X/Y pair rows, in Motion's order; storage stays two scalars.
@MainActor @Suite struct EffectPairRowsTests {
    private func setup() -> (EffectControlsModel, ClipEffect.ID) {
        var c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero)
        let e = ClipEffect(kind: ClipEffect.transformKind)
        c.effects.append(e)
        let m = EffectControlsModel()
        m.setClip(c)
        m.playhead = Time(1, 1)
        return (m, e.id)
    }
    private func pos(_ id: ClipEffect.ID) -> EffectProperty { .fx(id, kind: ClipEffect.transformKind, key: ClipEffect.stagePositionXKey) }
    private func param(_ m: EffectControlsModel, _ key: String) -> AnimatedProperty<Double>? { m.clip?.effects.first?.parameters[key] }

    @Test func transformEffectRowsMatchMotion() {
        let (_, id) = setup()
        let props = EffectSection.effect(id, kind: ClipEffect.transformKind).properties
        #expect(props.map(\.title) == ["Position", "Scale", "Rotation", "Anchor", "Opacity", "Shutter Angle"])
        // Motion adds the layer's Tilt X / Y and Anti-flicker Filter; the Transform effect has no tilt.
        #expect(props.map(\.title) == EffectSection.motion.properties.map(\.title).filter { !$0.hasPrefix("Tilt") && !$0.hasPrefix("Anti-flicker") })
        #expect(props[0].kind == .vector && props[3].kind == .vector && props[1].kind == .vector && props[2].kind == .scalar)
        #expect(props[0].displayUnit == "px")
    }

    @Test func pairRowWritesBothMembers() {
        let (m, id) = setup()
        #expect(m.setVector(pos(id), to: Vec2(10, 20)))
        #expect(param(m, ClipEffect.stagePositionXKey)?.value == 10 && param(m, ClipEffect.stagePositionYKey)?.value == 20)
        #expect(m.vectorValue(pos(id)) == Vec2(10, 20))
        #expect(!m.isDefault(pos(id)))
        m.resetAll(pos(id))
        #expect(m.vectorValue(pos(id)) == .zero && m.isDefault(pos(id)))
    }

    @Test func stopwatchKeysBothMembersAligned() {
        let (m, id) = setup()
        #expect(m.toggleStopwatch(pos(id)) == .added)
        let x = param(m, ClipEffect.stagePositionXKey)!, y = param(m, ClipEffect.stagePositionYKey)!
        #expect(x.track.keys.count == 1 && y.track.keys.count == 1 && KeyframesPair.isAligned(x, y))
        #expect(m.keys(pos(id)).count == 1)
        m.playhead = Time(3, 1)
        #expect(m.setVector(pos(id), to: Vec2(5, -5)))
        let x2 = param(m, ClipEffect.stagePositionXKey)!, y2 = param(m, ClipEffect.stagePositionYKey)!
        #expect(x2.track.keys.count == 2 && KeyframesPair.isAligned(x2, y2))
        #expect(y2.value(atLocal: Time(3, 1)) == -5)
        #expect(m.toggleStopwatch(pos(id), confirmRemoval: true) == .removed)
        #expect(param(m, ClipEffect.stagePositionXKey)?.isAnimated == false && param(m, ClipEffect.stagePositionYKey)?.isAnimated == false)
    }

    @Test func unalignedStorageReadsExactValues() {
        let (m0, id) = setup()
        var c = m0.clip!
        c.effects[0].parameters[ClipEffect.stagePositionXKey] = AnimatedProperty(0, track: KeyframeTrack(keys: [
            Keyframe(time: .zero, value: 0), Keyframe(time: Time(4, 1), value: 40)]))
        c.effects[0].parameters[ClipEffect.stagePositionYKey] = AnimatedProperty(0, track: KeyframeTrack(keys: [
            Keyframe(time: .zero, value: 10), Keyframe(time: Time(2, 1), value: 30)]))
        let m = EffectControlsModel(); m.setClip(c); m.playhead = Time(1, 1)
        #expect(m.vectorValue(pos(id)) == Vec2(10, 20))
        #expect(m.keys(pos(id)).count == 3)                          // union of both members' key times
    }

    // MARK: P5 Scale link

    private func scale(_ id: ClipEffect.ID) -> EffectProperty { .fx(id, kind: ClipEffect.transformKind, key: ClipEffect.stageScaleKey) }

    @Test func scaleStartsLinkedAndWritesOnlyScale() {
        let (m, id) = setup()
        #expect(m.isLinked(scale(id)) && m.unlinkedPairEffects.isEmpty)
        #expect(PropertyRow.components(scale(id), model: m) == [.all])
        #expect(m.setValue(scale(id), to: 150))
        #expect(param(m, ClipEffect.stageScaleKey)?.value == 150)
        #expect(param(m, ClipEffect.stageScaleYKey) == nil)
        #expect(m.vectorValue(scale(id)) == Vec2(150, 150))
    }

    @Test func unlinkingKeepsPictureThenWidthAndHeightEditSeparately() {
        let (m, id) = setup()
        m.setValue(scale(id), to: 150)
        m.setLinked(scale(id), false)
        #expect(!m.isLinked(scale(id)) && m.unlinkedPairEffects == [id])
        #expect(param(m, ClipEffect.stageScaleYKey)?.value == 150)
        #expect(PropertyRow.components(scale(id), model: m) == [.x, .y])
        #expect(m.setValue(scale(id), component: .y, to: 50))
        #expect(param(m, ClipEffect.stageScaleKey)?.value == 150 && param(m, ClipEffect.stageScaleYKey)?.value == 50)
        #expect(m.clip!.renderTransform(at: Time(1, 1), frame: Vec2(1920, 1080)).scale == Vec2(1.5, 0.5))
    }

    @Test func relinkingDropsHeightAndResetRelinks() {
        let (m, id) = setup()
        m.setLinked(scale(id), false)
        m.setValue(scale(id), component: .y, to: 50)
        var notice: String?
        m.onNotice = { notice = $0 }
        m.setLinked(scale(id), true)
        #expect(param(m, ClipEffect.stageScaleYKey) == nil && notice != nil)
        m.setLinked(scale(id), false)
        m.resetAll(scale(id))
        #expect(m.isLinked(scale(id)) && m.isDefault(scale(id)))
    }

    @Test func linkedScaleKeysOnlyTheScaleTrack() {
        let (m, id) = setup()
        #expect(m.toggleStopwatch(scale(id)) == .added)
        #expect(param(m, ClipEffect.stageScaleKey)?.track.keys.count == 1)
        #expect(param(m, ClipEffect.stageScaleYKey) == nil)
        m.playhead = Time(3, 1)
        #expect(m.setValue(scale(id), to: 200))
        #expect(param(m, ClipEffect.stageScaleKey)?.track.keys.count == 2 && param(m, ClipEffect.stageScaleYKey) == nil)
    }
}
