import Foundation

public enum SnapKind: Sendable, Hashable { case clipEdge, playhead, marker, frame }

public struct SnapPoint: Sendable, Hashable {
    public var time: Time
    public var kind: SnapKind
    public init(time: Time, kind: SnapKind) { self.time = time; self.kind = kind }

    /// Sorted by time, one point per time; non-frame kinds win over `.frame`, otherwise the first one stays.
    static func normalized(_ points: [SnapPoint]) -> [SnapPoint] {
        var out: [SnapPoint] = []
        for p in points.sorted(by: { $0.time < $1.time }) {
            if let last = out.last, last.time == p.time {
                if last.kind == .frame && p.kind != .frame { out[out.count - 1] = p }
            } else {
                out.append(p)
            }
        }
        return out
    }
}

extension Timeline {
    /// Snap targets: start and end of every clip not in `excluding`, the playhead, markers and 0.
    /// Sorted and deduplicated by time.
    public func snapPoints(excluding: Set<Clip.ID> = [], playhead: Time? = nil, markers: [Time] = []) -> [SnapPoint] {
        var pts = [SnapPoint(time: .zero, kind: .clipEdge)]
        if let playhead { pts.append(SnapPoint(time: playhead, kind: .playhead)) }
        pts += markers.map { SnapPoint(time: $0, kind: .marker) }
        for track in tracks {
            for c in track.clips where !excluding.contains(c.id) {
                pts.append(SnapPoint(time: c.timeline.start, kind: .clipEdge))
                pts.append(SnapPoint(time: c.timeline.end, kind: .clipEdge))
            }
        }
        return SnapPoint.normalized(pts)
    }
}

private func distance(_ a: Time, _ b: Time) -> Time {
    let d = a - b
    return d.isNegative ? -d : d
}

/// Nearest point to `t` within `threshold` (ties: earlier). `points` must be sorted by time.
private func nearest(_ t: Time, in points: [SnapPoint], threshold: Time) -> SnapPoint? {
    var lo = 0, hi = points.count          // first index with time >= t
    while lo < hi {
        let mid = (lo + hi) / 2
        if points[mid].time < t { lo = mid + 1 } else { hi = mid }
    }
    var best: SnapPoint?
    if lo > 0 { best = points[lo - 1] }
    if lo < points.count {
        let next = points[lo]
        if let b = best {
            if distance(next.time, t) < distance(b.time, t) { best = next }
        } else {
            best = next
        }
    }
    guard let b = best, distance(b.time, t) <= threshold else { return nil }
    return b
}

/// Snaps `t` to the nearest point within `threshold`; otherwise to the frame grid when `frameDuration` is set.
public func snap(_ t: Time, to points: [SnapPoint], threshold: Time,
                 frameDuration: Time?) -> (time: Time, hit: SnapPoint?) {
    if let p = nearest(t, in: points, threshold: threshold) { return (p.time, p) }
    if let fd = frameDuration { return (t.snapped(to: fd), nil) }
    return (t, nil)
}

/// Snapping for dragging a clip: tries its start and its end. Returns the adjustment to add to the clip's
/// position; the closer hit wins (tie: start). Without a hit, falls back to the frame grid for the start.
public func snapMove(start: Time, duration: Time, to points: [SnapPoint], threshold: Time,
                     frameDuration: Time?) -> (delta: Time, hit: SnapPoint?) {
    let end = start + duration
    let s = nearest(start, in: points, threshold: threshold)
    let e = nearest(end, in: points, threshold: threshold)
    switch (s, e) {
    case let (s?, e?):
        return distance(e.time, end) < distance(s.time, start) ? (e.time - end, e) : (s.time - start, s)
    case let (s?, nil): return (s.time - start, s)
    case let (nil, e?): return (e.time - end, e)
    case (nil, nil):
        if let fd = frameDuration { return (start.snapped(to: fd) - start, nil) }
        return (.zero, nil)
    }
}
