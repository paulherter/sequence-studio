import Foundation
import Testing
import SQUIKit
@testable import SQDrawKit

@Suite("IconOutline")
struct IconOutlineTests {
    @Test func chevronRightIsOnePolyline() {
        let o = IconOutline.outline(.chevronRight)
        #expect(o == [[CGPoint(x: 9, y: 18), CGPoint(x: 15, y: 12), CGPoint(x: 9, y: 6)]])
    }

    @Test func curvesFlattenIntoSteps() {
        let o = IconOutline()
        o.sinkMove(CGPoint(x: 0, y: 0))
        o.sinkCurve(to: CGPoint(x: 8, y: 0), control1: CGPoint(x: 2, y: 4), control2: CGPoint(x: 6, y: 4))
        let lines = o.finish()
        #expect(lines.count == 1 && lines[0].count == 1 + IconOutline.curveSteps)
        #expect(lines[0].last == CGPoint(x: 8, y: 0))
    }

    @Test func circleBecomesAClosedOutline() {
        let shapes = SQIconSVG.shapes(#"<svg><circle cx="12" cy="12" r="10"/></svg>"#) { IconOutline() }
        let lines = shapes.flatMap { $0.0.finish() }
        #expect(lines.count == 1)
        #expect(lines[0].first == lines[0].last)
    }

    @Test func iconDrawsSegments() {
        var c = Canvas(width: 64, height: 64, atlas: nil, scale: 2)
        c.draw(icon: .chevronRight, at: .zero, size: 16, .white)
        #expect(c.list.quads.count == 2)
    }
}
