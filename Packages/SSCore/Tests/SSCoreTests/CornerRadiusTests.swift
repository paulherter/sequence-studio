import Foundation
import Testing
@testable import SSCore

private func s(_ n: Int64) -> Time { Time(n, 1) }

@Suite struct CornerRadiusTests {
    private func clip() -> Clip {
        Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: s(10), duration: s(4)), start: s(2))
    }

    @Test func defaultIsZero() {
        #expect(clip().effects.isEmpty)
        #expect(clip().effects(at: s(3)) == ClipEffects.none)
    }

    @Test func staticValueAndClamp() {
        var c = clip()
        c.roundedCorners = .roundedCorners(radius: 32)
        #expect(c.effects(at: s(3)).cornerRadius == 32)
        c.roundedCorners = .roundedCorners(radius: -8)
        #expect(c.effects(at: s(3)).cornerRadius == 0)
    }

    @Test func keyframesAreClipLocal() {
        var c = clip()
        c.roundedCorners = ClipEffect(kind: ClipEffect.roundedCornersKind, parameters: [ClipEffect.radiusKey:
            AnimatedProperty(0.0, track: KeyframeTrack(keys: [Keyframe(time: s(0), value: 0.0), Keyframe(time: s(4), value: 40.0)]))])
        #expect(c.effects(at: s(2)).cornerRadius == 0)
        #expect(abs(c.effects(at: s(4)).cornerRadius - 20) < 1e-9)       // clip-local 2 of 4
        #expect(c.effects(at: s(6)).cornerRadius == 40)
    }

    @Test func keysFollowSourceFramesWhenCropped() {
        var c = clip()
        c.roundedCorners = ClipEffect(kind: ClipEffect.roundedCornersKind, parameters: [ClipEffect.radiusKey:
            AnimatedProperty(0.0, track: KeyframeTrack(keys: [Keyframe(time: s(0), value: 0.0), Keyframe(time: s(4), value: 40.0)]))])
        let right = c.cropped(to: TimeRange(start: s(4), end: s(6)))!
        #expect(right.roundedCorners!.parameters[ClipEffect.radiusKey]!.track.keys.map(\.time) == [s(-2), s(2)])
        #expect(abs(right.effects(at: s(4)).cornerRadius - 20) < 1e-9)
    }

    @Test func filledIntoLayerRequest() throws {
        var c = clip()
        c.roundedCorners = .roundedCorners(radius: 12)
        var t = Track(kind: .video)
        try t.overwrite(c)
        let tl = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [t])
        #expect(tl.videoLayers(at: s(3))[0].cornerRadius == 12)
    }

    @Test func disabledEffectRendersAsAbsent() {
        var c = clip()
        c.roundedCorners = .roundedCorners(radius: 20)
        c.roundedCorners?.enabled = false
        #expect(c.effects(at: s(3)) == ClipEffects.none)
        #expect(c.roundedCorners?.parameters[ClipEffect.radiusKey]?.value == 20)   // values kept
    }

    @Test func v4ClipDecodesWithoutEffects() throws {
        let c = clip()
        var data = try JSONEncoder().encode(c)
        var obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var anim = try #require(obj["animation"] as? [String: Any])
        anim.removeValue(forKey: "cornerRadius")
        obj["animation"] = anim
        obj.removeValue(forKey: "effects")
        obj.removeValue(forKey: "sequence")
        data = try JSONSerialization.data(withJSONObject: obj)
        let back = try JSONDecoder().decode(Clip.self, from: data)
        #expect(back.effects.isEmpty)
        #expect(back == c)
    }

    private func legacyData(radius: Double?) throws -> Data {
        let data = try JSONEncoder().encode(clip())
        var obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var anim = try #require(obj["animation"] as? [String: Any])
        if let r = radius { anim["cornerRadius"] = ["value": r, "track": ["keys": []]] }
        obj["animation"] = anim
        obj.removeValue(forKey: "effects")
        return try JSONSerialization.data(withJSONObject: obj)
    }

    @Test func v8NonDefaultRadiusBecomesAppliedEffect() throws {
        let back = try JSONDecoder().decode(Clip.self, from: legacyData(radius: 16))
        #expect(back.roundedCorners?.parameters[ClipEffect.radiusKey]?.value == 16)
        #expect(back.roundedCorners?.enabled == true)
        #expect(back.effects(at: s(3)).cornerRadius == 16)
        // Re-encoding writes the effect, not the old key.
        let re = try JSONSerialization.jsonObject(with: JSONEncoder().encode(back)) as! [String: Any]
        #expect((re["animation"] as! [String: Any])["cornerRadius"] == nil)
        #expect(try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(back)) == back)
    }

    @Test func v8DefaultRadiusMeansNotApplied() throws {
        #expect(try JSONDecoder().decode(Clip.self, from: legacyData(radius: 0)).effects.isEmpty)
        #expect(try JSONDecoder().decode(Clip.self, from: legacyData(radius: nil)).effects.isEmpty)
    }
}
