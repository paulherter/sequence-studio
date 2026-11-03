import Foundation
import Testing
import SQUIKit
@testable import SQDrawKit

@Suite("IconOutline")
struct IconOutlineTests {
    @Test func phosphorCaretIsOneFilledContourOnA256Grid() {
        let g = IconOutline.glyph(.chevronRight)
        #expect(g.grid == 256 && g.fills.count == 1 && g.strokes.isEmpty)
        #expect(g.fills[0].first == g.fills[0].last)
    }

    @Test func ownDrawingIsAStrokeOnA24Grid() {
        let g = IconOutline.glyph(.markIn)
        #expect(g.grid == 24 && g.lineWidth == 1.5 && g.fills.isEmpty && !g.strokes.isEmpty)
    }

    @Test func ringFillKeepsItsHole() {
        // Nonzero winding with an opposite inner contour: the center pixel stays empty, the band is covered.
        func square(_ a: CGFloat, _ b: CGFloat, reversed: Bool) -> [CGPoint] {
            let p = [CGPoint(x: a, y: a), CGPoint(x: b, y: a), CGPoint(x: b, y: b), CGPoint(x: a, y: b), CGPoint(x: a, y: a)]
            return reversed ? p.reversed() : p
        }
        var c = Canvas(width: 12, height: 12, atlas: nil, scale: 1)
        c.fill(contours: [square(0, 12, reversed: false), square(4, 8, reversed: true)], .white)
        let covered = c.list.quads.reduce(Float(0)) { $0 + $1.w * $1.h }
        #expect(abs(covered - (144 - 16)) < 0.5)
    }

    @Test func halfPixelEdgeGetsHalfAlpha() {
        var c = Canvas(width: 4, height: 4, atlas: nil, scale: 1)
        c.fill(contours: [[CGPoint(x: 0, y: 0), CGPoint(x: 1.5, y: 0), CGPoint(x: 1.5, y: 2), CGPoint(x: 0, y: 2)]], .white)
        #expect(c.list.quads.contains { abs($0.a - 0.5) < 0.05 })
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
        #expect(!c.list.quads.isEmpty)
    }
}
