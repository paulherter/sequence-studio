import Testing
@testable import SQRender

@Suite struct AntiFlickerTests {
    @Test func strengthZeroLeavesTheColumnUntouched() {
        let col: [Float] = [0, 1, 0, 1, 0]
        #expect(AntiFlickerFilter.filtered(column: col, strength: 0) == col)
        #expect(AntiFlickerFilter.neighborWeight(strength: -3) == 0)
    }

    @Test func fullStrengthIsOneTwoOneAndEdgesRepeat() {
        let out = AntiFlickerFilter.filtered(column: [0, 1, 0, 1], strength: 1)
        #expect(out == [0.25, 0.5, 0.5, 0.75])
        #expect(AntiFlickerFilter.neighborWeight(strength: 7) == 0.25)
    }

    @Test func halfStrengthMixesLess() {
        let out = AntiFlickerFilter.filtered(column: [0, 1, 0], strength: 0.5)
        #expect(out[1] == 0.75 && out[0] == 0.125)
    }
}
