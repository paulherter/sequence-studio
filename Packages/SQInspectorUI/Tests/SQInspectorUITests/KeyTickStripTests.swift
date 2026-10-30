import Testing
import SQCore
@testable import SQInspectorUI

@MainActor @Suite struct KeyTickStripTests {
    @Test func ticksSitProportionallyAndClamp() {
        let xs = KeyTickStrip.positions(times: [.zero, Time(1, 1), Time(2, 1), Time(9, 1)], duration: Time(2, 1), width: 100)
        #expect(xs == [0, 50, 100, 100])
        #expect(KeyTickStrip.positions(times: [Time(1, 1)], duration: .zero, width: 100) == [0])
        #expect(KeyTickStrip.positions(times: [Time(1, 1)], duration: Time(2, 1), width: 0).isEmpty)
    }

    @Test func clickMapsBackToAClipTime() {
        let d = Time(4, 1)
        #expect(KeyTickStrip.time(atX: 25, width: 100, duration: d) == Time(1, 1))
        #expect(KeyTickStrip.time(atX: -5, width: 100, duration: d) == .zero)
        #expect(KeyTickStrip.time(atX: 500, width: 100, duration: d) == d)
    }

    @Test func easeMenuFollowsTheVocabularyOrder() {
        #expect(GraphicsKeyEase.menuTitles == ["Steady", "Smooth", "Smooth In", "Smooth Out", "Hold", "Fast Start", "Fast End",
                                               "Gentle", "Smooth In 100%", "Smooth Out 100%", "Soft Landing", "Custom\u{2026}"])
        #expect(Array(GraphicsKeyEase.menuTitles.prefix(5)) == EaseName.keyframeMenu)
    }
}
