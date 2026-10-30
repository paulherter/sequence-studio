import Foundation
import Testing
import SQCore
@testable import SQInspectorUI

private func s(_ n: Int64) -> Time { Time(n, 1) }

@MainActor @Suite struct EffectControlsKeyNudgeTests {
    private func rig() -> (EffectControlsModel, [UUID], Box) {
        var clip = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: s(0), duration: s(10)), start: s(5))
        let ks = [Keyframe(time: s(1), value: 0.1), Keyframe(time: s(2), value: 0.2), Keyframe(time: s(3), value: 0.3)]
        clip.animation.opacity = AnimatedProperty(1.0, track: KeyframeTrack(keys: ks))
        let m = EffectControlsModel()
        let box = Box()
        m.onEdit = { c, _, _ in box.edits += 1; m.setClip(c) }
        m.setClip(clip)
        return (m, ks.map(\.id), box)
    }
    final class Box { var edits = 0 }
    private func times(_ m: EffectControlsModel) -> [Time] { (m.clip?.animation.opacity.track.keys ?? []).map(\.time) }

    @Test func nudgesByWholeFramesAsOneEditAndKeepsSelection() {
        let (m, ids, box) = rig()
        let fd = m.frameDuration
        m.setSelection(for: .opacity, ids: [ids[1]])
        #expect(m.nudgeSelectedKeys(frames: 1) == fd)
        #expect(times(m) == [s(1), s(2) + fd, s(3)])
        #expect(box.edits == 1)
        #expect(m.selectedKeyIDs(.opacity) == [ids[1]])
        #expect(m.nudgeSelectedKeys(frames: -10) == fd * -10)
        #expect(times(m)[1] == s(2) + fd - fd * 10)
        #expect(box.edits == 2)
    }

    @Test func mayLeaveTheClip() {
        let (m, ids, box) = rig()
        m.setSelection(for: .opacity, ids: [ids[0]])
        m.nudgeSelectedKeys(frames: -1000)
        #expect(times(m).first! < .zero)
    }

    @Test func neverMergesWithANeighborKey() {
        let (m, ids, _) = rig()
        m.setSelection(for: .opacity, ids: [ids[1]])
        let oneSecond = Int(m.frameDuration.timescale / max(m.frameDuration.value, 1))
        m.nudgeSelectedKeys(frames: oneSecond)               // exactly onto the key at 3 s
        #expect(times(m).count == 3)
        #expect(Set(times(m)).count == 3)
    }

    @Test func noSelectionDoesNothing() {
        let (m, _, box) = rig()
        #expect(m.nudgeSelectedKeys(frames: 1) == .zero)
        #expect(box.edits == 0)
    }
}
