#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import SQCore

/// The hover line of the razor tool (C): where a click would cut. One track row under the pointer, or every row with
/// Shift (Premiere: razor all tracks). Pure; the view draws the rectangle over the content.
public enum RazorGuide {
    /// `x` is the cut position in view coordinates. nil when the pointer is not over a track row.
    public static func rect(x: CGFloat, pointerY: CGFloat, allTracks: Bool, rows: [TrackRow]) -> CGRect? {
        guard let first = rows.first, let last = rows.last else { return nil }
        if allTracks {
            guard pointerY >= first.y, pointerY < last.maxY else { return nil }
            return CGRect(x: x.rounded() - 0.5, y: first.y, width: 1, height: last.maxY - first.y)
        }
        guard let row = rows.first(where: { pointerY >= $0.y && pointerY < $0.maxY }) else { return nil }
        return CGRect(x: x.rounded() - 0.5, y: row.y, width: 1, height: row.height)
    }

    /// Guide segments for an explicit set of tracks (the ones the click would cut: the clip under the pointer plus its
    /// linked partners, or every track with Shift). Adjacent rows merge into one segment.
    public static func rects(x: CGFloat, tracks: Set<Track.ID>, rows: [TrackRow]) -> [CGRect] {
        var out: [CGRect] = []
        for row in rows where tracks.contains(row.track) {
            if let last = out.last, abs(last.maxY - row.y) < 0.5 {
                out[out.count - 1].size.height = row.maxY - last.minY
            } else {
                out.append(CGRect(x: x.rounded() - 0.5, y: row.y, width: 1, height: row.height))
            }
        }
        return out
    }
}
