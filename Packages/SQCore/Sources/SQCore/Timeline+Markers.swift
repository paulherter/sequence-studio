import Foundation

/// Sequence marker operations (Premiere behavior). Markers stay sorted by time.
/// Color, comment and duration setters go through `updateMarker` so they need no extra API
/// once `Marker` carries those fields.
extension Timeline {
    private mutating func sortMarkers() {
        markers.sort { $0.time != $1.time ? $0.time < $1.time : $0.id.uuidString < $1.id.uuidString }
    }

    private func clampedFrame(_ t: Time) -> Time {
        max(.zero, t.snapped(to: frameDuration))
    }

    @discardableResult
    public mutating func addMarker(at time: Time, name: String = "") -> Marker.ID {
        let m = Marker(time: clampedFrame(time), name: name)
        markers.append(m); sortMarkers()
        return m.id
    }

    public mutating func removeMarker(_ id: Marker.ID) { markers.removeAll { $0.id == id } }

    public mutating func moveMarker(_ id: Marker.ID, to time: Time) {
        guard let i = markers.firstIndex(where: { $0.id == id }) else { return }
        markers[i].time = clampedFrame(time); sortMarkers()
    }

    public mutating func renameMarker(_ id: Marker.ID, to name: String) {
        guard let i = markers.firstIndex(where: { $0.id == id }) else { return }
        markers[i].name = name
    }

    /// Generic edit of one marker (comment, color, duration). False if the id is unknown.
    @discardableResult
    public mutating func updateMarker(_ id: Marker.ID, _ body: (inout Marker) -> Void) -> Bool {
        guard let i = markers.firstIndex(where: { $0.id == id }) else { return false }
        body(&markers[i]); sortMarkers()
        return true
    }

    /// M: adds a marker at the playhead; if one already sits on that frame, returns it with
    /// `openEdit == true` (second M opens the edit dialog) and adds nothing.
    public mutating func markAtPlayhead(_ playhead: Time) -> (id: Marker.ID, openEdit: Bool) {
        let frame = clampedFrame(playhead)
        if let m = markers.first(where: { $0.time == frame }) { return (m.id, true) }
        return (addMarker(at: frame), false)
    }

    public func nextMarker(after t: Time) -> Marker? { markers.first { $0.time > t } }
    public func previousMarker(before t: Time) -> Marker? { markers.last { $0.time < t } }

    /// Markers with `range.start <= time < range.end`.
    public func markers(in range: TimeRange) -> [Marker] {
        markers.filter { $0.time >= range.start && $0.time < range.end }
    }

    /// Ripple helper. Insert: `delta > 0`, markers at or after `editPoint` move later.
    /// Delete of [a, b): `editPoint = b`, `delta = a - b`; markers inside the removed span collapse
    /// to `a`, later ones move earlier. INTEGRATION: call from ripple delete / insert / ripple trim
    /// (Timeline.rippleDelete, insert, rippleTrim) with the edit point and the net shift.
    /// Range markers on a delete: both ends map the same way, so a range spanning or overlapping the removed span gets
    /// shorter by the part removed (a range entirely inside it collapses to a point at `a`).
    public mutating func shiftMarkers(from editPoint: Time, by delta: Time) {
        let floor = editPoint + min(delta, .zero)
        func moved(_ t: Time) -> Time { t >= editPoint ? t + delta : (t >= floor ? floor : t) }
        for i in markers.indices {
            let m = markers[i]
            if delta < .zero, m.duration > .zero {
                let s = moved(m.time), e = moved(m.time + m.duration)
                markers[i].time = s
                markers[i].duration = max(e - s, .zero)
            } else if m.time >= floor {
                markers[i].time = moved(m.time)
            }
        }
        sortMarkers()
    }

    /// `shiftMarkers` for many closed spans at once: `f` is their composed point map (`Timeline.RippleMap.map`); a
    /// range marker maps both ends.
    mutating func shiftMarkers(through f: (Time) -> Time) {
        for i in markers.indices {
            let m = markers[i]
            if m.duration > .zero {
                let s = f(m.time), e = f(m.time + m.duration)
                markers[i].time = s
                markers[i].duration = max(e - s, .zero)
            } else {
                markers[i].time = f(m.time)
            }
        }
        sortMarkers()
    }
}
