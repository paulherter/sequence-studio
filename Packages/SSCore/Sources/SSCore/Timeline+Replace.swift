import Foundation

extension Timeline {
    /// Replaces a clip by ID with `clip` for property edits (animation, name, volume...). The timeline position and
    /// source range must stay the same, so the track stays consistent: a timing change is `.collision` (use the trim
    /// and move edits for those). Throws `.clipNotFound`, or `.trackLocked` for a locked track.
    public mutating func replaceClip(_ clip: Clip) throws {
        guard let ti = tracks.firstIndex(where: { $0.clip(clip.id) != nil }), let old = tracks[ti].clip(clip.id) else {
            throw EditError.clipNotFound
        }
        guard !tracks[ti].isLocked else { throw EditError.trackLocked }
        guard old.start == clip.start, old.source == clip.source else { throw EditError.collision }
        tracks[ti].replace(clip)
    }
}
