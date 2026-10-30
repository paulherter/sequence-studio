import Foundation

extension Timeline {
    /// True when every clip of `ids` is a generator (text, shape, adjustment layer): no media, no nested sequence.
    /// A title block (Library) holds only such clips, so it can be placed in any project.
    public func isMediaFree(_ ids: Set<Clip.ID>) -> Bool {
        let clips = tracks.flatMap(\.clips).filter { ids.contains($0.id) }
        return !clips.isEmpty && clips.count == ids.count && clips.allSatisfy { $0.generator != nil && $0.sequence == nil && $0.kind == .video }
    }

    /// Places a copied block (a saved title: several generator clips with their element transitions) at `t` on free
    /// video tracks: the unlocked tracks above everything that plays over the block's span, new tracks on top when
    /// there are not enough. The block's lane order is kept (lowest lane = lowest new track). Nothing is overwritten.
    /// Copies get new IDs. Returns the new clip IDs in `block.entries` order. Throws `.emptyClip` for an empty block
    /// and `.wrongTrackKind` when it holds anything but video-track clips.
    @discardableResult
    public mutating func placeBlock(_ block: TimelineClipboard, at t: Time) throws -> [Clip.ID] {
        guard !block.isEmpty else { throw EditError.emptyClip }
        guard block.entries.allSatisfy({ $0.clip.kind == .video }) else { throw EditError.wrongTrackKind }
        let t = max(t.ceiled(to: frameDuration), .zero)
        let span = max(block.duration, frameDuration)
        let lanes = Array(Set(block.entries.map(\.lane))).sorted()
        var work = self
        let targets = work.stackedTitleTracks(count: lanes.count, over: TimeRange(start: t, duration: span))
        let known = Set(work.variants.map(\.id))
        var newID: [Clip.ID: Clip.ID] = [:]
        var ids: [Clip.ID] = []
        for e in block.entries {
            guard let rank = lanes.firstIndex(of: e.lane), let ti = work.tracks.firstIndex(where: { $0.id == targets[rank] }) else {
                throw EditError.clipNotFound
            }
            var c = e.clip
            c.id = UUID()
            c.link = nil
            c.start = t + e.offset
            c.variantOverrides = c.variantOverrides.filter { known.contains($0.key) }
            if c.generator != nil { c.media = c.id }
            newID[e.clip.id] = c.id
            var relinks: [UUID: UUID] = [:]
            try work.tracks[ti].overwrite(c, relinks: &relinks)
            ids.append(c.id)
        }
        work.remapAttachments(newID, only: Set(ids))
        for old in block.transitions {
            var tr = old
            tr.id = UUID()
            tr.outgoing = old.outgoing.flatMap { newID[$0] }
            tr.incoming = old.incoming.flatMap { newID[$0] }
            guard (old.outgoing == nil) == (tr.outgoing == nil), (old.incoming == nil) == (tr.incoming == nil),
                  let owner = work.tracks.firstIndex(where: { $0.clip(tr.outgoing ?? tr.incoming ?? UUID()) != nil }) else { continue }
            work.tracks[owner].transitions.append(tr)
        }
        work.pruneTransitions()
        self = work
        return ids
    }
}
