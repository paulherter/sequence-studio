import Foundation

/// One-sweep batch ripple: many cuts closed in one pass ("Remove Silences", filler words, accepted proposed cuts).
/// The result equals `extract` once per cut from the last to the first (the old path, kept as the test oracle), at
/// O(clips + cuts · log cuts) instead of one full copy and scan of every track per cut.
extension Timeline {
    /// Sorted, disjoint, non-empty cuts in the coordinates before the edit and where each point lands once they are
    /// all closed: a point inside a cut lands where that cut began, a point at or after a cut moves left by its length
    /// (the per-cut rule of `shiftMarkers` and `CaptionTrack.closeSpan`, composed).
    struct RippleMap {
        let cuts: [TimeRange]
        /// `removed[k]`: total length of `cuts[0..<k]` (count + 1 entries).
        let removed: [Time]

        init(_ cuts: [TimeRange]) {
            self.cuts = cuts
            var r = [Time.zero]
            r.reserveCapacity(cuts.count + 1)
            for c in cuts { r.append(r[r.count - 1] + c.duration) }
            removed = r
        }

        var total: Time { removed[removed.count - 1] }

        /// How many cuts end at or before `t`.
        func endedBy(_ t: Time) -> Int {
            var lo = 0, hi = cuts.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if cuts[mid].end <= t { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }

        func map(_ t: Time) -> Time {
            let k = endedBy(t)
            if k < cuts.count, cuts[k].start < t { return cuts[k].start - removed[k] }
            return t - removed[k]
        }
    }

    /// Extracts every cut from the tracks at `targets` in one sweep and closes the captions, markers and In/Out the
    /// way `extract` does. `cuts` must be sorted, disjoint and not touching, and no unlocked sync-locked track may be
    /// missing from `targets`: then everything that moves is also cut, nothing holds a cut open, and every cut closes
    /// completely (the sequential path's clamp cannot occur). Returns the time removed. A result that no longer fits
    /// (times rounded off every frame grid) throws `.collision` and changes nothing.
    mutating func extractAll(_ cuts: [TimeRange], targets: [Int]) throws -> Time {
        guard !cuts.isEmpty else { return .zero }
        let map = RippleMap(cuts)
        var work = tracks
        var relinks = [[UUID: UUID]](repeating: [:], count: cuts.count)
        var origin: [[Clip.ID: Time]] = []
        for i in targets { origin.append(work[i].extractAll(map, relinks: &relinks)) }
        // As `extract` does per cut (last first): a clip that starts at or after a cut and still holds the old link of a
        // clip that cut split belongs to its right piece and takes that piece's new link.
        var byLink: [UUID: [(cut: Int, link: UUID)]] = [:]
        for j in relinks.indices.reversed() { for (l, nl) in relinks[j] { byLink[l, default: []].append((j, nl)) } }
        for (n, i) in targets.enumerated() where !byLink.isEmpty {
            var changed = false
            let moved = work[i].clips.map { c -> Clip in
                var c = c
                guard let l = c.link, let hits = byLink[l], let o = origin[n][c.id] else { return c }
                if let h = hits.first(where: { o >= map.cuts[$0.cut].end }) { c.link = h.link; changed = true }
                return c
            }
            if changed { work[i].setClips(moved) }
        }
        guard work.allSatisfy(\.isConsistent) else { throw EditError.collision }
        tracks = work
        for i in captionTracks.indices where captionTracks[i].followsRipple { captionTracks[i].closeSpans(map.map) }
        shiftMarkers(through: map.map)
        shiftInOut(through: map.map)
        return map.total
    }

    /// True when `extractAll` may stand in for one `extract` per cut on these targets: cuts sorted, non-empty, at or
    /// after 0, overlapping none (touching is fine: closing both equals closing their union), and every unlocked
    /// sync-locked track targeted.
    func batchRippleApplies(_ sorted: [TimeRange], targets: [Int]) -> Bool {
        guard sorted.allSatisfy({ !$0.isEmpty && $0.start >= .zero }),
              zip(sorted, sorted.dropFirst()).allSatisfy({ $0.end <= $1.start }) else { return false }
        let t = Set(targets)
        guard tracks.indices.allSatisfy({ !tracks[$0].followsRipple || t.contains($0) }) else { return false }
        // `extract` also cuts and relinks untargeted partners of a cut clip; the batch sweep does not, so those go the long way.
        let links = Set(targets.flatMap { tracks[$0].clips.compactMap(\.link) })
        return tracks.indices.allSatisfy { t.contains($0) || tracks[$0].isLocked || !tracks[$0].clips.contains { c in c.link.map(links.contains) == true } }
    }
}

extension Track {
    /// `clear` of every cut, then the shift that closes them, in one pass. Pieces are cut from each clip exactly as
    /// the sequential path cuts them (last cut first, the left part keeps the ID and link, a right part gets a new ID
    /// and the link of `relinks[cut]`, shared with the pieces other tracks cut there), so keys, speed and transitions
    /// come out the same.
    @discardableResult
    mutating func extractAll(_ map: Timeline.RippleMap, relinks: inout [[UUID: UUID]]) -> [Clip.ID: Time] {
        var origin: [Clip.ID: Time] = [:]
        let cuts = map.cuts
        var out: [Clip] = []
        out.reserveCapacity(clips.count)
        var retarget: [Clip.ID: Clip.ID] = [:]
        var lo = 0
        func shifted(_ c: Clip) -> Clip {
            var c = c
            c.start = c.start - map.removed[map.endedBy(c.start)]
            return c
        }
        for c in clips {
            let end = c.timeline.end
            while lo < cuts.count && cuts[lo].end <= c.start { lo += 1 }
            var hi = lo
            while hi < cuts.count && cuts[hi].start < end { hi += 1 }
            if hi == lo { origin[c.id] = c.start; out.append(shifted(c)); continue }
            var pieces: [Clip] = []
            var cur: Clip? = c
            for j in stride(from: hi - 1, through: lo, by: -1) {
                guard let k = cur else { break }
                let hole = cuts[j]
                guard k.timeline.overlaps(hole) else { continue }
                let keepsLeft = hole.start > k.start
                let left = keepsLeft ? k.cropped(to: TimeRange(start: k.start, end: hole.start)) : nil
                if hole.end < k.timeline.end, var right = k.cropped(to: TimeRange(start: hole.end, end: k.timeline.end)) {
                    if keepsLeft {
                        let old = right.id
                        right.id = UUID(); right.relink(&relinks[j])
                        // The first cut (from the end) moves the old tail's transitions; later ones find none left.
                        if retarget[old] == nil { retarget[old] = right.id }
                    }
                    pieces.append(right)
                }
                cur = left
            }
            if let k = cur { pieces.append(k) }
            for p in pieces.reversed() { origin[p.id] = p.start; out.append(shifted(p)) }
        }
        setClips(out)
        if !retarget.isEmpty {
            for i in transitions.indices {
                if let o = transitions[i].outgoing, let n = retarget[o] { transitions[i].outgoing = n }
            }
        }
        return origin
    }
}
