import CoreGraphics
import Testing
@testable import SQUIKit

@Suite struct SQLoupeLogicTests {
    @Test func captureRectPutsPointerPixelAtPickedCell() {
        // 2x display: pointer at (100.4, 50.9) points = device pixel (200, 101).
        let r = SQLoupeLogic.captureRect(pointer: CGPoint(x: 100.4, y: 50.9), scale: 2)
        #expect(r.width == 6 && r.height == 6)              // 12 device pixels
        #expect(r.minX == (200 - 5) / 2 && r.minY == (101 - 5) / 2)
        let r1 = SQLoupeLogic.captureRect(pointer: CGPoint(x: 10.7, y: 20.2), scale: 1)
        #expect(r1 == CGRect(x: 5, y: 15, width: 12, height: 12))
    }

    @Test func cocoaToDisplayFlipsY() {
        #expect(SQLoupeLogic.displayPoint(fromCocoa: CGPoint(x: 10, y: 100), primaryHeight: 900) == CGPoint(x: 10, y: 800))
    }

    @Test func colorsFromBufferAndPick() throws {
        let n = SQLoupeLogic.cells
        var buf = [UInt8](repeating: 0, count: n * n * 4)
        let i = SQLoupeLogic.pickedCell * n + SQLoupeLogic.pickedCell
        buf[i * 4] = 0xB8; buf[i * 4 + 1] = 0x50; buf[i * 4 + 2] = 0x3E; buf[i * 4 + 3] = 255
        let cols = try #require(SQLoupeLogic.colors(rgba: buf))
        #expect(cols.count == n * n)
        let picked = try #require(SQLoupeLogic.picked(from: cols))
        #expect(SQLoupeLogic.readout(picked) == "#B8503E")
        #expect(SQLoupeLogic.colors(rgba: [0, 0, 0]) == nil)
    }

    @Test func windowStaysOnScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let size = CGSize(width: 112, height: 140)
        let o = SQLoupeLogic.windowOrigin(pointer: CGPoint(x: 2, y: 2), windowSize: size, circleTopInset: 14, screen: screen)
        #expect(o.x == 0 && o.y == 0)
        let mid = SQLoupeLogic.windowOrigin(pointer: CGPoint(x: 500, y: 400), windowSize: size, circleTopInset: 14, screen: screen)
        #expect(abs(mid.x - 444) < 0.001)
        #expect(abs((mid.y + size.height - 14 - SQLoupeLogic.diameter / 2) - 400) < 0.001)   // circle center on the pointer
    }
}
