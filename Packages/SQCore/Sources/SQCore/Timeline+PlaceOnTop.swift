import Foundation

/// Where "Place on Top" puts the media.
public enum PlaceOnTopTarget: Sendable, Hashable {
    case existing(Track.ID)
    /// No free video track above the occupied ones: the caller adds one (same undo step).
    case newTrack
}

extension Timeline {
    /// Resolve-style Place on Top (Q-BRL1): the lowest unlocked video track above the topmost video track that has a clip
    /// overlapping `range` and is itself empty there; `.newTrack` when there is none. With nothing in the range, the first
    /// unlocked empty video track. Pure; independent of track targeting.
    public func placeOnTopTarget(in range: TimeRange) -> PlaceOnTopTarget {
        let video = tracks.filter { $0.kind == .video }
        func busy(_ t: Track) -> Bool { t.clips.contains { $0.timeline.overlaps(range) } }
        // Fast Cut: V1 is the main track; Place on Top attaches above it and never lands on it.
        // With an empty main track nothing can be attached: the clip goes on the main track then.
        let floor = isFastCut && mainTrackEnd > .zero ? 1 : 0
        let from = max((video.lastIndex(where: busy)).map { $0 + 1 } ?? 0, floor)
        if from < video.count, let t = video[from...].first(where: { !$0.isLocked && !busy($0) }) { return .existing(t.id) }
        return .newTrack
    }
}
