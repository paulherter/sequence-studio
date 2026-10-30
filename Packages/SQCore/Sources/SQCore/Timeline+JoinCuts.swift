import Foundation

// Join Cuts (our name; Premiere calls it Join Through Edits): a through edit is the leftover of a blade. Two clips that sit
// edge to edge, play contiguous parts of the same source and are identical in every other property, so the cut changes
// nothing in picture or sound. Joining puts them back into one clip.
//
// The test for "identical" is exact and cheap: build the joined clip, crop it back to both halves with `cropped(to:)` (the
// very function a blade uses) and compare with the originals. Speed, effects, keyframes, levels, labels, markers, anything
// stored: if one differs, the cut is a real edit and stays.

/// A through edit: the clip before the cut and the clip after it, on one track.
public struct ThroughEdit: Sendable, Hashable {
    public var left: Clip.ID
    public var right: Clip.ID
}

extension Clip {
    /// The clip `next` would become when this clip absorbs it, nil when the cut between them is a real edit.
    func joined(with next: Clip) -> Clip? {
        guard kind == next.kind, media == next.media, sequence == next.sequence,
              !isGenerator, !next.isGenerator, !isStill, !next.isStill,
              holdFrame == nil, next.holdFrame == nil, speedKeys == nil, next.speedKeys == nil,
              reversed == next.reversed, start + duration == next.start else { return nil }
        let range: TimeRange
        if reversed {
            guard next.source.end == source.start else { return nil }
            range = TimeRange(start: next.source.start, end: source.end)
        } else {
            guard source.end == next.source.start else { return nil }
            range = TimeRange(start: source.start, end: next.source.end)
        }
        var merged = self
        merged.source = range
        guard let l = merged.cropped(to: timeline), let r = merged.cropped(to: next.timeline) else { return nil }
        func same(_ a: Clip, _ b: Clip) -> Bool {
            var x = a, y = b
            x.id = b.id; x.link = b.link
            x.attachment = b.attachment              // Fast Cut: re-derived per half, rejoined clip keeps the left one
            y.id = b.id
            return x == y
        }
        return same(l, self) && same(r, next) ? merged : nil
    }
}

extension Timeline {
    /// Every through edit on unlocked tracks (all of them, or only those at a cut where `selection` holds the clip before
    /// or after it, or a linked partner of one), left to right per track. A linked pair counts as one cut per track: a video
    /// cut whose audio partner cut is a real edit is not listed.
    public func throughEdits(selection: Set<Clip.ID>? = nil) -> [ThroughEdit] {
        let all = tracks.flatMap(\.clips)
        var scope = selection
        if let sel = selection { scope = sel.union(heldBackPartners(of: sel)) }
        var candidates: [ThroughEdit] = []
        for t in tracks where !t.isLocked {
            for (a, b) in zip(t.clips, t.clips.dropFirst()) {
                if let scope, !scope.contains(a.id), !scope.contains(b.id) { continue }
                guard a.joined(with: b) != nil, !hasTransition(on: t, between: a, b) else { continue }
                candidates.append(ThroughEdit(left: a.id, right: b.id))
            }
        }
        let rightOf = Dictionary(uniqueKeysWithValues: candidates.map { ($0.left, $0.right) })
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { f, _ in f })
        return candidates.filter { e in
            guard let a = byID[e.left], let b = byID[e.right] else { return false }
            let pa = a.link.map { l in all.filter { $0.link == l && $0.id != a.id } } ?? []
            let pb = b.link.map { l in all.filter { $0.link == l && $0.id != b.id } } ?? []
            if pa.isEmpty && pb.isEmpty { return true }
            guard a.link != b.link else { return false }
            // Every partner of the left clip must join the matching partner of the right clip.
            return Set(pa.compactMap { rightOf[$0.id] }) == Set(pb.map(\.id)) && pa.allSatisfy { rightOf[$0.id] != nil }
        }
    }

    /// Joins the through edits (see `throughEdits`) until none is left in scope and returns how many cuts went. The joined
    /// clip keeps the left clip's ID, link and place; the right clip's ID disappears and a transition that started at its
    /// tail now starts at the joined clip's tail. Transitions on the cut itself keep the cut. 0 = nothing changed.
    @discardableResult
    public mutating func joinThroughEdits(selection: Set<Clip.ID>? = nil) throws -> Int {
        var joined = 0
        while true {
            let pass = throughEdits(selection: selection)
            var used = Set<Clip.ID>()
            var progressed = false
            for e in pass where !used.contains(e.left) && !used.contains(e.right) {
                guard let l = find(e.left), let r = find(e.right), l.track == r.track,
                      let merged = l.clip.joined(with: r.clip) else { continue }
                tracks[l.track].remove(r.clip.id)
                tracks[l.track].replace(merged)
                for i in tracks[l.track].transitions.indices where tracks[l.track].transitions[i].outgoing == r.clip.id {
                    tracks[l.track].transitions[i].outgoing = merged.id
                }
                used.insert(e.left); used.insert(e.right)
                joined += 1; progressed = true
            }
            if !progressed { return joined }
        }
    }

    /// True when a transition touches the cut between `a` and `b`: on the cut, at the tail of `a` or at the head of `b`.
    /// Joining through it would change what it is attached to, so those cuts stay.
    private func hasTransition(on t: Track, between a: Clip, _ b: Clip) -> Bool {
        t.transitions.contains { $0.outgoing == a.id || $0.incoming == b.id }
    }
}
