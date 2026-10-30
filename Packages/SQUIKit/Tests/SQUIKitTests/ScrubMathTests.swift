import Testing
@testable import SQUIKit

@Suite struct ScrubMathTests {
    @Test func multipliers() {
        #expect(ScrubMath.multiplier(shift: false, option: false) == 1)
        #expect(ScrubMath.multiplier(shift: true, option: false) == 10)
        #expect(ScrubMath.multiplier(shift: false, option: true) == 0.1)
        #expect(ScrubMath.multiplier(shift: true, option: true) == 1)
    }

    @Test func dragDelta() {
        let r = -100.0...100.0
        #expect(ScrubMath.value(start: 10, deltaPixels: 5, step: 1, shift: false, option: false, range: r) == 15)
        #expect(ScrubMath.value(start: 10, deltaPixels: -5, step: 1, shift: false, option: false, range: r) == 5)
        #expect(ScrubMath.value(start: 0, deltaPixels: 3, step: 1, shift: true, option: false, range: r) == 30)
        #expect(ScrubMath.value(start: 0, deltaPixels: 3, step: 1, shift: false, option: true, range: r) == 0.3)
        #expect(ScrubMath.value(start: 0, deltaPixels: 7, step: 0.5, shift: false, option: false, range: r) == 3.5)
    }

    @Test func clamping() {
        let r = 0.0...100.0
        #expect(ScrubMath.value(start: 95, deltaPixels: 50, step: 1, shift: false, option: false, range: r) == 100)
        #expect(ScrubMath.value(start: 5, deltaPixels: -50, step: 1, shift: false, option: false, range: r) == 0)
        #expect(ScrubMath.clamp(-3, to: r) == 0)
        #expect(ScrubMath.clamp(.nan, to: r) == 0)
    }

    @Test func roundingToGrid() {
        let r = -1000.0...1000.0
        // Fractional pixel deltas (trackpad) still land on the step grid.
        #expect(ScrubMath.value(start: 0, deltaPixels: 2.4, step: 1, shift: false, option: false, range: r) == 2)
        #expect(ScrubMath.value(start: 0, deltaPixels: 2.6, step: 1, shift: false, option: false, range: r) == 3)
        #expect(ScrubMath.value(start: 0, deltaPixels: 3, step: 0.1, shift: false, option: false, range: r) == 0.3)
        #expect(ScrubMath.value(start: 0.1, deltaPixels: 2, step: 0.1, shift: false, option: false, range: r) == 0.3)
        #expect(ScrubMath.value(start: 0, deltaPixels: 4, step: 1, shift: false, option: true, range: r) == 0.4)
        // Off-grid start is stable at delta 0.
        #expect(ScrubMath.value(start: 12.34, deltaPixels: 0, step: 1, shift: false, option: false, range: r) == 12.34)
    }

    @Test func parsing() {
        #expect(ScrubMath.parse("42", unit: "%") == 42)
        #expect(ScrubMath.parse("42 %", unit: "%") == 42)
        #expect(ScrubMath.parse("42%", unit: "%") == 42)
        #expect(ScrubMath.parse("1,5", unit: "s") == 1.5)
        #expect(ScrubMath.parse(" -3,25 dB ", unit: "dB") == -3.25)
        #expect(ScrubMath.parse("\u{2212}6 dB", unit: "dB") == -6)
        #expect(ScrubMath.parse("90°", unit: "°") == 90)
        #expect(ScrubMath.parse("12 DB", unit: "dB") == 12)
        #expect(ScrubMath.parse("+5", unit: "") == 5)
        #expect(ScrubMath.parse("1.5", unit: "") == 1.5)
    }

    @Test func simpleMaths() {
        func ev(_ t: String, unit: String = "", cur: Double = 100, neg: Bool = true) -> Double? {
            ScrubMath.evaluate(t, unit: unit, current: cur, negativeAllowed: neg)
        }
        #expect(ev("42") == 42)
        #expect(ev("10+5") == 15)
        #expect(ev("1080/2") == 540)
        #expect(ev("2+3*4") == 14)
        #expect(ev("(2+3)*4") == 20)
        #expect(ev("1,5*2") == 3)
        #expect(ev("-5") == -5)               // negative field: plain number
        #expect(ev("-5", neg: false) == 95)   // cannot be negative: relative
        #expect(ev("+10") == 110)
        #expect(ev("+-5") == 95)
        #expect(ev("*2") == 200)
        #expect(ev("/4") == 25)
        #expect(ev("*2+1") == 300)
        #expect(ev("+10%", unit: "%") == 110)
        #expect(ev("50% + 5%", unit: "%") == 55)
        #expect(ev("2 s", unit: "s") == 2)
        #expect(ev("-3 - -2") == -1)
    }

    @Test func simpleMathsRejects() {
        for bad in ["", "+", "*", "abc", "1/0", "/0", "2**3", "(2", "2)", "1+", "1..2", "1e5", "nan", "inf",
                    "sqrt(4)", "2^3", "1;2", "$(x)", String(repeating: "(", count: 100) + "1" + String(repeating: ")", count: 100)] {
            #expect(ScrubMath.evaluate(bad, unit: "", current: 1) == nil, "\(bad)")
        }
    }

    @Test func parsingRejects() {
        #expect(ScrubMath.parse("", unit: "%") == nil)
        #expect(ScrubMath.parse("abc", unit: "%") == nil)
        #expect(ScrubMath.parse("1,2,3", unit: "") == nil)
        #expect(ScrubMath.parse("nan", unit: "") == nil)
        #expect(ScrubMath.parse("inf", unit: "") == nil)
        #expect(ScrubMath.parse("5 px", unit: "%") == nil)
    }

    @Test func formatting() {
        #expect(ScrubMath.format(42, decimals: 0, unit: "%") == "42 %")
        #expect(ScrubMath.format(1.5, decimals: 2, unit: "s") == "1.50 s")
        #expect(ScrubMath.format(-3.5, decimals: 1, unit: "") == "-3.5")
        #expect(ScrubMath.format(90, decimals: 0, unit: "°") == "90°")
        #expect(ScrubMath.format(-0.0001, decimals: 1, unit: "") == "0.0")
    }

    @Test func arrowStep() {
        let r = 0.0...10.0
        #expect(ScrubMath.stepped(5, direction: 1, step: 1, shift: false, option: false, range: r) == 6)
        #expect(ScrubMath.stepped(5, direction: -1, step: 1, shift: true, option: false, range: r) == 0)
        #expect(ScrubMath.stepped(5, direction: 1, step: 1, shift: false, option: true, range: r) == 5.1)
    }
}
