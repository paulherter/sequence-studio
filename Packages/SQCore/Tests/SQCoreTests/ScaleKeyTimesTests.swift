import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }

private func vclip(dur: Int64) -> Clip {
    Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: s(0), duration: s(dur)), start: s(0))
}

private func zoomClip(dur: Int64) -> Clip {
    var c = vclip(dur: dur)
    c.animation.scale = AnimatedProperty(Vec2(1, 1), track: KeyframeTrack(keys: [
        Keyframe(time: s(0), value: Vec2(1, 1)), Keyframe(time: s(2), value: Vec2(1.2, 1.2))]))
    return c
}

@Suite struct ScaleKeyTimesTests {
    @Test func shrinksKeysToTheTargetLength() {
        let out = zoomClip(dur: 2).keyTimesScaled(toDuration: s(1))
        #expect(out.animation.scale.track.keys.map(\.time) == [s(0), s(1)])
    }

    @Test func stretchesAnimationAndEffectKeys() {
        var src = zoomClip(dur: 2)
        var e = ClipEffect(kind: "blur")
        e.parameters["radius"] = AnimatedProperty(0.0, track: KeyframeTrack(keys: [Keyframe(time: s(2), value: 10.0)]))
        src.effects = [e]
        let out = src.keyTimesScaled(toDuration: s(4))
        #expect(out.animation.scale.track.keys.map(\.time) == [s(0), s(4)])
        #expect(out.effects.first?.parameters["radius"]?.track.keys.map(\.time) == [s(4)])
    }

    @Test func sameLengthIsIdentity() {
        let c = zoomClip(dur: 2)
        #expect(c.keyTimesScaled(toDuration: s(2)) == c)
    }

    @Test func maskKeysScaleExactlyOnce() {
        var c = vclip(dur: 2)
        var m = ClipMask(path: .rectangle(Vec2(0.2, 0.2), Vec2(0.8, 0.8)))
        m.feather = AnimatedProperty(0.0, track: KeyframeTrack(keys: [Keyframe(time: s(2), value: 5.0)]))
        c.masks = [m]
        let out = c.keyTimesScaled(toDuration: s(4))
        #expect(out.masks.first?.feather.track.keys.map(\.time) == [s(4)])
    }
}
