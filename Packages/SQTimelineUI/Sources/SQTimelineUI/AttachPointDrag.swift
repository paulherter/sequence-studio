#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import SQCore

/// Fast Cut: dragging the attach thread of an attached clip along its host clip. Pure geometry and snapping; the view
/// previews the drag on a copy of the timeline and commits once on mouse up (one undo step, no clip moves).
public enum AttachPointDrag {
    /// Pointer distance (points) within which the attach time snaps to a cut or the playhead.
    static let snapReach: CGFloat = 8
    /// Half width of the thread's grab zone.
    static let grabReach: CGFloat = 4

    /// The attached clip whose thread (the line outside the clip plus the triangle on the host edge) lies under `p`, else nil.
    public static func hit(at p: CGPoint, in timeline: Timeline, geometry: TimelineGeometry) -> Clip.ID? {
        guard timeline.isFastCut, let mi = timeline.mainTrackIndex else { return nil }
        let rows = geometry.rows(for: timeline)
        guard let main = rows.first(where: { $0.track == timeline.tracks[mi].id }) else { return nil }
        for row in rows where row.track != main.track {
            guard let track = timeline.track(row.track), !track.isLocked else { continue }
            for c in track.clips {
                guard let a = c.attachment, timeline.isAttachable(c.id) else { continue }
                let x = geometry.x(for: c.start + a.point)
                guard abs(p.x - x) <= grabReach else { continue }
                let rect = CGRect(x: geometry.x(for: c.start), y: row.y, width: geometry.width(of: c.timeline.duration), height: row.height)
                if Self.attachGrabSpan(clipRect: rect, hostMinY: main.y, hostMaxY: main.maxY).contains(p.y) { return c.id }
            }
        }
        return nil
    }

    /// Attach time for a pointer at `x`: kept on the host clip, snapped to a cut of the main track or the playhead
    /// within `snapReach` (when `snapping`), else to the frame grid.
    public static func target(x: CGFloat, clip id: Clip.ID, in timeline: Timeline, geometry: TimelineGeometry,
                       playhead: Time, snapping: Bool) -> Time? {
        guard let mi = timeline.mainTrackIndex, let a = timeline.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id })?.attachment,
              let host = timeline.tracks[mi].clips.first(where: { $0.id == a.host }) else { return nil }
        let fd = timeline.frameDuration
        var t = geometry.unsnappedTime(atX: x).snapped(to: fd)
        if snapping {
            var cuts = [playhead]
            for c in timeline.tracks[mi].clips { cuts.append(c.start); cuts.append(c.timeline.end) }
            let best = cuts.map { ($0, abs(geometry.x(for: $0) - x)) }.min { $0.1 < $1.1 }
            if let best, best.1 <= snapReach { t = best.0 }
        }
        let hi = max(host.timeline.end - fd, host.start)
        return min(max(t, host.start), hi)
    }

    /// Vertical span (view y) where a pointer grabs the attach marker: the thread plus the triangle on the host edge.
    public static func attachGrabSpan(clipRect: CGRect, hostMinY: CGFloat, hostMaxY: CGFloat) -> ClosedRange<CGFloat> {
        let above = clipRect.midY < (hostMinY + hostMaxY) / 2
        let from = above ? clipRect.maxY : clipRect.minY
        let edge = above ? hostMinY : hostMaxY
        let depth: CGFloat = 6
        return above ? (min(from, edge) - 1)...(edge + depth) : (edge - depth)...(max(from, edge) + 1)
    }
}
