import AppKit
import Testing
@testable import SQUIKit

@MainActor
struct ZoomScrollBarTests {
    private func bar(lo: Double, hi: Double) -> ZoomScrollBar {
        let b = ZoomScrollBar(accessibilityLabel: "t")
        b.frame = NSRect(x: 0, y: 0, width: 300, height: ZoomScrollBar.height)
        b.handles = { (lo, hi) }
        return b
    }
    private func x(_ f: Double) -> CGFloat { KeyframeZoomBarGeometry(width: 300).x(forFraction: f) }

    @Test func partsFromFractions() {
        let g = KeyframeZoomBarGeometry(width: 300)
        let h = (lo: 0.2, hi: 0.6)
        #expect(g.part(atX: x(0.2), handles: h) == .lower)
        #expect(g.part(atX: x(0.6) + 3, handles: h) == .upper)
        #expect(g.part(atX: x(0.4), handles: h) == .body)
        #expect(g.part(atX: x(0.9), handles: h) == .track)
    }

    @Test func dragEndsZoomBodyPansTrackCentres() {
        let b = bar(lo: 0.2, hi: 0.6)
        var handle: [(Bool, Double)] = [], pans: [Double] = []
        b.onHandle = { handle.append(($0, $1)) }
        b.onPan = { pans.append($0) }
        b.begin(atX: x(0.2)); b.drag(toX: x(0.3)); b.end()
        #expect(handle.count == 1 && handle[0].0 && abs(handle[0].1 - 0.3) < 1e-9)
        b.begin(atX: x(0.6)); b.drag(toX: x(0.8)); b.end()
        #expect(handle.count == 2 && !handle[1].0 && abs(handle[1].1 - 0.8) < 1e-9)
        b.begin(atX: x(0.3)); b.drag(toX: x(0.4)); b.end()       // grabbed 0.1 into the body, moved +0.1
        #expect(abs(pans[0] - 0.3) < 1e-9 && pans.count == 1)
        pans = []
        b.begin(atX: x(0.9)); b.end()                              // track click: window (0.4 wide) centered on 0.9
        #expect(abs(pans[0] - 0.7) < 1e-9)
    }

    @Test func doubleClickFitsAndInactiveIgnores() {
        let b = bar(lo: 0.2, hi: 0.6)
        var fits = 0, began = 0
        b.onFit = { fits += 1 }; b.onBegin = { began += 1 }
        b.begin(atX: x(0.4), clickCount: 2)
        #expect(fits == 1 && b.drag == nil && began == 0)
        b.isActive = { false }
        b.begin(atX: x(0.4))
        #expect(began == 0 && b.drag == nil)
    }
}
