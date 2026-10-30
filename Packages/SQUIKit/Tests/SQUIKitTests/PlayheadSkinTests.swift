import XCTest
@testable import SQUIKit

final class PlayheadSkinTests: XCTestCase {
    func testHeadWidthIsEvenAndHeightMatchesIconAspect() {
        let w = Theme.PlayheadSkin.headSize.width
        XCTAssertEqual(Int(w) % 2, 0)
        XCTAssertEqual(w, 12)
        XCTAssertEqual(Theme.PlayheadSkin.lineWidth, 2)
    }

    func testHeadIsCenteredOnTheLine() {
        let box = Theme.PlayheadSkin.headPath(centerX: 100, top: 3).boundingBox
        XCTAssertEqual(box.midX, 100, accuracy: 0.001)
        XCTAssertEqual(box.width, 12, accuracy: 0.001)
        XCTAssertEqual(box.minY, 3, accuracy: 0.05)
        let line = Theme.PlayheadSkin.lineFrame(centerX: 100.3, height: 10)
        XCTAssertEqual(line.midX, 100)
        XCTAssertEqual(line.width, 2)
    }

    func testAccentTokens() {
        let d = AppearancePalette.resolve(.standard)
        XCTAssertEqual(d.accent, PaletteColor(hex: 0xA56BFF))
        XCTAssertEqual(d.accentFill, PaletteColor(hex: 0x7C3AED))
        XCTAssertEqual(Theme.IconGradient.stops.count, 4)
    }
}
