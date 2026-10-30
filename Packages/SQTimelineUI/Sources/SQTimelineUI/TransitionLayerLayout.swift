#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import SQCore

/// Where a transition dropped on an empty track spot becomes a transition layer (DECISIONS 2026-10-05).
public struct TransitionLayerDropTarget: Sendable, Equatable {
    public var track: Track.ID
    public var start: Time
    public var duration: Time
    /// The cut (center marker) on the timeline.
    public var cut: Time
    /// Highlight box in view coordinates.
    public var rect: CGRect
}

/// The part of a transition layer clip under the pointer that has its own drag.
public enum TransitionLayerZone: Sendable, Equatable {
    /// The center marker: moves the cut (the split between lead-in and lead-out).
    case cut
    /// An end: resizes symmetrically around the cut (Option = this end only).
    case head, tail
}

/// Transition layer geometry on the timeline: drop target, center marker and hit zones. Pure: no AppKit.
public enum TransitionLayerLayout {
    /// Pointer distance (points) within which the cut snaps to an edit below or the playhead.
    static let snapReach: CGFloat = 8
    /// Half width of the center marker's grab zone.
    static let markerReach: CGFloat = 5
    /// Width of an end's grab zone (at most a quarter of the box).
    static func edgeWidth(forWidth w: CGFloat) -> CGFloat { min(8, w / 4) }

    /// Edit points the cut snaps to: clip starts and ends on the video tracks below `track`, and the playhead.
    public static func snapTimes(below track: Track.ID, in timeline: Timeline, playhead: Time) -> [Time] {
        guard let k = timeline.tracks.firstIndex(where: { $0.id == track }) else { return [playhead] }
        var out = [playhead]
        for tr in timeline.tracks[..<k] where tr.kind == .video {
            for c in tr.clips where !c.isTransitionLayer { out.append(c.start); out.append(c.timeline.end) }
        }
        return out
    }

    /// `t` moved onto the nearest snap time within `snapReach`, else onto the frame grid.
    public static func snapped(_ t: Time, to times: [Time], geometry: TimelineGeometry) -> Time {
        let x = geometry.x(for: t)
        let best = times.map { ($0, abs(geometry.x(for: $0) - x)) }.min { $0.1 < $1.1 }
        if let best, best.1 <= snapReach { return best.0 }
        return t.snapped(to: geometry.frameDuration)
    }

    /// A layer kind dropped at `p` on an unlocked video track where no clip is: `duration` (whole frames) centered on the
    /// pointer, whose time snaps to an edit below or the playhead, fitted into the gap (shortened when the gap is smaller).
    /// nil on a clip, another track kind or a kind that cannot be a layer.
    public static func dropTarget(at p: CGPoint, kind: TransitionKind, in timeline: Timeline, geometry: TimelineGeometry,
                                  playhead: Time, duration: Time) -> TransitionLayerDropTarget? {
        guard kind.isLayerKind, p.x >= TimelineGeometry.contentOriginX,
              let row = geometry.rows(for: timeline).first(where: { p.y >= $0.y && p.y < $0.maxY }),
              row.kind == .video, let track = timeline.track(row.track), !track.isLocked else { return nil }
        let fd = timeline.format.frameDuration
        let at = max(.zero, geometry.unsnappedTime(atX: p.x))
        guard !track.clips.contains(where: { $0.timeline.contains(at) }) else { return nil }
        let gapStart = track.clips.filter { $0.timeline.end <= at }.map(\.timeline.end).max() ?? .zero
        let gapEnd = track.clips.filter { $0.start > at }.map(\.start).min()
        var cut = snapped(at, to: snapTimes(below: track.id, in: timeline, playhead: playhead), geometry: geometry)
        cut = max(cut, gapStart)
        if let gapEnd { cut = min(cut, gapEnd) }
        var d = max(duration.snapped(to: fd), fd)
        if let gapEnd { d = min(d, gapEnd - gapStart) }
        guard d >= fd else { return nil }
        var start = cut - fd * (d.frameIndex(frameDuration: fd) / 2)
        if let gapEnd { start = min(start, gapEnd - d) }
        start = max(start, gapStart)
        return TransitionLayerDropTarget(track: track.id, start: start, duration: d, cut: cut,
                                         rect: CGRect(x: geometry.x(for: start), y: row.y + 1, width: geometry.width(of: d),
                                                      height: max(row.height - 2, 1)))
    }

    /// The transition layer clip and zone under `p` (center marker first, then the ends), or nil.
    public static func hitTest(_ p: CGPoint, in timeline: Timeline, geometry: TimelineGeometry) -> (id: Clip.ID, track: Track.ID, zone: TransitionLayerZone)? {
        guard let row = geometry.rows(for: timeline).first(where: { p.y >= $0.y && p.y < $0.maxY }), row.kind == .video,
              let track = timeline.track(row.track), !track.isLocked else { return nil }
        let fd = timeline.format.frameDuration
        for c in track.clips where c.isTransitionLayer {
            guard let r = c.resolvedTransitionLayer(frameDuration: fd) else { continue }
            let x0 = geometry.x(for: r.span.start), x1 = geometry.x(for: r.span.end)
            guard p.x >= x0, p.x <= x1 else { continue }
            if abs(p.x - geometry.x(for: r.cut)) <= markerReach { return (c.id, track.id, .cut) }
            let e = edgeWidth(forWidth: x1 - x0)
            if p.x <= x0 + e { return (c.id, track.id, .head) }
            if p.x >= x1 - e { return (c.id, track.id, .tail) }
        }
        return nil
    }
}
