import Foundation
import Testing
@testable import SQCore

@Suite struct SafeZoneChoiceTests {
    @Test func offHasNoZone() {
        #expect(SafeZoneChoice.off.normRect(frameAspect: 9.0 / 16) == nil)
        #expect(SafeZoneChoice.off.offsetRect(canvasWidth: 1080, canvasHeight: 1920) == nil)
    }

    @Test func choicesAreTheCreatorPlatformsOnly() {
        #expect(SafeZoneChoice.allCases.map(\.rawValue) == ["off", "tiktok", "reels", "shorts", "youtube"])
        #expect(SafeZoneChoice(stored: "nonsense") == .off)
        #expect(SafeZoneChoice(stored: nil) == .off)
        #expect(SafeZoneChoice(stored: "reels") == .reels)
    }

    @Test func verticalFrameUsesThePlatformZone() {
        #expect(SafeZoneChoice.tiktok.normRect(frameAspect: 9.0 / 16) == SafeZone.rect(for: .tiktok, frameAspect: 9.0 / 16))
        #expect(SafeZoneChoice.shorts.normRect(frameAspect: 9.0 / 16) == SafeZone.rect(for: .shorts, frameAspect: 9.0 / 16))
    }

    @Test func widerFrameMapsThePortraitZoneIntoACentredWindow() {
        let r = SafeZoneChoice.reels.normRect(frameAspect: 16.0 / 9)!
        #expect(r.x > 0.3 && r.x + r.width < 0.7)
        #expect(abs((r.x + r.width / 2) - 0.5) < 0.1)
    }

    @Test func youtubeIsAFullFrameZoneOnAnyAspect() {
        let wide = SafeZoneChoice.youtube.normRect(frameAspect: 16.0 / 9)!
        let tall = SafeZoneChoice.youtube.normRect(frameAspect: 9.0 / 16)!
        #expect(wide == tall)
        #expect(wide.x > 0 && wide.y > 0 && wide.x + wide.width < 1 && wide.y + wide.height < 1)
    }

    @Test func offsetRectIsCentredOnTheCanvasWithYDown() {
        let z = SafeZone.zone(for: .tiktok)
        let r = SafeZoneChoice.tiktok.offsetRect(canvasWidth: 1080, canvasHeight: 1920)!
        #expect(abs(r.minX - (-540 + z.left * 1080)) < 1e-6)
        #expect(abs(r.maxX - (540 - z.right * 1080)) < 1e-6)
        #expect(abs(r.minY - (-960 + z.top * 1920)) < 1e-6)
        #expect(abs(r.maxY - (960 - z.bottom * 1920)) < 1e-6)
    }
}
