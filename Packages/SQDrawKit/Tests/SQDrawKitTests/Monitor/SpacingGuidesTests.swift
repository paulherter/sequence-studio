import Foundation
import Testing
@testable import SQDrawKit

@Suite struct SpacingGuidesTests {
    let left = CGRect(x: 0, y: 0, width: 100, height: 100)
    let right = CGRect(x: 300, y: 0, width: 100, height: 100)

    @Test func snapsToEqualGapOnX() {
        let box = CGRect(x: 153, y: 10, width: 50, height: 50)   // gaps 53 and 97 -> want x = 175
        let r = SpacingGuides.snap(box: box, others: [left, right], threshold: 30)
        #expect(abs(r.dx - 22) < 1e-9)
        #expect(r.dy == 0)
        #expect(r.gaps.count == 2)
        #expect(r.gaps[0].from == 100 && abs(r.gaps[0].to - 175) < 1e-9)
    }

    @Test func outsideThresholdDoesNothing() {
        let box = CGRect(x: 110, y: 10, width: 50, height: 50)   // needs 65
        #expect(SpacingGuides.snap(box: box, others: [left, right], threshold: 6) == .none)
    }

    @Test func needsBothNeighborsAndRowOverlap() {
        let box = CGRect(x: 170, y: 500, width: 50, height: 50)  // no row overlap
        #expect(SpacingGuides.snap(box: box, others: [left, right], threshold: 30) == .none)
        #expect(SpacingGuides.snap(box: CGRect(x: 170, y: 10, width: 50, height: 50), others: [left], threshold: 30) == .none)
    }

    @Test func snapsOnY() {
        let top = CGRect(x: 0, y: 0, width: 100, height: 50), bottom = CGRect(x: 0, y: 250, width: 100, height: 50)
        let r = SpacingGuides.snap(box: CGRect(x: 10, y: 120, width: 50, height: 50), others: [top, bottom], threshold: 30)
        #expect(abs(r.dy - 5) < 1e-9)   // free 100 -> top gap 50, box.minY 100
    }
}
