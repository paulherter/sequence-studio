import Foundation
import SQCore
import Testing
@testable import SQAnalysis

private func person(_ cx: Double, size: Double = 0.2) -> AnonymizePerson {
    AnonymizePerson(label: 1, point: Vec2(cx, 0.5), box: AnonymizeBox(x: cx - size / 2, y: 0.4, width: size, height: size), face: nil)
}

@Suite struct AnonymizeSearchTests {
    @Test func sampleTimesIncludeTheAnchorAndRespectTheCap() {
        let t = AnonymizeSearch.sampleTimes(first: 0, last: 10, anchor: 3.3, interval: 0.5, maxCount: 8)
        #expect(t.count <= 8)
        #expect(t.contains(3.3))
        #expect(t == t.sorted() && Set(t).count == t.count)
        #expect(AnonymizeSearch.sampleTimes(first: 2, last: 2, anchor: 2) == [2])
        #expect(AnonymizeSearch.sampleTimes(first: 0, last: 1, anchor: 5).contains(1))
    }

    @Test func aPersonWalkingAcrossFramesIsOneEntry() {
        let s = AnonymizeSearch.link([(0, [person(0.1)]), (0.5, [person(0.25)]), (1, [person(0.4)])], anchor: 0.5)
        #expect(s.count == 1)
        #expect(s[0].pts == 0.5 && s[0].firstSeen == 0)
    }

    @Test func aPersonWhoEntersLaterIsAddedWithTheirOwnFrame() {
        let s = AnonymizeSearch.link([(0, [person(0.2)]), (1, [person(0.2)]), (2, [person(0.2), person(0.8, size: 0.3)]),
                                      (3, [person(0.2), person(0.8, size: 0.4)])], anchor: 0)
        #expect(s.count == 2)
        #expect(s[0].firstSeen == 0 && s[0].pts == 0)
        #expect(s[1].firstSeen == 2 && s[1].pts == 3)           // not on the anchor frame: the largest box
    }

    @Test func aJumpBeyondReachIsAnotherPerson() {
        #expect(AnonymizeSearch.link([(0, [person(0.1)]), (0.5, [person(0.9)])], anchor: 0).count == 2)
        #expect(AnonymizeSearch.link([(0, [])], anchor: 0).isEmpty)
    }
}
