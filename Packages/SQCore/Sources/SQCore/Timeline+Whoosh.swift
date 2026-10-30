import Foundation

extension Timeline {
    /// Cut times (a clip ends where another starts on the same track) touching any of `ids`, sorted, without duplicates.
    public func cuts(ofClips ids: Set<Clip.ID>) -> [Time] {
        var out: [Time] = []
        for tr in tracks {
            for c in tr.clips where ids.contains(c.id) {
                if tr.clips.contains(where: { $0.start == c.timeline.end }) { out.append(c.timeline.end) }
                if tr.clips.contains(where: { $0.timeline.end == c.start }) { out.append(c.start) }
            }
        }
        return Array(Set(out)).sorted()
    }

    /// The time of `edge` of clip `id` when a neighbor touches it there (a cut); nil otherwise.
    public func cutTime(ofClip id: Clip.ID, edge: ClipEdge) -> Time? {
        guard let c = find(id)?.clip else { return nil }
        let at = edge == .head ? c.start : c.timeline.end
        return cuts(ofClips: [id]).contains(at) ? at : nil
    }

    /// "Whoosh at selected cuts": one copy of the audio clip `proto` per cut, centered on it (clamped to the sequence start,
    /// snapped to the frame grid), each on the first unlocked audio track that is free over its range; a new audio track
    /// when none is. Copies get fresh IDs and no link. Atomic, so one undo step. Returns the new clip IDs in cut order.
    @discardableResult
    public mutating func placeCentred(_ proto: Clip, onCuts cuts: [Time]) throws -> [Clip.ID] {
        guard proto.kind == .audio else { throw EditError.wrongTrackKind }
        let sorted = Array(Set(cuts)).sorted()
        guard !sorted.isEmpty, proto.duration > .zero else { throw EditError.clipNotFound }
        var work = self
        var ids: [Clip.ID] = []
        let half = proto.duration.halved
        for cut in sorted {
            var c = proto
            c.id = UUID(); c.link = nil; c.bundle = nil; c.attachment = nil
            let at = cut - half
            c.start = (at < .zero ? .zero : at).snapped(to: frameDuration)
            let range = c.timeline
            var target = work.tracks.firstIndex {
                $0.kind == .audio && !$0.isLocked && !$0.clips.contains { $0.timeline.overlaps(range) }
            }
            if target == nil { work.addTrack(kind: .audio); target = work.tracks.count - 1 }
            try work.tracks[target!].overwrite(c)
            ids.append(c.id)
        }
        self = work
        return ids
    }
}
