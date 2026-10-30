import Foundation

/// Premiere's "Move into Sync" / "Slip into Sync" (right-click on the out-of-sync badge). Both act on the one clip
/// that carries the badge and bring its offset (see `syncOffsets()`) to 0; the linked partner stays where it is.
extension Timeline {
    /// Moves the clip on its own track so it is in sync with its partner. Covered clips are overwritten like in a move;
    /// refused when the clip would start before 0 or its track is locked. No-op when the clip is in sync.
    public mutating func moveIntoSync(_ id: Clip.ID) throws {
        guard let m = find(id) else { throw EditError.clipNotFound }
        if tracks[m.track].isLocked { throw EditError.trackLocked }
        let offsets = syncOffsets()
        guard let frames = offsets[id] else { return }
        // Fast Cut: a main-track clip cannot move (V1 stays gapless); its partners off V1 move the other way instead.
        if isFastCut, isOnMainTrack(id) {
            // Partners on locked tracks stay put (they are not candidates); none left means `.collision`.
            let partners = tracks.filter { !$0.isLocked }.flatMap(\.clips).filter {
                $0.id != id && m.clip.link != nil && $0.link == m.clip.link && offsets[$0.id] != nil && !isOnMainTrack($0.id)
            }.map(\.id)
            guard !partners.isEmpty else { throw EditError.collision }
            var work = self
            try work.magneticEdit(involving: Set(partners), local: true, stay: .all) { w in
                for p in partners { try w.moveIntoSync(p) }
            }
            self = work
            return
        }
        var c = m.clip
        c.start = c.start - frameDuration * frames
        if c.start < .zero { throw EditError.collision }
        var work = tracks
        work[m.track].remove(id)
        var relinks: [UUID: UUID] = [:]
        try work[m.track].overwrite(c, relinks: &relinks)
        guard work.allSatisfy({ $0.isConsistent }) else { throw EditError.collision }
        tracks = work
    }

    /// Slips the clip's source so it is in sync with its partner; position and duration stay. Refused when the media
    /// does not reach that far (`insufficientMedia`) or the track is locked. No-op when the clip is in sync.
    public mutating func slipIntoSync(_ id: Clip.ID) throws {
        guard let m = find(id) else { throw EditError.clipNotFound }
        if tracks[m.track].isLocked { throw EditError.trackLocked }
        guard let frames = syncOffsets()[id] else { return }
        var c = m.clip
        if c.speedKeys != nil { throw EditError.speedUnsupported }
        c.source.start = c.source.start + frameDuration * frames
        if c.source.start < .zero { throw EditError.insufficientMedia }
        if let total = c.mediaDuration, c.source.end > total { throw EditError.insufficientMedia }
        var work = tracks
        work[m.track].replace(c)
        tracks = work
    }
}
