import Foundation
import SQCore
import Testing
@testable import SQDrawKit

@Suite struct CropHandleGeometryTests {
    /// Frame drawn 200 x 100 at (50, 40).
    private let quad = [CGPoint(x: 50, y: 40), CGPoint(x: 250, y: 40), CGPoint(x: 250, y: 140), CGPoint(x: 50, y: 140)]

    private func near(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) < 1e-6 && abs(a.y - b.y) < 1e-6 }

    @Test func handlesSitAtTheMiddleOfEachCroppedEdge() {
        let g = CropHandleGeometry(quad: quad)
        let i = CropInsets(left: 0.1, top: 0.2, right: 0.3, bottom: 0)
        #expect(near(g.handlePoint(.left, i), CGPoint(x: 70, y: 40 + 100 * (0.2 + 0.4))))
        #expect(near(g.handlePoint(.top, i), CGPoint(x: 50 + 200 * (0.1 + 0.3), y: 60)))
        #expect(near(g.handlePoint(.right, i), CGPoint(x: 50 + 200 * 0.7, y: 40 + 100 * 0.6)))
        #expect(near(g.handlePoint(.bottom, i), CGPoint(x: 50 + 200 * 0.4, y: 140)))
    }

    @Test func hitPicksTheNearestHandleOnly() {
        let g = CropHandleGeometry(quad: quad)
        let i = CropInsets.none
        #expect(g.hit(CGPoint(x: 52, y: 90), i) == .left)
        #expect(g.hit(CGPoint(x: 150, y: 138), i) == .bottom)
        #expect(g.hit(CGPoint(x: 150, y: 90), i) == nil)
    }

    @Test func dragWritesOnlyThatEdgeAndClamps() {
        let g = CropHandleGeometry(quad: quad)
        let i = CropInsets(left: 0, top: 0, right: 0.5, bottom: 0)
        #expect(g.inset(.left, at: CGPoint(x: 100, y: 90), current: i) == 0.25)
        #expect(g.inset(.left, at: CGPoint(x: 0, y: 90), current: i) == 0)               // outside: no negative crop
        #expect(g.inset(.left, at: CGPoint(x: 240, y: 90), current: i) == 0.5 - CropHandleGeometry.minRemaining)
        #expect(g.inset(.bottom, at: CGPoint(x: 150, y: 115), current: i) == 0.25)
    }

    @Test func rotatedLayerStillDragsAlongItsOwnAxis() {
        // Rotated 90 degrees: the frame's x axis points down the screen.
        let q = [CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 200), CGPoint(x: 0, y: 200), CGPoint(x: 0, y: 0)]
        let g = CropHandleGeometry(quad: q)
        #expect(g.inset(.top, at: CGPoint(x: 75, y: 50), current: .none) == 0.25)
    }

    @Test func edgesMapToTheEffectKeys() {
        #expect(CropEdge.allCases.map(\.effectKey) == ["left", "top", "right", "bottom"])
        #expect(CropEdge.top.setting(0.2, in: .none) == CropInsets(top: 0.2))
    }
}
