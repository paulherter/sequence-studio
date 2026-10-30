import Testing
@testable import SQInspectorUI

@Suite struct CaptionOffsetDisplayTests {
    @Test func yIsShownUp() {
        #expect(CaptionOffsetDisplay.shown(0.1, isY: true) == -10)      // stored down, shown up
        #expect(CaptionOffsetDisplay.shown(-0.25, isY: true) == 25)
        #expect(CaptionOffsetDisplay.shown(0.1, isY: false) == 10)
    }
    @Test func roundTripAndNoNegativeZero() {
        for v in stride(from: -0.5, through: 0.5, by: 0.125) {
            #expect(CaptionOffsetDisplay.stored(CaptionOffsetDisplay.shown(v, isY: true), isY: true) == v)
            #expect(CaptionOffsetDisplay.stored(CaptionOffsetDisplay.shown(v, isY: false), isY: false) == v)
        }
        #expect(CaptionOffsetDisplay.shown(0, isY: true).sign == .plus)
        #expect(CaptionOffsetDisplay.stored(0, isY: true).sign == .plus)
    }
}
