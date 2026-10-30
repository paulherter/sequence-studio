import Testing
@testable import SQInspectorUI

@Suite struct ColorStepTabPartsTests {
    @Test func hueBarEdgesRoundTripThroughCenterAndWidth() {
        let values = ColorRangeRow.params(.hue, low: 20, high: 80)
        #expect(values.map(\.0) == [.hueCenter, .hueWidth])
        #expect(values.map(\.1) == [50, 60])
        let (lo, hi) = ColorRangeRow.bounds(.hue, first: Double(values[0].1), second: Double(values[1].1))
        #expect(lo == 20 && hi == 80)
    }

    @Test func hueBarClampsToTheWheel() {
        let (lo, hi) = ColorRangeRow.bounds(.hue, first: 350, second: 60)
        #expect(lo == 320 && hi == 360)
    }

    @Test func saturationAndLumaBarsAreMinAndMax() {
        #expect(ColorRangeRow.params(.saturation, low: 10, high: 70).map(\.0) == [.satMin, .satMax])
        #expect(ColorRangeRow.params(.luma, low: 5, high: 95).map(\.1) == [5, 95])
        let (lo, hi) = ColorRangeRow.bounds(.luma, first: 5, second: 95)
        #expect(lo == 5 && hi == 95)
    }
}
