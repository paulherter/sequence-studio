import Foundation
import SQCore

/// Fast Cut geometry the timeline draws (attach hosts, spacers, attach threads), portable for the shared toolkit
/// timeline; `ClipDrawing` forwards to it.
public enum FastCutMarks {
    /// Fast Cut: the main-track clips the selected attached clips are attached to (their host highlight). Empty outside
    /// Fast Cut.
    public static func attachHosts(of selection: Set<Clip.ID>, in t: Timeline) -> Set<Clip.ID> {
        guard t.isFastCut, !selection.isEmpty else { return [] }
        return Set(t.tracks.lazy.flatMap(\.clips).filter { selection.contains($0.id) }.compactMap { $0.attachment?.host })
    }
    /// Fast Cut spacers: the holes of the main track before its last clip (time ranges), empty outside Fast Cut.
    public static func spacers(in t: Timeline) -> [TimeRange] {
        guard t.isFastCut, let mi = t.mainTrackIndex else { return [] }
        return spacers(on: t.tracks[mi])
    }
    /// The holes of one (main) track as drawn, e.g. the live preview of a drag.
    public static func spacers(on track: Track) -> [TimeRange] {
        var out: [TimeRange] = []
        var end = Time.zero
        for c in track.clips {
            if c.start > end { out.append(TimeRange(start: end, end: c.start)) }
            end = max(end, c.timeline.end)
        }
        return out
    }
    /// Where the attach thread of an attached clip runs (Fast Cut): a vertical line at the attach point `x` from the
    /// attached clip's near edge to the host's row on the main track (`hostMinY`...`hostMaxY`), ending in a small
    /// triangle on the host edge that points into the host. nil when the clip touches the host row.
    public static func attachThreadGeometry(clipRect: CGRect, x: CGFloat, hostMinY: CGFloat, hostMaxY: CGFloat)
        -> (from: CGPoint, to: CGPoint, triangle: [CGPoint])? {
        let above = clipRect.midY < (hostMinY + hostMaxY) / 2          // attached clip above the host: the thread runs down
        let from = above ? clipRect.maxY : clipRect.minY
        let to = above ? hostMinY : hostMaxY
        guard abs(to - from) >= 1 else { return nil }
        let s: CGFloat = 3
        let tip = above ? to + s + 1 : to - s - 1
        return (CGPoint(x: x, y: from), CGPoint(x: x, y: to),
                [CGPoint(x: x, y: tip), CGPoint(x: x - s, y: to), CGPoint(x: x + s, y: to)])
    }
    /// The marker alone (no thread) for a clip whose row touches the host row: a triangle on the shared edge pointing
    /// into the host. nil when the clip is not next to the host.
    public static func attachMarker(clipRect: CGRect, x: CGFloat, hostMinY: CGFloat, hostMaxY: CGFloat)
        -> (from: CGPoint, to: CGPoint, triangle: [CGPoint])? {
        let above = clipRect.midY < (hostMinY + hostMaxY) / 2
        let edge = above ? hostMinY : hostMaxY
        guard abs((above ? clipRect.maxY : clipRect.minY) - edge) < 1 else { return nil }
        let s: CGFloat = 3
        let tip = above ? edge + s + 1 : edge - s - 1
        return (CGPoint(x: x, y: edge), CGPoint(x: x, y: edge),
                [CGPoint(x: x, y: tip), CGPoint(x: x - s, y: edge), CGPoint(x: x + s, y: edge)])
    }
}
