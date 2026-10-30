#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import SQCore

/// Dragging a marker flag in the ruler (pure): the new time is clamped at 0, snaps to clip edges, the playhead and the
/// In/Out marks when snapping is on (other markers count too, the dragged one does not), else lands on the frame grid.
public enum MarkerDrag {
    public static func target(time: Time, dragging id: Marker.ID, in timeline: Timeline, playhead: Time?,
                              snapping: Bool, geometry: TimelineGeometry,
                              beatLevel: BeatSnapLevel = .everyBeat) -> (time: Time, hit: SnapPoint?) {
        let t = max(time, .zero)
        guard snapping else { return (max(t.snapped(to: timeline.frameDuration), .zero), nil) }
        var rest = timeline
        rest.markers.removeAll { $0.id == id }
        let others = rest.markerSnapTimes(beatLevel: beatLevel)
        let points = timeline.snapPoints(excluding: [], playhead: playhead, markers: others)
        let r = snap(t, to: points, threshold: geometry.snapThreshold(), frameDuration: timeline.frameDuration)
        return (max(r.time, .zero), r.hit)
    }
}
