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
        return alive.isEmpty ? nil : EdgeSelection(edges: alive, ripple: sel.ripple, linked: sel.linked)
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

    /// Ctrl+T: the next trim type of the selected edit. Order: regular trim, ripple, rolling (only where the edit has a
    /// clip on both sides), then regular again. Premiere's Adobe text only says "the next type in the order"; this order
    /// is ours. The selected edges stay, except that rolling selects both sides and leaving it keeps the first edge.
    public static func cycled(_ sel: EdgeSelection, in t: Timeline) -> EdgeSelection {
        guard let first = sel.edges.first else { return sel }
        let l = sel.linked
        if isRoll(sel, in: t) { return EdgeSelection(edges: [first], ripple: false, linked: l) }
        if !sel.ripple { return EdgeSelection(edges: sel.edges, ripple: true, linked: l) }
        if let p = partner(of: first, in: t) { return EdgeSelection(edges: [first, p], ripple: false, linked: l) }
        return EdgeSelection(edges: sel.edges, ripple: false, linked: l)
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

    /// E: moves the first selected edit to `time` (the playhead). A selected edit (both sides) rolls with the linked
    /// partners of both clips; a single edge trims. Either way a clip keeps at least one frame instead of the edit failing.
    public static func extend(_ sel: EdgeSelection, to time: Time, in t: Timeline) -> [TimelineEdit] {
        guard let first = sel.edges.first, let at = Self.time(of: first, in: t), time != at else { return [] }
        if let p = partner(of: first, in: t), sel.edges.contains(p) {
            let left = first.edge == .tail ? first : p
            return [.extendEdit(left.clip, edge: .tail, to: time)]
        }
        // Shortening: every trimmed clip (and its linked partners, which get the same change) keeps one frame.
        var delta = time - at
        let fd = t.frameDuration
        for r in sel.edges {
            guard let c = clip(r.clip, in: t)?.clip else { continue }
            let group = t.tracks.flatMap(\.clips).filter { $0.id == c.id || (c.link != nil && $0.link == c.link) }
            for g in group {
                if r.edge == .tail, delta < .zero { delta = max(delta, min(.zero, fd - g.duration)) }
                if r.edge == .head, delta > .zero { delta = min(delta, max(.zero, g.duration - fd)) }
            }
        }
        return trim(sel, by: delta, in: t)
    }
}
