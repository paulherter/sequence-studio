import Foundation
import Testing
@testable import SQCore

@Suite struct CaptionWordWidenConfidenceTests {
    @Test func aWidenedRefitKeepsTheNeighborsValue() {
        // Two packed unsure words one tick long each, no pause: the inserted word needs room, so the neighbors join the pool.
        let tick = CaptionItem.wordTick
        let a = CaptionWord(text: "aa", range: TimeRange(start: .zero, end: tick), confidence: 0.1)
        let b = CaptionWord(text: "bb", range: TimeRange(start: tick, end: tick + tick), confidence: 0.2)
        let out = CaptionItem.refit([a, b], replacing: 1..<1, with: ["xx"], duration: tick + tick)
        #expect(out.map(\.text) == ["aa", "xx", "bb"])
        #expect(out.map(\.confidence) == [0.1, nil, 0.2])
    }
}
