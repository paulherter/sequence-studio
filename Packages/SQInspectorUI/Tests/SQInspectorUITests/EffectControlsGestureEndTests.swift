import Foundation
import Testing
import SQCore
@testable import SQInspectorUI

/// A gesture of Effect Controls that reached the session tells the host when it ends (`onGestureEnded`), so the host
/// ends the session's gesture as the item lanes do. One that changed nothing stays silent.
@MainActor @Suite struct EffectControlsGestureEndTests {
    final class Box { var edits = 0; var ends = 0 }

    private func rig() -> (EffectControlsModel, Box) {
        let clip = Clip(name: "c", media: UUID(), kind: .video,
                        source: TimeRange(start: .zero, duration: Time(10, 1)), start: Time(5, 1))
        let m = EffectControlsModel()
        let box = Box()
        m.onEdit = { c, _, _ in box.edits += 1; m.setClip(c) }
        m.onGestureEnded = { box.ends += 1 }
        m.setClip(clip)
        m.playhead = Time(5, 1)
        return (m, box)
    }

    @Test func aValueDragEndsOnce() {
        let (m, box) = rig()
        m.beginGesture()
        m.setValue(.opacity, to: 0.5)
        m.setValue(.opacity, to: 0.4)
        #expect(box.edits == 2 && box.ends == 0)
        m.endGesture()
        #expect(box.ends == 1)
        m.endGesture()
        #expect(box.ends == 1)
    }

    @Test func aGestureThatChangedNothingStaysSilent() {
        let (m, box) = rig()
        m.beginGesture()
        m.endGesture()
        m.beginGesture()
        m.cancelGesture()
        #expect(box.edits == 0 && box.ends == 0)
    }

    @Test func aCanceledGestureEndsToo() {
        let (m, box) = rig()
        m.beginGesture()
        m.setValue(.opacity, to: 0.5)
        m.cancelGesture()
        #expect(box.ends == 1 && m.clip?.animation.opacity.value == 1)
    }

    @Test func aKeyDragEndsOnceAfterItsOneEdit() {
        let (m, box) = rig()
        m.toggleStopwatch(.opacity)
        let id = m.clip!.animation.opacity.track.keys[0].id
        m.selectKey(.opacity, id: id, extend: false)
        let before = box.edits
        m.beginGesture()
        m.moveSelection(by: Time(2, 1))
        m.endKeyMove()
        #expect(box.edits == before + 1 && box.ends == 1)
        // A drag that moved nothing: no edit, no end.
        m.beginGesture()
        m.moveSelection(by: .zero)
        m.endKeyMove()
        #expect(box.ends == 1)
    }
}
