import Foundation

// Reorder tracks. A track only trades places with the next track of its own kind (video stays above audio); "up" is what
// the timeline shows: video lanes stack upward (V2 above V1), audio lanes downward (A1 at the top). Clips, transitions and
// links travel with the track (track ids do not change), so Picture masks keep reading the same track.
//
// Fast Cut: the first video track is the main track every attachment hangs on, so it neither moves nor is swapped.
extension Timeline {
    /// Index the track `id` would trade places with when moved `up`, nil when it cannot move that way.
    public func moveTrackNeighbor(of id: Track.ID, up: Bool) -> Int? {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return nil }
        let step = (tracks[i].kind == .video) == up ? 1 : -1
        var j = i + step
        while tracks.indices.contains(j), tracks[j].kind != tracks[i].kind { j += step }
        guard tracks.indices.contains(j) else { return nil }
        if isFastCut, let m = mainTrackIndex, i == m || j == m { return nil }
        return j
    }

    /// Moves the track one place up or down among tracks of its kind. False (nothing changed) when it is at the end.
    @discardableResult
    public mutating func moveTrack(_ id: Track.ID, up: Bool) -> Bool {
        guard let i = tracks.firstIndex(where: { $0.id == id }), let j = moveTrackNeighbor(of: id, up: up) else { return false }
        tracks.swapAt(i, j)
        return true
    }
}
