import Foundation
import Testing
import SQCore
@testable import SQExport

@Suite struct PlatformSpecSoftLimitTests {
    @Test func softLimitsComeFromTheBundledSpec() {
        #expect(PlatformSpec.bundled.entry("shorts")?.softDurationSeconds == 180)
        #expect(PlatformSpec.bundled.entry("reels")?.softDurationSeconds == 90)
        #expect(PlatformSpec.bundled.entry("tiktok")?.softDurationSeconds == nil)
        #expect(DeliveryAdvice.softDurationLimit(of: .preset(.shorts, .h264)) == Time(180, 1))
        #expect(DeliveryAdvice.softDurationLimit(of: .preset(.reels, .h264)) == Time(90, 1))
        #expect(DeliveryAdvice.softDurationLimit(of: .preset(.tiktok, .h264)) == nil)
    }
}
