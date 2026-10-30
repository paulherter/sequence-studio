import Foundation

extension Project {
    /// Folds `drop` into `keep`: every clip (and stinger) of `drop` points at `keep`, the item goes, `keep` inherits the
    /// Source marks it lacks. One file is one asset. No-op for unknown or equal ids.
    @discardableResult
    mutating func mergeMedia(_ drop: MediaRef.ID, into keep: MediaRef.ID) -> Bool {
        guard drop != keep, media.contains(where: { $0.id == drop }), media.contains(where: { $0.id == keep }) else { return false }
        for ti in timelines.indices {
            for tri in timelines[ti].tracks.indices {
                for c in timelines[ti].tracks[tri].clips {
                    var n = c
                    if n.media == drop { n.media = keep }
                    // LUTs embedded in the dropped item (any clip may carry one, e.g. pasted grades) now name `keep`.
                    for k in n.effects.indices {
                        if var d = n.effects[k].grade {
                            d.inputLUT = d.inputLUT?.repointing(drop, to: keep)
                            d.look = d.look?.repointing(drop, to: keep)
                            n.effects[k].grade = d
                        }
                        guard var g = n.effects[k].colorGraph else { continue }
                        g.inputLUT = g.inputLUT?.repointing(drop, to: keep)
                        g.outputLUT = g.outputLUT?.repointing(drop, to: keep)
                        for si in g.steps.indices { g.steps[si].lut = g.steps[si].lut?.repointing(drop, to: keep) }
                        n.effects[k].colorGraph = g
                    }
                    if n != c { timelines[ti].tracks[tri].replace(n) }
                }
                for k in timelines[ti].tracks[tri].transitions.indices where timelines[ti].tracks[tri].transitions[k].stinger?.media == drop {
                    timelines[ti].tracks[tri].transitions[k].stinger?.media = keep
                }
            }
        }
        if sourceMarks[keep] == nil, let m = sourceMarks[drop] { sourceMarks[keep] = m }
        let gone = media.first { $0.id == drop }!
        for i in media.indices {
            if media[i].id == keep {
                if media[i].sourceMarkers == nil { media[i].sourceMarkers = gone.sourceMarkers }
                if media[i].label == nil { media[i].label = gone.label }
                if media[i].posterTime == nil { media[i].posterTime = gone.posterTime }
            }
            if media[i].subclip?.parent == drop { media[i].subclip?.parent = keep }   // subclips of the dropped item follow
        }
        sourceMarks[drop] = nil
        media.removeAll { $0.id == drop }
        normalizeBins()
        return true
    }

    /// After a relink: items of `moved` that now share a path with another item are folded into it (the item that was
    /// there first, or the earlier one of two relinked items). Called by `relink`.
    mutating func mergeSharedPaths(moved: Set<MediaRef.ID>) {
        for id in media.map(\.id) where moved.contains(id) {
            guard let mi = media.firstIndex(where: { $0.id == id }) else { continue }
            let path = media[mi].path
            // Subclips share their parent's path by design: only items with the same subclip value (both none) are one file.
            if let ti = media.indices.first(where: { $0 != mi && media[$0].path == path && media[$0].subclip == media[mi].subclip
                                                       && (!moved.contains(media[$0].id) || $0 < mi) }) {
                mergeMedia(id, into: media[ti].id)
            }
        }
    }

    /// Repair for projects that hold a linked original AND its imported copy (`folder` is the Imported folder with a
    /// trailing slash): the original is folded into the copy when `isSameFile(original, copy)` says so (the caller
    /// compares contents). Only items outside `folder` with a size match are offered. Returns how many were merged.
    @discardableResult
    public mutating func mergeLinkedOriginals(intoCopiesIn folder: String, isSameFile: (MediaRef, MediaRef) -> Bool) -> Int {
        var merged = 0
        let copies = media.filter { $0.path.hasPrefix(folder) && $0.subclip == nil }
        for original in media where !original.path.hasPrefix(folder) && original.fingerprint.size > 0 && original.subclip == nil {
            guard let copy = copies.first(where: { $0.fingerprint.size == original.fingerprint.size && isSameFile(original, $0) }) else { continue }
            if mergeMedia(original.id, into: copy.id) { merged += 1 }
        }
        return merged
    }
}

extension LUTRef {
    /// `.embedded(drop)` as `.embedded(keep)`; everything else unchanged.
    func repointing(_ drop: UUID, to keep: UUID) -> LUTRef {
        if case .embedded(let m) = self, m == drop { return .embedded(keep) }
        return self
    }
}
