import Foundation

/// What an undo or redo touched in a sequence: the clips that exist afterwards and the time range they or their
/// removed predecessors covered. The editor moves the playhead, selection and view there so the change is visible.
public struct UndoFocus: Sendable, Equatable {
    public var clips: Set<Clip.ID>
    public var range: TimeRange

    public init(clips: Set<Clip.ID>, range: TimeRange) {
        self.clips = clips
        self.range = range
    }

    /// Compares two states of the same sequence by clip. nil when no clip differs (or a state is missing).
    public static func between(_ old: Timeline?, _ new: Timeline?) -> UndoFocus? {
        guard let old, let new else { return nil }
        let before = Dictionary(old.tracks.flatMap(\.clips).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let after = Dictionary(new.tracks.flatMap(\.clips).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var ids: Set<Clip.ID> = []
        var lo: Time?, hi: Time?
        func cover(_ r: TimeRange) {
            lo = lo.map { min($0, r.start) } ?? r.start
            hi = hi.map { max($0, r.end) } ?? r.end
        }
        for (id, c) in after where before[id] != c {
            ids.insert(id)
            cover(c.timeline)
            if let o = before[id] { cover(o.timeline) }
        }
        for (id, c) in before where after[id] == nil { cover(c.timeline) }
        guard let lo, let hi else { return nil }
        return UndoFocus(clips: ids, range: TimeRange(start: lo, end: hi))
    }

    /// Where the playhead should go: nil when it already is inside the range, else the range start.
    public func playhead(from current: Time) -> Time? {
        (current >= range.start && current <= range.end) ? nil : range.start
    }
}
