import Foundation
import SQCore

/// Keyboard trims of selected clip edges (Trim Backward/Forward, Extend Edit) as replayable edits. Pure.
public enum EdgeEdits {
    private static func clip(_ id: Clip.ID, in t: Timeline) -> (clip: Clip, track: Track)? {
        for tr in t.tracks { if let c = tr.clips.first(where: { $0.id == id }) { return (c, tr) } }
        return nil
    }

    /// The edge refs that still exist in `t`.
    public static func pruned(_ sel: EdgeSelection, in t: Timeline) -> EdgeSelection? {
        let alive = sel.edges.filter { clip($0.clip, in: t) != nil }
        return alive.isEmpty ? nil : EdgeSelection(edges: alive, ripple: sel.ripple)
    }

    public static func time(of ref: EdgeRef, in t: Timeline) -> Time? {
        clip(ref.clip, in: t).map { ref.edge == .head ? $0.clip.start : $0.clip.timeline.end }
    }

    /// The other side of the edit `ref` sits on (same track, touching), if any.
    public static func partner(of ref: EdgeRef, in t: Timeline) -> EdgeRef? {
        guard let (c, tr) = clip(ref.clip, in: t) else { return nil }
        if ref.edge == .tail {
            return tr.clips.first { $0.start == c.timeline.end }.map { EdgeRef(clip: $0.id, edge: .head) }
        }
        return tr.clips.first { $0.timeline.end == c.start }.map { EdgeRef(clip: $0.id, edge: .tail) }
    }

    /// Both sides of one edit are selected: a drag or trim rolls the edit.
    public static func isRoll(_ sel: EdgeSelection, in t: Timeline) -> Bool {
        sel.edges.contains { r in partner(of: r, in: t).map { sel.edges.contains($0) } ?? false }
    }

    /// Moves the selected edges by `delta` (timeline direction: positive = later). Regular trim, ripple trim with
    /// Cmd-selected edges, rolling edit when both sides of an edit are selected.
    public static func trim(_ sel: EdgeSelection, by delta: Time, in t: Timeline) -> [TimelineEdit] {
        guard delta != .zero else { return [] }
        var out: [TimelineEdit] = []
        var done = Set<EdgeRef>()
        // Edits act on the whole link group: one per group and kind, or the delta would apply twice.
        var seen = Set<String>()
        func fresh(_ ref: EdgeRef, _ kind: String) -> Bool {
            guard let l = clip(ref.clip, in: t)?.clip.link else { return true }
            return seen.insert("\(l)-\(kind)").inserted
        }
        for r in sel.edges where !done.contains(r) {
            if let p = partner(of: r, in: t), sel.edges.contains(p) {
                done.insert(r); done.insert(p)
                let left = r.edge == .tail ? r : p
                if fresh(left, "roll") { out.append(.roll(left.clip, by: delta)) }
            } else {
                done.insert(r)
                guard fresh(r, r.edge == .head ? "head" : "tail") else { continue }
                out.append(sel.ripple ? .rippleTrim(r.clip, edge: r.edge, by: delta) : .trim(r.clip, edge: r.edge, by: delta))
            }
        }
        return out
    }

    /// E: moves the first selected edit to `time` (the playhead).
    public static func extend(_ sel: EdgeSelection, to time: Time, in t: Timeline) -> [TimelineEdit] {
        guard let first = sel.edges.first, let at = Self.time(of: first, in: t) else { return [] }
        return trim(sel, by: time - at, in: t)
    }
}
