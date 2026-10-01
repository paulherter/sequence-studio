import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private let fd = Time(1, 30)

@Suite struct FixedEffectToggleTests {
    private func animated() -> Clip {
        var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: s(10), duration: s(5)), start: .zero)
        c.animation.position = AnimatedProperty(Vec2(30, 40))
        c.animation.scale = AnimatedProperty(Vec2(2, 2))
        c.animation.rotation = AnimatedProperty(45.0)
        c.animation.opacity = AnimatedProperty(0.5)
        c.blendMode = .screen
        return c
    }

    @Test func motionOffRendersAtDefaultsAndKeepsValues() {
        var c = animated()
        c.motionEnabled = false
        let t = c.transform(at: s(1))
        #expect(t.position == .zero && t.scale == Vec2(1, 1) && t.rotation == 0 && t.anchor == .zero)
        #expect(t.opacity == 0.5)                                    // Opacity is its own toggle
        #expect(c.animation.position.value == Vec2(30, 40))          // stored values stay
    }

    @Test func opacityOffRendersFullyOpaqueAndNormal() throws {
        var c = animated()
        c.opacityEnabled = false
        #expect(c.transform(at: s(1)).opacity == 1)
        #expect(c.transform(at: s(1)).position == Vec2(30, 40))
        var t = Track(kind: .video)
        try t.overwrite(c)
        let tl = Timeline(name: "t", frameDuration: fd, tracks: [t])
        #expect(tl.videoLayers(at: s(1))[0].blendMode == .normal)
        c.opacityEnabled = true
        var t2 = Track(kind: .video)
        try t2.overwrite(c)
        #expect(Timeline(name: "t", frameDuration: fd, tracks: [t2]).videoLayers(at: s(1))[0].blendMode == .screen)
    }

    @Test func togglesRoundTripAndDefaultToOn() throws {
        var c = animated()
        c.motionEnabled = false
        let data = try JSONEncoder().encode(c)
        let back = try JSONDecoder().decode(Clip.self, from: data)
        #expect(!back.motionEnabled && back.opacityEnabled)
        var obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj.removeValue(forKey: "motionEnabled"); obj.removeValue(forKey: "opacityEnabled")
        let old = try JSONDecoder().decode(Clip.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(old.motionEnabled && old.opacityEnabled)
    }
}
