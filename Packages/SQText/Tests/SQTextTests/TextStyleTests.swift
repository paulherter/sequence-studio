import Testing
import Foundation
@testable import SQText

@Suite struct TextStyleTests {
    @Test func defaultsAreSane() {
        let s = TextStyle()
        #expect(s.size > 0)
        #expect(s.alignment == .center)
        #expect(s.stroke == nil && s.background == nil && s.shadow == nil)
        #expect(s.color == .white)
    }

    @Test func codableRoundTripFullStyle() throws {
        let s = TextStyle(
            fontName: "Helvetica-Bold", size: 64, weight: .bold,
            color: RGBAColor(red: 1, green: 0.5, blue: 0.25, alpha: 0.9),
            stroke: .init(color: .black, width: 4),
            background: .init(color: RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.6), padding: .init(horizontal: 16, vertical: 8), cornerRadius: 12),
            shadow: .init(color: .black, offsetX: 2, offsetY: -3, blur: 5),
            alignment: .right, lineSpacing: 6)
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(TextStyle.self, from: data) == s)
    }

    @Test func hashableDistinguishesStyles() {
        var a = TextStyle(); var b = TextStyle()
        #expect(Set([a, b]).count == 1)
        b.size = a.size + 1
        #expect(Set([a, b]).count == 2)
        a.shadow = .init(color: .black, offsetX: 1, offsetY: 1, blur: 2)
        #expect(a != TextStyle())
    }

    @Test func colorClampsToUnitRange() {
        let c = RGBAColor(red: 2, green: -1, blue: 0.5, alpha: 5)
        #expect(c.red == 1 && c.green == 0 && c.blue == 0.5 && c.alpha == 1)
    }

    @Test func weightOrderingAndValue() {
        #expect(FontWeight.regular < FontWeight.bold)
        #expect(FontWeight.bold.rawValue == 700)
    }

    @Test func sizeAndPaddingAreNonNegative() {
        #expect(TextStyle(size: -5).size == 1)
        let p = BoxPadding(horizontal: -1, vertical: 2)
        #expect(p.horizontal == 0 && p.vertical == 2)
    }
}
