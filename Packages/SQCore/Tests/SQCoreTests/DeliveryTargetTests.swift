import Foundation
import Testing
@testable import SQCore

@Suite struct DeliveryTargetTests {
    @Test func loudnessGroupsAreVerticalAndHorizontal() {
        for p in [DeliveryPlatform.tiktok, .reels, .shorts, .socialFeed] { #expect(p.loudnessGroup == .vertical) }
        #expect(DeliveryPlatform.youtube.loudnessGroup == .horizontal)
        let tt = DeliveryTarget(platform: .tiktok), rl = DeliveryTarget(platform: .reels), sh = DeliveryTarget(platform: .shorts)
        #expect(tt.targetLUFS == rl.targetLUFS && rl.targetLUFS == sh.targetLUFS)
        #expect(tt.targetLUFS == -14 && tt.truePeakDB == -1)
        #expect(DeliveryTarget(platform: .youtube).targetLUFS == -14)
    }

    @Test func zoneTablePerPlatform() {
        #expect(DeliveryPlatform.tiktok.safeZone == SafeZone.zone(for: .tiktok))
        #expect(DeliveryPlatform.reels.safeZone == SafeZone.zone(for: .reels))
        #expect(DeliveryPlatform.shorts.safeZone == SafeZone.zone(for: .shorts))
        #expect(DeliveryPlatform.socialFeed.safeZone == nil && DeliveryPlatform.youtube.safeZone == nil)
        #expect(SafeZoneChoice(platform: .reels) == .reels)
        #expect(SafeZoneChoice(platform: .youtube) == .off)
    }

    @Test func oldTimelineDecodesWithoutTarget() throws {
        let t = Timeline(name: "A", frameDuration: Time(1, 30))
        var obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(t)) as! [String: Any]
        obj.removeValue(forKey: "deliveryTarget")
        let back = try JSONDecoder().decode(Timeline.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(back.deliveryTarget == nil)
    }

    @Test func targetRoundTripsAndPartialTargetDecodesDefaults() throws {
        var t = Timeline(name: "A", frameDuration: Time(1, 30))
        t.deliveryTarget = DeliveryTarget(platform: .reels)
        let back = try JSONDecoder().decode(Timeline.self, from: JSONEncoder().encode(t))
        #expect(back.deliveryTarget == DeliveryTarget(platform: .reels))
        let partial = try JSONDecoder().decode(DeliveryTarget.self, from: Data(#"{"platform":"youtube"}"#.utf8))
        #expect(partial == DeliveryTarget(platform: .youtube))
    }

    @Test func socialPresetsCarryTargets() {
        let n = SequenceFormatPresets.named
        func p(_ s: String) -> SequenceFormatPresets.Named? { n.first { $0.name.hasPrefix(s) } }
        #expect(p("TikTok")?.deliveryTarget?.platform == .tiktok && p("TikTok")?.format.height == 1920)
        #expect(p("Instagram Reels")?.deliveryTarget?.platform == .reels)
        #expect(p("YouTube Shorts")?.deliveryTarget?.platform == .shorts)
        #expect(p("YouTube 1080p")?.deliveryTarget?.platform == .youtube)
        #expect(n.contains { $0.format.width == 1080 && $0.format.height == 1350 && $0.deliveryTarget != nil })
        #expect(n.contains { $0.format.width == 1080 && $0.format.height == 1080 && $0.deliveryTarget != nil })
        #expect(n.contains { $0.format.width == 1440 && $0.format.height == 1080 && $0.deliveryTarget?.platform == .youtube })
        #expect(Set(n.map(\.name)).count == n.count)
    }

    @Test func projectSetsTarget() throws {
        var p = Project(name: "P")
        let t = Timeline(name: "A", frameDuration: Time(1, 30))
        p.timelines = [t]
        try p.setDeliveryTarget(DeliveryTarget(platform: .tiktok), of: t.id)
        #expect(p.timelines[0].deliveryTarget?.platform == .tiktok)
    }
}
