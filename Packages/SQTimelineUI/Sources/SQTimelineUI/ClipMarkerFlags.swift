#if canImport(AppKit)
import AppKit
#endif
import Foundation
import SQCore

/// Clip markers on the timeline: a small flag in the marker's color at the bottom edge of the clip. Drawn, hit-tested
/// (nearest flag within `hitRadius`), dragged along the clip and snapped to like ruler markers.
public enum ClipMarkerFlags {
    public static let flagWidth: CGFloat = 8
    public static let flagHeight: CGFloat = 7
    /// How far (points) from a flag's pole a press still grabs it.
    public static let hitRadius: CGFloat = 5
    /// Height of the strip along the clip's bottom edge where flags are grabbed.
    public static let hitStrip: CGFloat = 12

    /// Smallest clip width that shows flags.
    public static let minClipWidth: CGFloat = 16

    public struct Hit: Equatable, Sendable {
        public var clip: Clip.ID
        public var marker: Marker.ID
        /// Sequence time of the flag.
        public var time: Time
    }

    #if canImport(AppKit)
    public static func draw(clip: Clip, frameDuration: Time, geometry: TimelineGeometry, rect: CGRect, visible: CGRect) {
        guard let cg = NSGraphicsContext.current?.cgContext, rect.width >= minClipWidth else { return }
        for m in clip.visibleMarkers(frameDuration: frameDuration) {
            let x = geometry.x(for: clip.start + m.time)
            guard x >= visible.minX - flagWidth, x <= visible.maxX + flagWidth else { continue }
            cg.setFillColor(Theme.Palette.marker(m.color).cgColor)
            cg.move(to: CGPoint(x: x, y: rect.maxY))
            cg.addLine(to: CGPoint(x: x + flagWidth / 2, y: rect.maxY - flagHeight))
            cg.addLine(to: CGPoint(x: x - flagWidth / 2, y: rect.maxY - flagHeight))
            cg.closePath()
            cg.fillPath()
        }
    }
    #endif

    /// The flag under `point`, nil when the point is not in the bottom strip of a clip that has flags.
    public static func hit(at point: CGPoint, in timeline: Timeline, geometry: TimelineGeometry) -> Hit? {
        guard point.x >= TimelineGeometry.contentOriginX,
              let row = geometry.rows(for: timeline).first(where: { point.y >= $0.y && point.y < $0.maxY }),
              point.y >= row.maxY - hitStrip, let track = timeline.track(row.track) else { return nil }
        var best: (Hit, CGFloat)?
        for c in track.clips where !(c.markers ?? []).isEmpty {
            let w = geometry.x(for: c.timeline.end) - geometry.x(for: c.start)
            guard w >= minClipWidth else { continue }
            for m in c.visibleMarkers(frameDuration: timeline.frameDuration) {
                let t = c.start + m.time
                let d = abs(geometry.x(for: t) - point.x)
                if d <= hitRadius, best == nil || d < best!.1 { best = (Hit(clip: c.id, marker: m.id, time: t), d) }
            }
        }
        return best?.0
    }

    /// Where a dragged flag lands: snaps to clip edges, the playhead, In/Out and markers (ruler and other clip flags) when
    /// snapping is on, else the frame grid. The core clamps it into the clip.
    public static func target(time: Time, dragging: Hit, in timeline: Timeline, playhead: Time?, snapping: Bool,
                              geometry: TimelineGeometry) -> (time: Time, hit: SnapPoint?) {
        let t = max(time, .zero)
        guard snapping else { return (max(t.snapped(to: timeline.frameDuration), .zero), nil) }
        var others = timeline.markers.map(\.time) + timeline.clipMarkerTimes()
        if let i = others.firstIndex(of: dragging.time) { others.remove(at: i) }
        let points = timeline.snapPoints(excluding: [], playhead: playhead, markers: others)
        let r = snap(t, to: points, threshold: geometry.snapThreshold(), frameDuration: timeline.frameDuration)
        return (max(r.time, .zero), r.hit)
    }
}
