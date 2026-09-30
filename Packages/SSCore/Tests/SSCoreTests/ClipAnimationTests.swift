import Foundation
import Testing
@testable import SSCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func clip(_ start: Int64 = 0, _ dur: Int64 = 10) -> Clip {
    Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: s(0), duration: s(dur)), start: s(start))
}

@Suite struct ClipAnimationTests {
    @Test func defaultsAreStaticIdentity() {
        let t = clip().transform(at: s(3))
        #expect(t == ClipTransform.identity)
        #expect(t.scale == Vec2(1, 1) && t.opacity == 1 && t.rotation == 0 && t.position == .zero && t.anchor == .zero)
    }

    @Test func staticValueWithoutKeys() {
        var c = clip()
        c.animation.rotation.value = 45
        #expect(c.transform(at: s(5)).rotation == 45)
    }

    @Test func tracksUseClipLocalTime() {
        var c = clip(10, 10)
        c.animation.position.track = KeyframeTrack(keys: [
            Keyframe(time: s(0), value: Vec2(0, 0)), Keyframe(time: s(4), value: Vec2(40, 0))])
        #expect(c.transform(at: s(12)).position == Vec2(20, 0))   // timeline 12 = local 2
        #expect(c.transform(at: s(5)).position == Vec2(0, 0))     // before the clip: clamped to first key
    }

    @Test func rotationUnbounded() {
        var c = clip()
        c.animation.rotation.track = KeyframeTrack(keys: [kfKey(0, 0), kfKey(4, 720)])
        #expect(c.transform(at: s(4)).rotation == 720)
        #expect(c.transform(at: s(1)).rotation == 180)
        c.animation.rotation.track = KeyframeTrack(keys: [kfKey(0, 0), kfKey(4, -1080)])
        #expect(c.transform(at: s(4)).rotation == -1080)
    }

    @Test func scaleClampedAtZeroNotWrapped() {
        var c = clip()
        c.animation.scale.value = Vec2(-2, 3)
        #expect(c.transform(at: s(1)).scale == Vec2(0, 3))
        c.animation.scale.track = KeyframeTrack(keys: [
            Keyframe(time: s(0), value: Vec2(1, 1)), Keyframe(time: s(2), value: Vec2(-3, 5))])
        let v = c.transform(at: s(1)).scale
        #expect(v.x == 0 && v.y == 3)
        #expect(c.transform(at: s(2)).scale == Vec2(0, 5))
        c.animation.scale.value = Vec2(500, 500)   // no upper limit
        c.animation.scale.track = KeyframeTrack()
        #expect(c.transform(at: s(0)).scale == Vec2(500, 500))
    }

    @Test func opacityAndVolumeClamped() {
        var c = clip()
        c.animation.opacity.value = 1.5
        c.animation.volume.value = -1
        #expect(c.transform(at: s(0)).opacity == 1)
        #expect(c.volume(at: s(0)) == 0)
        c.animation.volume.value = 4   // +12 dB headroom allowed
        #expect(c.volume(at: s(0)) == 4)
    }

    @Test func splitShiftsKeysOfRightHalf() throws {
        var c = clip(0, 10)
        c.animation.opacity.track = KeyframeTrack(keys: [kfKey(0, 0), kfKey(10, 1)])
        var tr = Track(kind: .video)
        try tr.overwrite(c)
        try tr.split(at: s(4))
        let right = tr.clips[1]
        #expect(abs(right.transform(at: s(4)).opacity - 0.4) < 1e-9)
        #expect(abs(right.transform(at: s(9)).opacity - 0.9) < 1e-9)
        #expect(abs(tr.clips[0].transform(at: s(2)).opacity - 0.2) < 1e-9)
    }

    @Test func videoLayerCarriesTransform() throws {
        var c = clip()
        c.animation.opacity.value = 0.5
        var t = Track(kind: .video)
        try t.overwrite(c)
        let tl = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [t])
        #expect(tl.videoLayers(at: s(1))[0].transform.opacity == 0.5)
    }

    @Test func codableRoundTripWithKeyframes() throws {
        var c = clip()
        c.animation.position.track = KeyframeTrack(keys: [
            Keyframe(time: s(0), value: Vec2(1, 2), interpolation: .bezier, outHandle: EaseHandle(dx: 0.2, dy: 0.9)),
            Keyframe(time: s(2), value: Vec2(3, 4))])
        c.animation.volume.value = 0.5
        let back = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(c))
        #expect(back == c)
    }

    @Test func undoSnapshotRestoresAnimation() {
        var h = History(clip())
        h.commit("Rotate") { $0.animation.rotation.value = 90 }
        #expect(h.current.animation.rotation.value == 90)
        h.undo()
        #expect(h.current.animation.rotation.value == 0)
    }
}
