import Foundation

/// Take comping: several takes of one performance sit on stacked tracks of the same kind; picking a take for a range
/// lets that take play there and silences / hides the others, without touching track mute, solo or visibility.
extension Timeline {
    /// The tracks that hold the other takes for `clip` over `range`: unlocked tracks of the same kind (other than the
    /// clip's own) with a clip overlapping `range`. Indices into `tracks`, top to bottom.
    func takeStackTracks(of clipID: Clip.ID, range: TimeRange) -> [Int] {
        guard let own = tracks.firstIndex(where: { $0.clips.contains { $0.id == clipID } }) else { return [] }
        let kind = tracks[own].kind
        return tracks.indices.filter { i in
            i != own && tracks[i].kind == kind && !tracks[i].isLocked
                && tracks[i].clips.contains { $0.timeline.overlaps(range) }
        }
    }

    /// Whether `compTake` has other takes to silence for this clip over `range`.
    public func canCompTake(of clipID: Clip.ID, range: TimeRange) -> Bool {
        guard let own = tracks.first(where: { $0.clips.contains { $0.id == clipID } }), !own.isLocked,
              let c = own.clips.first(where: { $0.id == clipID }),
              let r = range.intersection(c.timeline), !r.isEmpty else { return false }
        return !takeStackTracks(of: clipID, range: r).isEmpty
    }

    /// Uses the take `clipID` is on for the part of `range` it covers: every track of the same kind that holds an
    /// overlapping clip is cut at the range edges, the clips of the other takes inside the range are disabled and the
    /// clips of the chosen track inside it are enabled. Linked partners (the audio of a picture take) follow their
    /// clip. Returns the chosen track's clips inside the range. Throws `clipNotFound` when the clip is unknown or
    /// nothing is left of the range, `trackLocked` for a locked chosen track, `notACut` when there is no other take.
    @discardableResult
    public mutating func compTake(of clipID: Clip.ID, range: TimeRange) throws -> [Clip.ID] {
        guard let own = tracks.firstIndex(where: { $0.clips.contains { $0.id == clipID } }),
              let clip = tracks[own].clips.first(where: { $0.id == clipID }) else { throw EditError.clipNotFound }
        guard let r = range.intersection(clip.timeline), !r.isEmpty else { throw EditError.clipNotFound }
        if tracks[own].isLocked { throw EditError.trackLocked }
        let others = takeStackTracks(of: clipID, range: r)
        guard !others.isEmpty else { throw EditError.notACut }
        let stack = [own] + others
        // Cut the take tracks and the tracks of linked partners, so a split pair stays a pair.
        let links = Set(stack.flatMap { tracks[$0].clips.filter { $0.timeline.overlaps(r) }.compactMap(\.link) })
        var cutTracks = Set(stack)
        for i in tracks.indices {
            if tracks[i].clips.contains(where: { c in c.timeline.overlaps(r) && (c.link.map(links.contains) ?? false) }) {
                // A locked partner track refuses the whole edit before anything is cut.
                if tracks[i].isLocked { throw EditError.trackLocked }
                cutTracks.insert(i)
            }
        }
        var relinks: [UUID: UUID] = [:]
        for i in cutTracks.sorted() {
            try tracks[i].split(at: r.start, relinks: &relinks)
            try tracks[i].split(at: r.end, relinks: &relinks)
        }
        // Inside the range: the chosen track plays, the others are off; partners take their clip's state.
        var chosen: [Clip.ID] = []
        var state: [UUID: Bool] = [:]
        for i in stack {
            for c in tracks[i].clips where c.start >= r.start && c.timeline.end <= r.end {
                if let l = c.link { state[l] = (i == own) }
            }
        }
        // Halves of a split pair got fresh links: state of the right halves follows through the relink map.
        for (old, new) in relinks { if let on = state[old] { state[new] = on } }
        for i in cutTracks {
            for j in tracks[i].clips.indices {
                var c = tracks[i].clips[j]
                guard c.start >= r.start, c.timeline.end <= r.end else { continue }
                if stack.contains(i) {
                    c.isEnabled = (i == own)
                    tracks[i].replace(c)
                    if i == own { chosen.append(c.id) }
                } else if let l = c.link, let on = state[l] {
                    c.isEnabled = on
                    tracks[i].replace(c)
                }
            }
        }
        return chosen
    }
}
