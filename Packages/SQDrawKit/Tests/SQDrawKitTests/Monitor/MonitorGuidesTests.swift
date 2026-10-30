import Foundation
import Testing
@testable import SQDrawKit

@Suite struct MonitorGuidesTests {
    @Test func addMoveRemoveClampIntoThePicture() {
        var g = MonitorGuides()
        #expect(g.isEmpty)
        let v = g.add(.vertical, at: 1.4)
        let h = g.add(.horizontal, at: -0.2)
        #expect(g.vertical == [1] && g.horizontal == [0])
        g.move(.vertical, index: v, to: 0.25)
        #expect(g.vertical == [0.25])
        g.remove(.horizontal, index: h)
        #expect(g.horizontal.isEmpty)
        g.move(.vertical, index: 9, to: 0.5)   // out of range: ignored
        #expect(g.vertical == [0.25])
        g.clear()
        #expect(g.isEmpty)
    }

    @Test func nearestAndSnapRespectTheTolerance() {
        var g = MonitorGuides()
        g.add(.vertical, at: 0.2); g.add(.vertical, at: 0.5)
        #expect(g.nearest(.vertical, to: 0.48, tolerance: 0.05) == 1)
        #expect(g.nearest(.vertical, to: 0.35, tolerance: 0.05) == nil)
        #expect(g.snapped(.vertical, 0.49, tolerance: 0.02) == 0.5)
        #expect(g.snapped(.vertical, 0.4, tolerance: 0.02) == 0.4)
        #expect(g.snapped(.horizontal, 0.5, tolerance: 0.5) == 0.5)   // other axis has no guides
    }

    @Test func allListsBothAxes() {
        var g = MonitorGuides()
        g.add(.vertical, at: 0.1); g.add(.horizontal, at: 0.9)
        #expect(g.all == [.init(axis: .vertical, fraction: 0.1), .init(axis: .horizontal, fraction: 0.9)])
    }
}
