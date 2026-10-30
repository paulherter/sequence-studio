import Foundation
import Testing
import SQCore
import SQTimelineUI
@testable import SQInspectorUI

private func s(_ n: Int64) -> Time { Time(n, 1) }

/// A press on a key-lane glyph selects those keys in Effect Controls, so the nudge keys move them.
@MainActor @Suite struct KeyLaneSelectTests {
    private func rig() -> (EffectControlsModel, Clip) {
        var clip = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: s(0), duration: s(10)), start: s(5))
        clip.animation.opacity = AnimatedProperty(1.0, track: KeyframeTrack(keys: [
            Keyframe(time: s(1), value: 0.1), Keyframe(time: s(2), value: 0.2), Keyframe(time: s(3), value: 0.3)]))
        let m = EffectControlsModel()
        m.onEdit = { c, _, _ in m.setClip(c) }
        m.setClip(clip)
        m.selectedSection = .opacity
        return (m, clip)
    }

    @Test func clickSelectsTheKeysAtThatTimeAndShiftExtends() {
        let (m, clip) = rig()
        #expect(m.selectKeyLaneKey(clip: clip.id, at: s(7), extend: false))
        #expect(m.selectedKeyIDs(.opacity) == [clip.animation.opacity.track.keys[1].id])
        #expect(m.keyLaneSelectedTimes == [s(7)])
        #expect(m.selectKeyLaneKey(clip: clip.id, at: s(8), extend: true))
        #expect(m.keyLaneSelectedTimes == [s(7), s(8)])
        let moved = m.nudgeSelectedKeys(frames: 1)
        #expect(moved == m.frameDuration)
    }

    @Test func unknownTimeOrOtherClipSelectsNothing() {
        let (m, clip) = rig()
        #expect(!m.selectKeyLaneKey(clip: clip.id, at: s(100), extend: false))
        #expect(!m.selectKeyLaneKey(clip: UUID(), at: s(7), extend: false))
        #expect(m.selection.isEmpty)
    }

    @Test func hitTestFindsTheGlyphNearTheClickInsideTheLane() {
        let (_, c) = rig()
        let g = TimelineGeometry(frameDuration: Time(1, 30), pointsPerSecond: 100)
        let rect = CGRect(x: g.x(for: c.timeline.start), y: 0, width: g.width(of: c.duration), height: 60)
        let lane = KeyLanes.lane(in: rect)
        let x = g.x(for: s(7))
        #expect(KeyLanes.hitTest(clip: c, section: .opacity, clipRect: rect, at: CGPoint(x: x + 2, y: lane.midY), geometry: g) == s(7))
        #expect(KeyLanes.hitTest(clip: c, section: .opacity, clipRect: rect, at: CGPoint(x: x + 20, y: lane.midY), geometry: g) == nil)
        #expect(KeyLanes.hitTest(clip: c, section: .opacity, clipRect: rect, at: CGPoint(x: x, y: 5), geometry: g) == nil)
    }
}
