import Foundation

/// Beat markers (Add Beat Markers): ordinary sequence markers named "Beat", so snapping, jumping and the marker list
/// treat them like any other. A re-run replaces the beat markers inside the range and leaves everything else alone.
extension Timeline {
    public static let beatMarkerName = "Beat"

    /// Replaces the beat markers inside `range` (timeline time) with markers at `times`. Times outside the range are
    /// dropped; times are snapped to frames, and a frame that already holds another marker gets none.
    /// Returns the number of markers added.
    @discardableResult
    public mutating func replaceBeatMarkers(in range: TimeRange, with times: [Time]) -> Int {
        markers.removeAll { $0.name == Self.beatMarkerName && range.contains($0.time) }
        var taken = Set(markers.map(\.time))
        var added = 0
        for t in times.sorted() where range.contains(t) {
            let frame = max(.zero, t.snapped(to: frameDuration))
            guard !taken.contains(frame) else { continue }
            taken.insert(frame)
            let id = addMarker(at: frame, name: Self.beatMarkerName)
            _ = updateMarker(id) { $0.color = .cyan }
            added += 1
        }
        return added
    }
}
