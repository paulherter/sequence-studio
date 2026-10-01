import Foundation

/// Where a dropped media item lands (Premiere): video on the track under the pointer, its linked audio on the
/// mirrored audio track A(n) for V(n). One rule for Finder drops, Project-panel drops and the drop ghost.
public struct DropTargets: Sendable, Hashable {
    public var video: Track.ID?
    /// Existing audio track the audio lands on; nil when `newAudioOrdinal` says it must be created first.
    public var audio: Track.ID?
    /// Zero-based audio track ordinal (A1 = 0) that does not exist yet and is created for the drop.
    public var newAudioOrdinal: Int?
}

extension Timeline {
    /// Zero-based position of a track among the tracks of its kind (V1 / A1 = 0).
    public func ordinal(of id: Track.ID) -> Int? {
        guard let t = track(id) else { return nil }
        return tracks.filter { $0.kind == t.kind }.firstIndex { $0.id == id }
    }

    public func audioTrack(atOrdinal n: Int) -> Track.ID? {
        let audio = tracks.filter { $0.kind == .audio }
        return audio.indices.contains(n) ? audio[n].id : nil
    }

    /// Targets for one dropped item. `pointer` is the track under the pointer (any kind) or nil.
    /// - Video goes to the pointer's video track, else the targeted, else the first video track.
    /// - Audio goes to the audio track with the same ordinal as that video track (V2 -> A2); a missing one is reported
    ///   in `newAudioOrdinal`. Audio-only items dropped on an audio track stay on that track.
    /// - Without any video track the audio falls back to the targeted or first audio track.
    public func dropTargets(pointer: Track.ID?, hasVideo: Bool, hasAudio: Bool) -> DropTargets {
        let pointed = pointer.flatMap { track($0) }
        var out = DropTargets()
        if !hasVideo, hasAudio, let p = pointed, p.kind == .audio { out.audio = p.id; return out }
        let v = pointed.flatMap { $0.kind == .video ? $0.id : nil }
            ?? tracks.first { $0.kind == .video && $0.isTargeted }?.id ?? tracks.first { $0.kind == .video }?.id
        if hasVideo { out.video = v }
        if hasAudio {
            if let v, let n = ordinal(of: v) {
                if let a = audioTrack(atOrdinal: n) { out.audio = a } else { out.newAudioOrdinal = n }
            } else {
                out.audio = tracks.first { $0.kind == .audio && $0.isTargeted }?.id ?? tracks.first { $0.kind == .audio }?.id
                if out.audio == nil { out.newAudioOrdinal = 0 }
            }
        }
        return out
    }

    /// Appends audio tracks until one with `ordinal` exists; returns its ID.
    @discardableResult
    public mutating func ensureAudioTrack(atOrdinal ordinal: Int) -> Track.ID {
        while audioTrack(atOrdinal: ordinal) == nil {
            let isFirst = !tracks.contains { $0.kind == .audio }
            tracks.append(Track(kind: .audio, isTargeted: isFirst))
        }
        return audioTrack(atOrdinal: ordinal)!
    }
}
