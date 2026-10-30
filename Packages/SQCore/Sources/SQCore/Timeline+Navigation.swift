import Foundation

/// Selection navigation and marker clearing used by Select Next/Previous Clip, Go to Selected Clip Start/End,
/// Clear Marker and Clear All Markers.
extension Timeline {
    /// The clip after (or before) `id` on the same track; nil at the end of the track or for an unknown id.
    public func neighbourClip(of id: Clip.ID, forward: Bool) -> Clip.ID? {
        for track in tracks {
            guard let i = track.clips.firstIndex(where: { $0.id == id }) else { continue }
            let j = forward ? i + 1 : i - 1
            return track.clips.indices.contains(j) ? track.clips[j].id : nil
        }
        return nil
    }

    /// Smallest range covering the timeline spans of the given clips; nil when none of them exists.
    public func extent(of ids: Set<Clip.ID>) -> TimeRange? {
        let spans = tracks.flatMap(\.clips).filter { ids.contains($0.id) }.map(\.timeline)
        guard let lo = spans.map(\.start).min(), let hi = spans.map(\.end).max() else { return nil }
        return TimeRange(start: lo, end: hi)
    }

    /// Removes the marker on the frame of `time` (Premiere's Clear Selected Marker acts on the marker at the playhead).
    @discardableResult
    public mutating func clearMarker(at time: Time) -> Marker.ID? {
        let frame = max(.zero, time.snapped(to: frameDuration))
        guard let m = markers.first(where: { $0.time == frame }) else { return nil }
        markers.removeAll { $0.id == m.id }
        return m.id
    }

    /// Removes every sequence marker; returns how many there were.
    @discardableResult
    public mutating func clearAllMarkers() -> Int {
        let n = markers.count
        markers.removeAll()
        return n
    }
}
