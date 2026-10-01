import CoreGraphics
import Foundation
import SQCore
import SQRender
import Testing
@testable import SQEditorUI

@MainActor @Suite struct ReviewFixesTests {
    @Test func zeroSizeViewNeverDividesByZero() {
        let m = MonitorViewMapping(viewSize: .zero, backingScale: 2, sequenceSize: CGSize(width: 1920, height: 1080), zoom: .fit)
        #expect(m.panned(byViewDelta: CGSize(width: 10, height: 10)) == .fit)
        #expect(m.zoomed(by: 2, about: .zero) == .fit)
        let z = MonitorViewMapping(viewSize: CGSize(width: 100, height: 100), backingScale: 2,
                                   sequenceSize: CGSize(width: 1920, height: 1080), zoom: .view(scale: 0, centerX: 0, centerY: 0))
        #expect(z.zoomed(by: 2, about: .zero) == z.zoom)
    }

    @Test func axisLockSuppressesSnapOnTheLockedAxis() {
        let r = SnapGuides.Result(dx: 3, dy: -2, verticalLines: [0], horizontalLines: [0])
        #expect(r.locking(x: false, y: true) == SnapGuides.Result(dx: 3, dy: 0, verticalLines: [0], horizontalLines: []))
        #expect(r.locking(x: true, y: false) == SnapGuides.Result(dx: 0, dy: -2, verticalLines: [], horizontalLines: [0]))
        #expect(r.locking(x: false, y: false) == r)
    }

    @Test func textAnimationFactorsRoundTripThroughTheOverlayTransform() {
        var t = OverlayTarget(clip: UUID(), size: CGSize(width: 200, height: 100), isText: true,
                              baseTransform: ClipTransform(position: Vec2(10, 20), scale: Vec2(2, 2), rotation: 15),
                              shift: Vec2(5, -5), positionTrack: KeyframeTrack<Vec2>())
        t.animScale = 0.5; t.animRotation = 30
        let d = t.displayTransform
        #expect(d.scale == Vec2(1, 1) && d.rotation == 45 && d.position == Vec2(15, 15))
        // Drag the scale handle to 2 (display): stored scale becomes 4 / 2 = 4 (display 2 / animScale 0.5).
        var edited = d; edited.scale = Vec2(2, 2); edited.rotation = 60
        let back = t.baseTransform(fromDisplay: edited)
        #expect(back.scale == Vec2(4, 4) && back.rotation == 30 && back.position == Vec2(10, 20))
        #expect(t.baseTransform(fromDisplay: d) == t.baseTransform)
    }

    @Test func anchorDragWithAnimatedPositionShiftsEveryKey() {
        let clip = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)
        let m = EffectControlsModel()
        m.setClip(clip)
        m.playhead = Time(2, 1)
        var c = m.clip!
        var track = KeyframeTrack<Vec2>()
        track.insert(Keyframe(time: Time(0, 1), value: Vec2(0, 0)))
        track.insert(Keyframe(time: Time(4, 1), value: Vec2(100, 0)))
        c.animation.position = AnimatedProperty(Vec2.zero, track: track)
        m.setClip(c)
        let start = m.clip!.transform(at: Time(2, 1))
        var t = start
        t.anchor = Vec2(40, 0); t.position = start.position + Vec2(20, 0)
        m.beginGesture()
        #expect(m.setTransform(t, from: start))
        m.endGesture()
        let keys = m.clip!.animation.position.track.keys
        #expect(keys.count == 2 && keys[0].value == Vec2(20, 0) && keys[1].value == Vec2(120, 0))
        #expect(m.clip!.animation.anchor.value == Vec2(40, 0))
    }
}
