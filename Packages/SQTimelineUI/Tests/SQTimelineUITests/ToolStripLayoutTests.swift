import Foundation
import Testing
@testable import SQTimelineUI

struct ToolStripLayoutTests {
    /// Positive-area overlap: `CGRect.intersects` counts touching edges as an overlap off the Mac.
    static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let i = a.intersection(b)
        return !i.isNull && i.width > 0 && i.height > 0
    }

    private let bounds = CGRect(x: 0, y: 0, width: 800, height: 300)

    @Test func dragNearAnEdgeDocksThere() {
        #expect(ToolStripLayout.edge(for: CGPoint(x: 10, y: 150), in: bounds) == .left)
        #expect(ToolStripLayout.edge(for: CGPoint(x: 790, y: 150), in: bounds) == .right)
        #expect(ToolStripLayout.edge(for: CGPoint(x: 400, y: 5), in: bounds) == .top)
        #expect(ToolStripLayout.edge(for: CGPoint(x: 400, y: 47), in: bounds) == .top && ToolStripLayout.edge(for: CGPoint(x: 63, y: 150), in: bounds) == .left)
        #expect(ToolStripLayout.edge(for: CGPoint(x: 400, y: 295), in: bounds) == .bottom)
        #expect(ToolStripLayout.edge(for: CGPoint(x: 400, y: 150), in: bounds) == .floating)
    }

    @Test func dockedStripTakesItsThicknessFromTheContent() {
        for edge in [ToolStripEdge.left, .right, .top, .bottom] {
            let f = ToolStripLayout.frames(edge: edge, bounds: bounds, toolCount: 5, floatOrigin: .zero)
            #expect(!Self.overlaps(f.strip, f.content))
            #expect(f.strip.union(f.content) == bounds)
        }
        let left = ToolStripLayout.frames(edge: .left, bounds: bounds, toolCount: 5, floatOrigin: .zero)
        #expect(left.strip.width == 38 && left.content.minX == 38)
    }

    @Test func floatingStripKeepsContentWholeAndStaysInside() {
        let f = ToolStripLayout.frames(edge: .floating, bounds: bounds, toolCount: 5, floatOrigin: CGPoint(x: 5000, y: -20))
        #expect(f.content == bounds && bounds.contains(f.strip))
    }

    @Test func barIsAColumnBesideTheLanesAndARowElsewhere() {
        #expect(ToolStripLayout.thickness(.left) == 38 && ToolStripLayout.thickness(.right) == 38)
        #expect(ToolStripLayout.thickness(.top) == 36 && ToolStripLayout.thickness(.floating) == 36)
        #expect(ToolStripEdge.floating.isVertical == false)
        #expect(ToolStripLayout.zone(.left, in: bounds)?.width == 64 && ToolStripLayout.zone(.top, in: bounds)?.height == 48)
        #expect(ToolStripLayout.zone(.floating, in: bounds) == nil)
    }

    @Test func hiddenStripGivesTheContentEverything() {
        let f = ToolStripLayout.frames(edge: .left, bounds: bounds, toolCount: 5, floatOrigin: .zero, visible: false)
        #expect(f.content == bounds && f.strip == .zero)
    }

    @Test func toolsFitInsideTheStrip() {
        for edge in [ToolStripEdge.left, .top, .floating] {
            let n = 6, t = ToolStripLayout.thickness(edge), len = ToolStripLayout.length(toolCount: n, edge: edge)
            let size = edge.isVertical ? CGSize(width: t, height: len) : CGSize(width: len, height: t)
            let s = ToolStripLayout.slots(edge: edge, toolCount: n, size: size)
            let rect = CGRect(origin: .zero, size: size)
            #expect(s.tools.allSatisfy { rect.contains($0) && $0.width == 28 && $0.height == 28 })
            #expect(rect.contains(s.grip))
            #expect(s.tools.allSatisfy { !Self.overlaps($0, s.grip) })
        }
    }
}
