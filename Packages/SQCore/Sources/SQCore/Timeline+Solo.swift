import Foundation

/// Premiere "selected unlinked" (Option-click, or Linked Selection off): an edit acts on exactly the selected clips.
/// A linked partner follows only when it is selected too.
extension Timeline {
    /// Linked partners of `ids` that are not in `ids` themselves (they stay put when only `ids` are edited).
    public func heldBackPartners(of ids: Set<Clip.ID>) -> Set<Clip.ID> {
        let links = Set(tracks.flatMap(\.clips).filter { ids.contains($0.id) }.compactMap(\.link))
        guard !links.isEmpty else { return [] }
        return Set(tracks.flatMap(\.clips).filter { c in c.link.map(links.contains) == true && !ids.contains(c.id) }.map(\.id))
    }

    /// Runs `body` (any linked edit) so that only `ids` and their selected partners change: held-back partners are
    /// detached for the edit and relinked afterwards. A link left with a single clip (its partner deleted alone, a
    /// lone copy) is cleared. Without held-back partners `body` runs unchanged. Throws leave `self` unchanged.
    public mutating func editing(only ids: Set<Clip.ID>, _ body: (inout Timeline) throws -> Void) throws {
        let held = heldBackPartners(of: ids)
        guard !held.isEmpty else { try body(&self); return }
        var work = self
        var saved: [Clip.ID: UUID] = [:]
        work.relink { c in
            guard held.contains(c.id) else { return c.link }
            saved[c.id] = c.link
            return nil
        }
        try body(&work)
        work.relink { saved[$0.id] ?? $0.link }
        var counts: [UUID: Int] = [:]
        for c in work.tracks.flatMap(\.clips) { if let l = c.link { counts[l, default: 0] += 1 } }
        work.relink { c in c.link.flatMap { counts[$0, default: 0] < 2 ? nil : $0 } }
        // Fast Cut: a clip moved alone and linked again is no attachment of its own any more.
        work.deriveFastCutAttachments()
        self = work
    }

    /// Sets every clip's link to `f(clip)` (only clips whose link changes are replaced).
    private mutating func relink(_ f: (Clip) -> UUID?) {
        for ti in tracks.indices {
            for var c in tracks[ti].clips {
                let l = f(c)
                guard l != c.link else { continue }
                c.link = l
                tracks[ti].replace(c)
            }
        }
    }
}
