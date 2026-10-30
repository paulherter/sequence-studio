import Foundation

// Editing clip markers from the timeline (ClipMarkers.swift holds the model). Markers are stored in the clip's source
// time; these helpers take sequence time (what the user points at) and convert with `Clip.sourceTime(at:frameDuration:)`,
// so a marker keeps its source frame through trims and splits.
extension Timeline {
    /// Adds a marker to clip `clipID` at sequence time `time` (snapped to the sequence frame grid). Nil when the clip does not
    /// show markers there: the time is outside the clip, or the clip plays a hold frame or an applied title template.
    @discardableResult
    public mutating func addClipMarker(to clipID: Clip.ID, at time: Time, name: String = "", color: MarkerColor = .green) -> Marker.ID? {
        guard var c = find(clipID)?.clip else { return nil }
        let t = time.snappedDown(frameDuration)
        guard c.timeline.contains(t) else { return nil }
        let m = Marker(time: c.sourceTime(at: t, frameDuration: frameDuration), name: name, color: color)
        c.markers = (c.markers ?? []) + [m]
        guard c.visibleMarkers(frameDuration: frameDuration).contains(where: { $0.id == m.id }) else { return nil }
        guard (try? replaceClip(c)) != nil else { return nil }
        return m.id
    }

    /// Moves a clip marker to sequence time `time` (clamped into the clip, on the frame grid). False when unknown or when the
    /// clip would not show the marker there.
    @discardableResult
    public mutating func moveClipMarker(_ id: Marker.ID, on clipID: Clip.ID, to time: Time) -> Bool {
        guard var c = find(clipID)?.clip, var all = c.markers, let i = all.firstIndex(where: { $0.id == id }),
              c.duration > .zero else { return false }
        let last = max(c.start, (c.timeline.end - frameDuration).snappedDown(frameDuration))
        let t = min(max(time.snappedDown(frameDuration), c.start), last)
        all[i].time = c.sourceTime(at: t, frameDuration: frameDuration)
        c.markers = all
        guard c.visibleMarkers(frameDuration: frameDuration).contains(where: { $0.id == id }),
              (try? replaceClip(c)) != nil else { return false }
        return true
    }

    /// Changes name, color, comment or length of a clip marker. False when unknown.
    @discardableResult
    public mutating func updateClipMarker(_ id: Marker.ID, on clipID: Clip.ID, _ body: (inout Marker) -> Void) -> Bool {
        guard var c = find(clipID)?.clip, var all = c.markers, let i = all.firstIndex(where: { $0.id == id }) else { return false }
        let time = all[i].time
        body(&all[i])
        all[i].time = time                                  // the position has its own call (`moveClipMarker`)
        c.markers = all
        return (try? replaceClip(c)) != nil
    }

    /// Removes a clip marker; the list goes back to nil when it was the last one.
    @discardableResult
    public mutating func removeClipMarker(_ id: Marker.ID, on clipID: Clip.ID) -> Bool {
        guard var c = find(clipID)?.clip, var all = c.markers, all.contains(where: { $0.id == id }) else { return false }
        all.removeAll { $0.id == id }
        c.markers = all.isEmpty ? nil : all
        return (try? replaceClip(c)) != nil
    }

    /// Sequence times of every clip marker shown on the timeline, for snapping (Snap to markers).
    public func clipMarkerTimes() -> [Time] {
        var out: [Time] = []
        for t in tracks {
            for c in t.clips where !(c.markers ?? []).isEmpty {
                out += c.visibleMarkers(frameDuration: frameDuration).map { c.start + $0.time }
            }
        }
        return out
    }
}
