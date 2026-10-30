import Foundation

extension Timeline {
    /// `count` video tracks for a title (lines and emoji, one clip each), bottom to top: the unlocked tracks above the
    /// highest video track that has a clip over `range`, free over it; new video tracks go on top for the rest.
    /// Never overwrites anything.
    public mutating func stackedTitleTracks(count: Int, over range: TimeRange) -> [Track.ID] {
        guard count > 0 else { return [] }
        let video = tracks.filter { $0.kind == .video }
        let busy = video.lastIndex { $0.clips.contains { $0.timeline.overlaps(range) } }
        let above = busy.map { video.suffix(from: $0 + 1) } ?? video[...]
        var out = above.filter { !$0.isLocked && !$0.clips.contains { $0.timeline.overlaps(range) } }.prefix(count).map(\.id)
        while out.count < count { out.append(addTrack(kind: .video)) }
        return out
    }
}
