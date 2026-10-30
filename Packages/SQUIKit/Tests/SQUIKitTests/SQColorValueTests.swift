import Testing
@testable import SQUIKit

@Suite struct SQColorValueTests {
    @Test func rgbHSBRoundTrip() {
        for (r, g, b) in [(1.0, 0.0, 0.0), (0.2, 0.6, 0.9), (0.5, 0.5, 0.5), (0.0, 0.0, 0.0), (1.0, 1.0, 0.1)] {
            let c = SQColorValue(r: r, g: g, b: b).rgb
            #expect(abs(c.r - r) < 1e-9 && abs(c.g - g) < 1e-9 && abs(c.b - b) < 1e-9)
        }
    }
    @Test func hexFormatAndParse() {
        #expect(SQColorValue(r: 1, g: 0.5, b: 0).hex == "FF8000")
        #expect(SQColorValue.parse(hex: "#ff8000")?.hex == "FF8000")
        #expect(SQColorValue.parse(hex: "f80")?.hex == "FF8800")
        #expect(SQColorValue.parse(hex: "FF800080")?.a ?? 0 > 0.49)
        #expect(SQColorValue.parse(hex: "12") == nil)
        #expect(SQColorValue.parse(hex: "GG0000") == nil)
        #expect(SQColorValue.parse(hex: "ff0000", keepingAlpha: 0.3)?.a == 0.3)
    }
    @Test func clampsInputs() {
        let v = SQColorValue(h: 2, s: -1, b: 5, a: 9)
        #expect(v.h == 1 && v.s == 0 && v.b == 1 && v.a == 1)
    }
}
