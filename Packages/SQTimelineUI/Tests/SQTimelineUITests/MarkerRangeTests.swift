#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
import SQCore
@testable import SQTimelineUI

@Suite("Marker range and beat snap")
struct MarkerRangeTests {
    private func rig() -> (Timeline, Marker.ID, TimelineGeometry) {
        var t = Timeline(name: "T", frameDuration: Time(1, 30), tracks: [])
        t.replaceBeatMarkers(in: TimeRange(start: .zero, duration: Time(20, 1)), with: (1..<9).map { Time(Int64($0), 1) })
        let id = t.addMarker(at: Time(10, 1), name: "Range")
        _ = t.setMarkerDuration(id, to: Time(2, 1))
        let g = TimelineGeometry(frameDuration: t.frameDuration, pointsPerSecond: 100)
        return (t, id, g)
    }

    @Test func barSpansDuration() {
        let (t, id, g) = rig()
        let m = t.markers.first { $0.id == id }!
        let r = MarkerRange.barRect(m, geometry: g, rulerHeight: 28)!
        #expect(r.minX == g.x(for: m.time).rounded())
        #expect(r.width > 1)
        var point = m; point.duration = .zero
        #expect(MarkerRange.barRect(point, geometry: g, rulerHeight: 28) == nil)
    }

    @Test func endHandleHitsOnlyNearEnd() {
        let (t, id, g) = rig()
        let endX = g.x(for: Time(12, 1))
        #expect(MarkerRange.endHandle(atX: endX + 2, markers: t.markers, geometry: g) == id)
        #expect(MarkerRange.endHandle(atX: endX + 40, markers: t.markers, geometry: g) == nil)
    }

    @Test func endSnapsToBarDownbeatOnly() {
        let (t, id, g) = rig()
        let near = Time(4, 1) + Time(1, 100)
        // Beats at 1...8; bar downbeats are 1 and 5. Dragging to 5.01 s (start 0 stand-in) lands on 5 in bars mode.
        let bars = MarkerRange.duration(forEndTime: Time(5, 1) + Time(1, 100), start: .zero, timeline: t, markerID: id,
                                        snapping: true, geometry: g, playhead: nil, beatLevel: .barsOnly)
        #expect(bars == Time(5, 1))
        let beat = MarkerRange.duration(forEndTime: Time(6, 1) + Time(1, 100), start: .zero, timeline: t, markerID: id,
                                        snapping: true, geometry: g, playhead: nil, beatLevel: .everyBeat)
        #expect(beat == Time(6, 1))
        let skipped = MarkerRange.duration(forEndTime: Time(6, 1) + Time(1, 25), start: .zero, timeline: t, markerID: id,
                                           snapping: true, geometry: g, playhead: nil, beatLevel: .barsOnly)
        #expect(skipped != Time(6, 1))
        _ = near
    }

    @Test func playheadSnapHonorsLevel() {
        let (t, _, g) = rig()
        let every = PlayheadSnap.resolve(Time(3, 1) + Time(1, 60), timeline: t, geometry: g, beatLevel: .everyBeat)
        #expect(every.time == Time(3, 1))
        let bars = PlayheadSnap.resolve(Time(3, 1) + Time(1, 60), timeline: t, geometry: g, beatLevel: .barsOnly)
        #expect(bars.hit == nil)
    }
}
