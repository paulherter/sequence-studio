import Foundation

/// Cut to Beats / Snap to Beats: edits that use the beat markers (`Timeline+BeatMarkers`) as the grid.
extension Timeline {
    /// Beat marker times, sorted and unique.
    public var beatTimes: [Time] {
        Array(Set(markers.lazy.filter { $0.name == Self.beatMarkerName }.map(\.time))).sorted()
    }

    /// Cuts the given clips (and their linked partners' tracks) at every beat marker inside their span. Only the tracks the
    /// clips and their partners sit on are cut; other clips on those tracks outside the span stay whole. Beats on a clip
    /// edge or outside cut nothing. Returns the number of beats that produced a cut (0 leaves the timeline unchanged).
    @discardableResult
    public mutating func cutToBeats(clips ids: Set<Clip.ID>) throws -> Int {
        var span: TimeRange?
        var trackIDs: [Track.ID] = []
        for id in ids {
            for m in try linkedGroup(id) {
                if tracks[m.track].isLocked { throw EditError.trackLocked }
                if !trackIDs.contains(tracks[m.track].id) { trackIDs.append(tracks[m.track].id) }
                if ids.contains(m.clip.id) {
                    span = span.map { TimeRange(start: min($0.start, m.clip.start), end: max($0.end, m.clip.timeline.end)) } ?? m.clip.timeline
                }
            }
        }
        guard let span else { return 0 }
        let beats = beatTimes.filter { $0 > span.start && $0 < span.end }
        var work = self
        var cuts = 0
        for b in beats {
            // Only clips inside the selected span are cut: restrict to tracks, the span check above bounds the beats.
            if try !work.addEdit(at: b, tracks: trackIDs).isEmpty { cuts += 1 }
        }
        if cuts > 0 { self = work }
        return cuts
    }

    /// Moves the tail of each given clip to the nearest beat marker after its head, ripple-trimming (everything after
    /// shifts, so the following cuts keep their place relative to the snapped one). Clips are processed left to right,
    /// each against the timeline as the earlier ripples left it. The beat grid keeps its absolute times: the markers do
    /// not ride the ripple. A tail the media or a neighbor does not let reach the beat moves as far as it can.
    /// Returns the number of clips whose tail moved.
    @discardableResult
    public mutating func snapToBeats(clips ids: [Clip.ID]) throws -> Int {
        let grid = markers.filter { $0.name == Self.beatMarkerName }
        let beats = beatTimes
        guard !beats.isEmpty else { return 0 }
        let order = ids.compactMap { find($0) }.sorted { $0.clip.start < $1.clip.start }.map(\.clip.id)
        var work = self
        var moved = 0
        for id in order {
            guard let c = work.find(id)?.clip else { continue }
            let candidates = beats.filter { $0 >= c.start + frameDuration }
            guard let target = candidates.min(by: { abs(Rational($0 - c.timeline.end).double) < abs(Rational($1 - c.timeline.end).double) }),
                  target != c.timeline.end else { continue }
            let by = try work.magneticRippleTrim(id, edge: .tail, by: target - c.timeline.end)   // Fast Cut: V1 stays gapless
            if by != .zero { moved += 1 }
        }
        guard moved > 0 else { return 0 }
        work.markers.removeAll { $0.name == Self.beatMarkerName }
        work.markers.append(contentsOf: grid)
        self = work
        return moved
    }
}
