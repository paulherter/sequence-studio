import Foundation

/// Generator clips (text layers): clips without media, see `Clip.generator`.
extension Project {
    /// Places a generator clip on a video track of `timeline` at `start`, covering `duration` (overwrite, like a
    /// drag onto the track). The clip has no media: free trims in both directions, keyframable like any clip.
    /// Throws `.wrongTrackKind` (audio track), `.trackLocked`, `.emptyClip` (duration under one frame),
    /// `.clipNotFound` (track) or `.timelineNotFound`. Returns the new clip's ID.
    @discardableResult
    public mutating func addGeneratorClip(kind: String, payload: Data, payloadVersion: Int = 1, name: String? = nil,
                                          in timeline: Timeline.ID, at start: Time, track: Track.ID,
                                          duration: Time) throws -> Clip.ID {
        guard let ti = timelines.firstIndex(where: { $0.id == timeline }) else { throw EditError.timelineNotFound }
        guard let tr = timelines[ti].tracks.firstIndex(where: { $0.id == track }) else { throw EditError.clipNotFound }
        guard timelines[ti].tracks[tr].kind == .video else { throw EditError.wrongTrackKind }
        guard !timelines[ti].tracks[tr].isLocked else { throw EditError.trackLocked }
        guard duration >= timelines[ti].frameDuration, start >= .zero else { throw EditError.emptyClip }
        let id = UUID()
        let clip = Clip(id: id, name: name ?? (kind == GeneratorRef.text ? "Text" : kind.capitalized), media: id,
                        kind: .video, source: TimeRange(start: .zero, duration: duration), start: start,
                        generator: GeneratorRef(kind: kind, payload: payload, payloadVersion: payloadVersion))
        try edit(timeline) { try $0.tracks[tr].overwrite(clip) }
        return id
    }

    /// Replaces a generator clip's payload (text edit). Position, length and animation stay. A single mutation,
    /// so callers get one undo step. Throws `.clipNotFound` for an unknown clip or one that is not a generator,
    /// `.trackLocked` on a locked track.
    public mutating func updateGenerator(clipID: Clip.ID, payload: Data, payloadVersion: Int? = nil) throws {
        for ti in timelines.indices {
            for tr in timelines[ti].tracks.indices {
                guard var c = timelines[ti].tracks[tr].clips.first(where: { $0.id == clipID }) else { continue }
                guard var g = c.generator else { throw EditError.clipNotFound }
                if timelines[ti].tracks[tr].isLocked { throw EditError.trackLocked }
                g.payload = payload
                if let payloadVersion { g.payloadVersion = payloadVersion }
                c.generator = g
                timelines[ti].tracks[tr].replace(c)
                return
            }
        }
        throw EditError.clipNotFound
    }
}
