import Foundation

/// The playhead keeps the picture it was on when a ripple closes material before it. A closed span is the stretch of
/// the timeline that disappears: everything at or after its end moves left by its duration.
extension Timeline {
    /// The rule. Where the playhead belongs after ripples closed `spans` (in the order the edits ran, each span in the
    /// coordinates the one before left behind). Same point rule as `shiftMarkers`: at or after a span it moves left
    /// by the span, inside it lands on the edit point where the span began, before it stays.
    public static func playheadAfterRipple(_ playhead: Time, closing spans: [TimeRange]) -> Time {
        spans.reduce(playhead) { p, span in
            if span.isEmpty || p < span.start { return p }
            return p >= span.end ? p - span.duration : span.start
        }
    }

    /// Runs `edit` and returns where a playhead at `playhead` belongs afterwards. Every ripple reports the span it
    /// closes to the sequence markers (`closeCaptionSpan`), so a probe marker at the playhead rides along with the edit
    /// and is taken out again: the result follows `playheadAfterRipple` for whatever the edit closed, on whichever path
    /// (ripple delete, close gap, extract, ripple trim, their Fast Cut forms). Only closing moves the playhead: an edit
    /// that pushes material later leaves it where it was. A refused edit throws and changes nothing.
    public mutating func followingRipple(playhead: Time, _ edit: (inout Timeline) throws -> Void) rethrows -> Time {
        var work = self
        let probe = Marker(time: playhead)
        work.markers.insert(probe, at: work.markers.firstIndex { $0.time > playhead } ?? work.markers.count)
        try edit(&work)
        let landed = work.markers.first { $0.id == probe.id }?.time ?? playhead
        work.markers.removeAll { $0.id == probe.id }
        self = work
        return min(landed, playhead)
    }
}
