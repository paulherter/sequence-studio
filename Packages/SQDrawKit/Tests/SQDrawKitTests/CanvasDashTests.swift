import Foundation
import Testing
@testable import SQDrawKit

@Suite struct CanvasDashTests {
    @Test func dashedLineDrawsOnlyTheOnParts() {
        var cv = Canvas(list: DrawList(width: 100, height: 20), atlas: nil, scale: 1)
        cv.strokeDashed([CGPoint(x: 0, y: 5), CGPoint(x: 21, y: 5)], width: 1, on: 4, off: 3, .white)
        let xs = cv.list.quads.map { ($0.x, $0.w) }
        #expect(xs.count == 3)                      // 0-4, 7-11, 14-18 (21 ends in the gap)
        #expect(xs[0] == (0, 4) && xs[1] == (7, 4) && xs[2] == (14, 4))
    }

    @Test func dashedRoundedRectFollowsTheOutline() {
        var cv = Canvas(list: DrawList(width: 100, height: 100), atlas: nil, scale: 1)
        cv.strokeDashed(roundedRect: CGRect(x: 10, y: 10, width: 60, height: 30), radius: 4, width: 1, on: 4, off: 3, .white)
        #expect(cv.list.quads.count > 15)
        for q in cv.list.quads { #expect(q.x >= 8 && q.x + q.w <= 72 && q.y >= 8 && q.y + q.h <= 42) }
    }

    @Test func fillInsideRoundedRectKeepsTheCorners() {
        var cv = Canvas(list: DrawList(width: 100, height: 40), atlas: nil, scale: 1)
        let body = CGRect(x: 0, y: 0, width: 50, height: 20)
        cv.fill(CGRect(x: 0, y: 17, width: 50, height: 3), insideRoundedRect: body, radius: 4, .white)
        let bottom = cv.list.quads.max { $0.y < $1.y }!
        #expect(bottom.x > 0.5 && bottom.x + bottom.w < 49.5)     // the last row is cut by the corner arcs
        #expect(cv.list.quads.allSatisfy { $0.y >= 17 && $0.y + $0.h <= 20.001 })
    }
}
