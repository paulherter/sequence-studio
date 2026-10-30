import Foundation

// Flatten Angles Clip: replaces an Angles piece (with its linked pieces of the same Angles sequence) by the clips of the
// angle it shows, as ordinary clips on the timeline. Built on Unnest, so it follows the same rules and refusals; the
// Angles sequence itself stays in the project.

extension Project {
    /// Replaces the Angles piece `clipID` and its linked pieces of the same Angles sequence by the content of the angle
    /// each shows (a video piece its picture track, a sound piece its audio track). Returns the placed clip ids.
    /// Throws `.notNested` when `clipID` is no Angles piece, plus the refusals of Unnest (`.ungroupLosesLook`,
    /// `.trackLocked`, `.collision`).
    @discardableResult
    public mutating func flattenAngles(clip clipID: Clip.ID, in timelineID: Timeline.ID) throws -> [Clip.ID] {
        guard let tl = timeline(timelineID) else { throw EditError.timelineNotFound }
        guard let hit = tl.find(clipID) else { throw EditError.clipNotFound }
        guard hit.clip.isAnglesClip, let seqID = hit.clip.sequence, let inner = timeline(seqID) else { throw EditError.notNested }
        let pieces = try tl.linkedGroup(clipID).map(\.clip).filter { $0.isAnglesClip && $0.sequence == seqID }
        // One stand-in sequence with the shown picture track and the shown sound track: Unnest then restores both halves
        // together and keeps their links.
        var view = inner
        view.id = UUID()
        view.angles = nil
        var shown: [TrackKind: Int] = [:]
        for p in pieces where shown[p.kind] == nil { shown[p.kind] = p.angle?.index ?? 0 }
        var seen: [TrackKind: Int] = [:]
        view.tracks = inner.tracks.filter { t in
            guard let want = shown[t.kind] else { return t.kind != .video && t.kind != .audio }
            let n = seen[t.kind, default: 0]
            seen[t.kind] = n + 1
            return n == min(want, max(inner.tracks.filter { $0.kind == t.kind }.count - 1, 0))
        }
        var work = self
        work.timelines.append(view)
        let ids = Set(pieces.map(\.id))
        try work.edit(timelineID) { t in
            for i in t.tracks.indices {
                for var c in t.tracks[i].clips where ids.contains(c.id) {
                    c.sequence = view.id; c.media = view.id; c.angle = nil
                    t.tracks[i].replace(c)
                }
            }
        }
        let placed = try work.unnest(clip: clipID, in: timelineID)
        work.timelines.removeAll { $0.id == view.id }
        self = work
        return placed
    }
}
