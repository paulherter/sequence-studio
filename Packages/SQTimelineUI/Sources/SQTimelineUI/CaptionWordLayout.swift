#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import SQCore

/// One word of a caption on the caption track (index into `CaptionItem.tokens`).
public struct CaptionWordRef: Hashable, Sendable {
    public var caption: CaptionItem.ID
    public var index: Int
    public init(caption: CaptionItem.ID, index: Int) { self.caption = caption; self.index = index }
}

/// What a point on the caption track hits at word level: the word and whether it is one of its edges (retime) or its body.
public struct CaptionWordHit: Hashable, Sendable {
    public var ref: CaptionWordRef
    public var zone: ClipZone
    public init(ref: CaptionWordRef, zone: ClipZone) { self.ref = ref; self.zone = zone }
}

/// Level of detail and geometry of the words on the caption track. Pure: the same zoom and caption always give the
/// same answer, so nothing flickers while scrolling or playing (only a zoom step can switch a caption between its two
/// pictures, and each caption switches exactly once on the way).
public enum CaptionWordLayout {
    /// Zoom from which a caption track shows words at all (points per second). Below it every caption is one block.
    public static let wordLevelPointsPerSecond: Double = 60
    /// A caption shows its words only when they are this wide on average; a fast speaker stays a block a little longer.
    public static let minAverageWordWidth: CGFloat = 18
    /// Width of the grab zone at a word edge, and the narrowest word that still has edges to grab.
    public static let edgeGrab: CGFloat = 4
    public static let minWidthForEdges: CGFloat = 14
    /// Space between a word box and the caption's body, top and bottom.
    public static let boxInsetY: CGFloat = 3
    /// Space between two touching word boxes (half on each side).
    public static let boxGap: CGFloat = 1
    /// A caption narrower than this is drawn as a plain sliver (no outline, no text).
    public static let sliverWidth: CGFloat = 3

    /// True when `item` is drawn as word boxes at this zoom.
    public static func showsWords(_ item: CaptionItem, geometry: TimelineGeometry) -> Bool {
        guard geometry.pointsPerSecond >= wordLevelPointsPerSecond else { return false }
        let n = wordCount(item)
        guard n > 0 else { return false }
        let width = geometry.x(for: item.range.end) - geometry.x(for: item.range.start)
        return width / CGFloat(n) >= minAverageWordWidth
    }

    /// Zoom (points per second) at which `item` shows its words.
    public static func zoomForWords(_ item: CaptionItem) -> Double {
        let n = wordCount(item), d = item.range.duration
        guard n > 0, d > .zero else { return wordLevelPointsPerSecond }
        let seconds = Double(d.value) / Double(d.timescale)
        return max(wordLevelPointsPerSecond, Double(minAverageWordWidth + 2) * Double(n) / seconds)
    }

    /// Number of words without building them (the stored timings match the text in the common case).
    private static func wordCount(_ item: CaptionItem) -> Int {
        item.hasWordTimings ? item.words.count : item.tokens.count
    }

    /// The box of the word with the absolute range `range` in `row`.
    public static func box(_ range: TimeRange, geometry: TimelineGeometry, row: CaptionRow) -> CGRect {
        let x0 = geometry.x(for: range.start), x1 = geometry.x(for: range.end)
        return CGRect(x: x0 + boxGap / 2, y: row.y + 1 + boxInsetY, width: max(x1 - x0 - boxGap, 1), height: row.height - 2 - 2 * boxInsetY)
    }

    /// Word boxes of `item` in `row`, in word order.
    public static func boxes(_ item: CaptionItem, geometry: TimelineGeometry, row: CaptionRow) -> [CGRect] {
        item.effectiveWords.map { box($0.range, geometry: geometry, row: row) }
    }

    /// Row and item of a caption.
    public static func locate(_ id: CaptionItem.ID, in timeline: Timeline, geometry: TimelineGeometry) -> (row: CaptionRow, item: CaptionItem)? {
        for row in geometry.captionRows(for: timeline) {
            if let item = timeline.captionTrack(row.track)?.items.first(where: { $0.id == id }) { return (row, item) }
        }
        return nil
    }

    /// The box of one word (view coordinates), nil when the word does not exist.
    public static func box(_ ref: CaptionWordRef, in timeline: Timeline, geometry: TimelineGeometry) -> CGRect? {
        guard let (row, item) = locate(ref.caption, in: timeline, geometry: geometry) else { return nil }
        let words = item.effectiveWords
        guard words.indices.contains(ref.index) else { return nil }
        return box(words[ref.index].range, geometry: geometry, row: row)
    }

    /// The word of caption `id` at `p`, nil when the caption is drawn as a block. A point in a pause between two words
    /// belongs to the nearer one (body). Word edges are grab zones only on words wide enough to keep a body.
    public static func hit(_ p: CGPoint, caption id: CaptionItem.ID, in timeline: Timeline, geometry: TimelineGeometry) -> CaptionWordHit? {
        guard let (_, item) = locate(id, in: timeline, geometry: geometry), showsWords(item, geometry: geometry) else { return nil }
        let words = item.effectiveWords
        var best: (index: Int, distance: CGFloat)?
        for (i, w) in words.enumerated() {
            let x0 = geometry.x(for: w.range.start), x1 = geometry.x(for: w.range.end)
            if p.x >= x0, p.x < x1 {
                var zone = ClipZone.body
                if x1 - x0 >= minWidthForEdges {
                    if p.x < x0 + edgeGrab { zone = .head } else if p.x >= x1 - edgeGrab { zone = .tail }
                }
                return CaptionWordHit(ref: CaptionWordRef(caption: id, index: i), zone: zone)
            }
            let d = p.x < x0 ? x0 - p.x : p.x - x1
            if best == nil || d < best!.distance { best = (i, d) }
        }
        return best.map { CaptionWordHit(ref: CaptionWordRef(caption: id, index: $0.index), zone: .body) }
    }

    /// Index of the first item that ends after `t` (items are in time order and never overlap): where drawing starts.
    public static func firstIndex(endingAfter t: Time, in items: [CaptionItem]) -> Int {
        var lo = 0, hi = items.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if items[mid].range.end > t { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }
}
