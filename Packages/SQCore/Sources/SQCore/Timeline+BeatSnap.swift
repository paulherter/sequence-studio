import Foundation

/// Which beat markers act as snap targets.
public enum BeatSnapLevel: String, Sendable, Hashable, CaseIterable {
    /// Every beat marker snaps (the default).
    case everyBeat
    /// Only the first beat of each bar (downbeat) snaps.
    case barsOnly
}

extension Timeline {
    /// Beat marker times in order (markers named `beatMarkerName`).
    public var beatMarkerTimes: [Time] {
        markers.filter { $0.name == Self.beatMarkerName }.map(\.time).sorted()
    }

    /// Snap candidates from markers: every non-beat marker always, beat markers by `level`.
    /// shortcut: beat markers carry no bar info, so downbeats are every `beatsPerBar`-th beat marker from the first one;
    /// upgrade by storing the downbeat flag on the marker when Add Beat Markers keeps `BeatGrid.downbeatBeatIndices`.
    public func markerSnapTimes(beatLevel level: BeatSnapLevel, beatsPerBar: Int = 4) -> [Time] {
        let others = markers.filter { $0.name != Self.beatMarkerName }.map(\.time)
        let beats = beatMarkerTimes
        let kept: [Time]
        switch level {
        case .everyBeat: kept = beats
        case .barsOnly:
            let n = max(1, beatsPerBar)
            kept = beats.enumerated().filter { $0.offset % n == 0 }.map(\.element)
        }
        return others + kept
    }

    /// Sets a marker's duration (clamped at 0, frame grid). False if the id is unknown.
    @discardableResult
    public mutating func setMarkerDuration(_ id: Marker.ID, to duration: Time) -> Bool {
        let d = max(.zero, duration.snapped(to: frameDuration))
        return updateMarker(id) { $0.duration = d }
    }
}
