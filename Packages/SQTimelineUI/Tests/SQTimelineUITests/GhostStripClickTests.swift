import AppKit
import Foundation
import SQCore
import Testing
@testable import SQTimelineUI

@MainActor @Suite struct GhostStripClickTests {
    private func makeView(height: CGFloat = 400) -> TimelineView {
        let tl = Timeline(name: "t", frameDuration: Time(1, 24), tracks: [Track(kind: .video), Track(kind: .audio)])
        return TimelineView(timeline: tl, frame: NSRect(x: 0, y: 0, width: 1000, height: height))
    }

    /// Board: no idle ghost strips under the last track (the drop ghost shows only during a drag).
    @Test func noIdleGhostStrips() {
        for h in [90, 400, 900] as [CGFloat] {
            let v = makeView(height: h)
            #expect(v.visibleIdleGhostRows().isEmpty)
            #expect(v.idleGhostKind(at: CGPoint(x: TimelineGeometry.toolColumnWidth + 40, y: 250)) == nil)
        }
    }
}
