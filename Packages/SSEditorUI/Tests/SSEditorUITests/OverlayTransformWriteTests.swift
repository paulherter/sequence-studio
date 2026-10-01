import Foundation
import Testing
import SSCore
@testable import SSEditorUI

@MainActor @Suite struct OverlayTransformWriteTests {
    private func model(playhead: Time = Time(6, 1)) -> EffectControlsModel {
        let clip = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: Time(5, 1))
        let m = EffectControlsModel()
        m.setClip(clip)
        m.playhead = playhead
        return m
    }

    @Test func gestureEditsAreRelativeToTheGestureStartAndOnlyWriteChangedProperties() {
        let m = model()
        var edits: [(Clip, String, Bool)] = []
        m.onEdit = { edits.append(($0, $1, $2)) }
        let start = m.clip!.transform(at: Time(6, 1))
        m.beginGesture()
        var t = start; t.position = Vec2(10, 0)
        #expect(m.setTransform(t, from: start))
        t.position = Vec2(30, 5); t.scale = Vec2(2, 2)
        #expect(m.setTransform(t, from: start))
        m.endGesture()
        #expect(m.clip!.animation.position.value == Vec2(30, 5))
        #expect(m.clip!.animation.scale.value == Vec2(2, 2))
        #expect(m.clip!.animation.rotation.value == 0 && m.clip!.animation.anchor.value == .zero)
        // First emit opens the undo step, the second continues it.
        #expect(edits.map(\.2) == [false, true])
    }

    @Test func animatedPropertyGetsAKeyAtThePlayhead() {
        let m = model(playhead: Time(7, 1))
        m.toggleStopwatch(.position)
        let start = m.clip!.transform(at: Time(7, 1))
        var t = start; t.position = Vec2(50, 50)
        m.beginGesture()
        #expect(m.setTransform(t, from: start))
        m.endGesture()
        let keys = m.clip!.animation.position.track.keys
        #expect(keys.count == 1 && keys[0].time == Time(2, 1) && keys[0].value == Vec2(50, 50))
    }
}
