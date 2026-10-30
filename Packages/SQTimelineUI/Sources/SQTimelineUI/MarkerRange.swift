#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import SQCore

/// Range markers in the ruler (pure): the duration bar and its draggable end.
public enum MarkerRange {
    public static let handleReach: CGFloat = 5
    public static let barHeight: CGFloat = 4

    /// Vertical band of the ruler where a marker dot or bar end can be grabbed: the 7 pt dot (4 pt above the bottom
    /// edge) plus 3 pt slack. Above it the ruler belongs to the playhead handle, even when a marker sits under the playhead.
    public static func grabBand(rulerHeight: CGFloat) -> ClosedRange<CGFloat> { (rulerHeight - 11 - 3)...rulerHeight }

    /// Bar from the marker's start to its end, 4 pt tall at the ruler's bottom edge. Nil for point markers.
    public static func barRect(_ m: Marker, geometry: TimelineGeometry, rulerHeight: CGFloat) -> CGRect? {
        guard m.duration > .zero else { return nil }
        let x0 = geometry.x(for: m.time).rounded(), x1 = geometry.x(for: m.time + m.duration).rounded()
        return CGRect(x: x0, y: rulerHeight - barHeight, width: max(x1 - x0, 1), height: barHeight)
    }

    /// The range marker whose bar end is within `handleReach` of `x` (nearest wins). Point markers have no handle.
    public static func endHandle(atX x: CGFloat, markers: [Marker], geometry: TimelineGeometry) -> Marker.ID? {
        markers.filter { $0.duration > .zero }
            .map { ($0.id, abs(geometry.x(for: $0.time + $0.duration) - x)) }
            .filter { $0.1 <= handleReach }.min { $0.1 < $1.1 }?.0
    }

    /// New duration for an end dragged to `time`: at least 0, snapped to other markers, clip edges, the playhead
    /// (and beat markers per `beatLevel`) when snapping is on, else the frame grid.
    public static func duration(forEndTime time: Time, start: Time, timeline: Timeline, markerID: Marker.ID,
                                snapping: Bool, geometry: TimelineGeometry, playhead: Time?,
                                beatLevel: BeatSnapLevel = .everyBeat) -> Time {
        var end = max(time, start)
        if snapping {
            var rest = timeline
            rest.markers.removeAll { $0.id == markerID }
            let points = rest.snapPoints(excluding: [], playhead: playhead,
                                         markers: rest.markerSnapTimes(beatLevel: beatLevel))
            end = snap(end, to: points, threshold: geometry.snapThreshold(), frameDuration: timeline.frameDuration).time
        } else {
            end = end.snapped(to: timeline.frameDuration)
        }
        return max(end - start, .zero)
    }
}
