import Testing
import SQCore
@testable import SQPlayback

@Suite struct PreviewRateTests {
    @Test func presetsCoverHalfSpeedToTenTimes() {
        let values = PreviewRate.presets.map { Double($0.rate.num) / Double($0.rate.den) }
        #expect(values.first == 0.5 && values.last == 10)
        #expect(values == values.sorted())
        #expect(PreviewRate.presets.contains(.normal))
    }

    @Test func clampsIntoRangeAndDropsDirection() {
        #expect(PreviewRate(PlaybackRate(1, 8)).rate == PlaybackRate(1, 2))
        #expect(PreviewRate(PlaybackRate(32)).rate == PlaybackRate(10))
        #expect(PreviewRate(PlaybackRate(-2)).rate == PlaybackRate(2))
        #expect(PreviewRate(PlaybackRate(0)).rate == PlaybackRate(1, 2))
    }

    @Test func titles() {
        #expect(PreviewRate.presets.first?.title == "0.5x")
        #expect(PreviewRate(PlaybackRate(5, 4)).title == "1.25x")
        #expect(PreviewRate.normal.title == "Normal (1x)")
        #expect(PreviewRate(PlaybackRate(10)).title == "10x")
    }
}
