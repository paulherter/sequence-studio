import XCTest
@testable import SQUIKit

@MainActor
final class SQSliderTests: XCTestCase {
    func testValueMapping() {
        XCTAssertEqual(SQSlider.value(atX: -20, width: 100, thumb: 10, min: 0, max: 50), 0)
        XCTAssertEqual(SQSlider.value(atX: 500, width: 100, thumb: 10, min: 0, max: 50), 50)
        XCTAssertEqual(SQSlider.value(atX: 50, width: 100, thumb: 10, min: 0, max: 50), 25, accuracy: 0.001)
    }
    func testDoubleValueClamps() {
        let s = SQSlider(value: 5, minValue: 0, maxValue: 10)
        s.doubleValue = 99
        XCTAssertEqual(s.doubleValue, 10)
    }
}
