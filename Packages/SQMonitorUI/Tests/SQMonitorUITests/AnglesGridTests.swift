import Testing
import CoreGraphics
@testable import SQMonitorUI

@Suite struct AnglesGridTests {
    private let area = CGRect(x: 0, y: 0, width: 1600, height: 900)

    @Test func fourAnglesFormATwoByTwoGridInsideTheArea() {
        let cells = AnglesGridLayout.cells(count: 4, in: area, aspect: 16.0 / 9.0, gap: 8)
        #expect(cells.count == 4)
        #expect(cells[0].minY == cells[1].minY && cells[2].minY == cells[3].minY && cells[2].minY > cells[0].minY)
        for c in cells { #expect(area.contains(c)) }
        for i in 0..<4 { for j in (i + 1)..<4 { #expect(!cells[i].intersects(cells[j])) } }
    }

    @Test func singleAngleFillsTheArea() {
        let cells = AnglesGridLayout.cells(count: 1, in: area, aspect: 16.0 / 9.0, gap: 8)
        #expect(abs(cells[0].width - 1600) < 0.01 && abs(cells[0].height - 900) < 0.01)
    }

    @Test func lastRowIsCenteredAndPickFindsTheTile() {
        let cells = AnglesGridLayout.cells(count: 3, in: area, aspect: 16.0 / 9.0, gap: 8)
        #expect(cells.count == 3)
        #expect(AnglesGridLayout.index(at: CGPoint(x: cells[2].midX, y: cells[2].midY), cells: cells) == 2)
        #expect(AnglesGridLayout.index(at: CGPoint(x: -5, y: -5), cells: cells) == nil)
        #expect(AnglesGridLayout.cells(count: 0, in: area, aspect: 1.7, gap: 8).isEmpty)
    }
}
