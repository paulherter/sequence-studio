import Foundation

/// Row spans of polygon sets, kept by `Canvas.fill(polygons:at:key:cache:)` (a panel owns one per static artwork).
/// shortcut: cleared whole once it holds `limit` sets (no LRU); upgrade when many differently sized wheels alternate.
public final class PolygonSpanCache {
    struct Key: Hashable { var key: AnyHashable; var fx, fy, scale: Float }
    private var sets: [Key: [(DrawRect, DrawColor)]] = [:]
    public let limit: Int
    public init(limit: Int = 32) { self.limit = limit }
    /// The span sets held.
    public var count: Int { sets.count }

    func spans(for k: Key, build: () -> [(DrawRect, DrawColor)]) -> [(DrawRect, DrawColor)] {
        if let s = sets[k] { return s }
        if sets.count >= limit { sets.removeAll(keepingCapacity: true) }
        let s = build()
        sets[k] = s
        return s
    }
}
