import Foundation
import SQCore

/// What a commit changes in one sequence: clips added, removed and changed (position, length, source range, track,
/// enabled), the sequence length before and after, and marker count changes. Sorted by start for stable output.
public struct EditDiff: Codable, Equatable, Sendable {
    public struct ClipRef: Codable, Equatable, Sendable {
        public var id: UUID
        public var track: UUID
        public var name: String
        public var start: Time
        public var duration: Time
        public var source: TimeRange
        public var enabled: Bool
    }

    public struct Change: Codable, Equatable, Sendable {
        public var id: UUID
        public var before: ClipRef
        public var after: ClipRef
    }

    public var added: [ClipRef]
    public var removed: [ClipRef]
    public var changed: [Change]
    public var durationBefore: Time
    public var durationAfter: Time
    public var markersAdded: Int
    public var markersRemoved: Int
    /// Media items shown with another pixel aspect after the commit; nil when none (the key is then absent).
    public var pixelAspectChanges: Int?

    public var isEmpty: Bool {
        added.isEmpty && removed.isEmpty && changed.isEmpty && durationBefore == durationAfter
            && markersAdded == 0 && markersRemoved == 0 && pixelAspectChanges == nil
    }

    public init(before: Timeline, after: Timeline) {
        let b = Self.refs(before), a = Self.refs(after)
        let order: (ClipRef, ClipRef) -> Bool = { ($0.start, $0.id.uuidString) < ($1.start, $1.id.uuidString) }
        added = a.values.filter { b[$0.id] == nil }.sorted(by: order)
        removed = b.values.filter { a[$0.id] == nil }.sorted(by: order)
        changed = b.values.compactMap { old -> Change? in
            guard let new = a[old.id], new != old else { return nil }
            return Change(id: old.id, before: old, after: new)
        }.sorted { order($0.before, $1.before) }
        durationBefore = before.duration; durationAfter = after.duration
        let mb = Set(before.markers.map(\.id)), ma = Set(after.markers.map(\.id))
        markersAdded = ma.subtracting(mb).count; markersRemoved = mb.subtracting(ma).count
    }

    /// Counts media items whose shown pixel aspect differs between the two projects (`setPixelAspect` operations).
    public mutating func noteMedia(before: Project, after: Project) {
        let n = after.media.filter { m in
            before.media(m.id).map { $0.info?.video?.displayPixelAspect != m.info?.video?.displayPixelAspect } ?? false
        }.count
        pixelAspectChanges = n == 0 ? nil : n
    }

    private static func refs(_ t: Timeline) -> [UUID: ClipRef] {
        var out: [UUID: ClipRef] = [:]
        for tr in t.tracks {
            for c in tr.clips {
                out[c.id] = ClipRef(id: c.id, track: tr.id, name: c.name, start: c.start, duration: c.duration,
                                    source: c.source, enabled: c.isEnabled)
            }
        }
        return out
    }
}
