#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import SQCore
import SQDrawKit
import SQTimelineUI
import Testing
@testable import SQDrawTimeline

@MainActor struct TimelineCullingTests {
    /// The culled range must contain every clip the exact per-clip test would draw, also with a long early clip that
    /// overlaps later ones (the prefix-max of the ends handles that).
    @Test func culledRangeNeverDropsAVisibleClip() {
        let fd = Time(1, 30)
        var clips = (0..<300).map { i in
            Clip(name: "c\(i)", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: fd * 60), start: fd * Int64(i * 60))
        }
        clips[3].source = TimeRange(start: .zero, duration: fd * 60 * 200)        // overlaps clips 4...202
        let t = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .audio, clips: clips)])
        var panel = TimelinePanel()
        panel.layout(DrawRect(x: 0, y: 0, w: 1200, h: 400), scale: 1)
        panel.sync(timeline: t, selection: [], playhead: .zero, selectedTransition: nil, labels: LabelResolver())
        let track = panel.timeline.tracks[0]
        for zoom in [2.0, 20.0, 90.0] {
            panel.setZoom(pointsPerSecond: zoom)
            for scroll in stride(from: 0.0, through: 9000.0, by: 413.0) {
                panel.geometry.scrollX = CGFloat(scroll)
                let (a, b) = (TimelineGeometry.contentOriginX, panel.size.width)
                let range = panel.visibleClipIndices(track, from: a, to: b)
                for (i, c) in track.clips.enumerated() {
                    let x0 = panel.geometry.x(for: c.timeline.start), x1 = panel.geometry.x(for: c.timeline.end)
                    if x1 >= a, x0 <= b { #expect(range.contains(i), "clip \(i) at zoom \(zoom) scroll \(scroll)") }
                }
                if zoom == 90 { #expect(range.count < 60) }
            }
        }
    }
}
