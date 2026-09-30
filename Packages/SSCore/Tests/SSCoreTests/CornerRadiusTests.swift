import Foundation
import Testing
@testable import SSCore

private func s(_ n: Int64) -> Time { Time(n, 1) }

@Suite struct CornerRadiusTests {
    private func clip() -> Clip {
        Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: s(10), duration: s(4)), start: s(2))
    }

    @Test func defaultIsZero() {
        #expect(ClipAnimation().cornerRadius.value == 0)
        #expect(clip().effects(at: s(3)) == ClipEffects.none)
    }

    @Test func staticValueAndClamp() {
        var c = clip()
        c.animation.cornerRadius = AnimatedProperty(32.0)
        #expect(c.effects(at: s(3)).cornerRadius == 32)
        c.animation.cornerRadius = AnimatedProperty(-8.0)
        #expect(c.effects(at: s(3)).cornerRadius == 0)
    }

    @Test func keyframesAreClipLocal() {
        var c = clip()
        c.animation.cornerRadius = AnimatedProperty(0.0, track: KeyframeTrack(keys: [
            Keyframe(time: s(0), value: 0.0), Keyframe(time: s(4), value: 40.0)]))
        #expect(c.effects(at: s(2)).cornerRadius == 0)
        #expect(abs(c.effects(at: s(4)).cornerRadius - 20) < 1e-9)       // clip-local 2 of 4
        #expect(c.effects(at: s(6)).cornerRadius == 40)
    }

    @Test func keysFollowSourceFramesWhenCropped() {
        var c = clip()
        c.animation.cornerRadius = AnimatedProperty(0.0, track: KeyframeTrack(keys: [
            Keyframe(time: s(0), value: 0.0), Keyframe(time: s(4), value: 40.0)]))
        let right = c.cropped(to: TimeRange(start: s(4), end: s(6)))!
        #expect(right.animation.cornerRadius.track.keys.map(\.time) == [s(-2), s(2)])
        #expect(abs(right.effects(at: s(4)).cornerRadius - 20) < 1e-9)
    }

    @Test func filledIntoLayerRequest() throws {
        var c = clip()
        c.animation.cornerRadius = AnimatedProperty(12.0)
        var t = Track(kind: .video)
        try t.overwrite(c)
        let tl = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [t])
        #expect(tl.videoLayers(at: s(3))[0].cornerRadius == 12)
    }

    @Test func v4ClipDecodesWithZeroRadius() throws {
        let c = clip()
        var data = try JSONEncoder().encode(c)
        var obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var anim = try #require(obj["animation"] as? [String: Any])
        anim.removeValue(forKey: "cornerRadius")
        obj["animation"] = anim
        obj.removeValue(forKey: "sequence")
        data = try JSONSerialization.data(withJSONObject: obj)
        let back = try JSONDecoder().decode(Clip.self, from: data)
        #expect(back.animation.cornerRadius.value == 0)
        #expect(back.sequence == nil)
        #expect(back == c)
    }
}
