import Foundation
import SQCore
import SQDrawKit
import SQEditorSession
import SQTimelineUI
import Testing
@testable import SQDrawTimeline

/// The header column's "Mix 0.0 dB" row (AppKit `TimelineView.drawMixHeader`): right under the last track row.
@MainActor @Suite struct TimelineMixRowTests {
    private func panel(height: Float) -> TimelinePanel {
        let fd = Time(1, 25)
        let t = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video), Track(kind: .audio)])
        var p = TimelinePanel()
        p.layout(DrawRect(x: 0, y: 0, w: 1000, h: height), scale: 1)
        p.sync(timeline: t, selection: [], playhead: .zero, selectedTransition: nil, labels: LabelResolver())
        return p
    }

    @Test func mixRowSitsUnderTheLastTrackInTheHeaderColumn() throws {
        let p = panel(height: 600)
        let r = try #require(p.mixRowRect())
        let last = try #require(p.rows.last)
        #expect(r.minY == last.bottom)
        #expect(r.height == TimelinePanel.mixRowHeight)
        #expect(r.minX == TimelineGeometry.toolColumnWidth)
        #expect(r.width == TimelineGeometry.headerWidth)
    }

    @Test func mixRowHidesWhenItWouldReachTheZoomBar() {
        let p = panel(height: 120)
        #expect(p.mixRowRect() == nil)
    }

    @Test func mixRowDrawsTextOnlyWhileItFits() throws {
        let atlas = try #require(GlyphAtlas())
        func quads(_ p: TimelinePanel) -> Int {
            var cv = Canvas(width: 1000, height: 600, atlas: atlas, scale: 1)
            p.drawMixRow(&cv)
            return cv.list.quads.count
        }
        #expect(quads(panel(height: 600)) > 4)      // fills plus the glyphs of "Mix" and "0.0 dB"
        #expect(quads(panel(height: 120)) == 0)
    }
}
