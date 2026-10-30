import Foundation

// Clip markers (v60): markers that belong to a clip's content, like Premiere's clip markers. Stored in source time
// (`Clip.markers`): a marker names the source frame that starts at its `time`. A trim, slip or split of a clip that plays
// its source range therefore never moves a marker off its frame; both halves of a split keep the list and each shows the
// markers inside its own range.
//
// Where source time does not describe what plays:
// - an applied title template (`playsThroughZones`) plays its content through the zones whatever its source range, so a
//   trim does move the content under the markers: `visibleMarkers` shows none there;
// - a hold frame shows one frame: none;
// - a clip relinked to a still loses its source offset (`Project.adoptProbes`): its markers shift with `source.start`, so
//   they keep their place on the clip.

extension Clip {
    /// The markers the clip shows, at clip-local time on the sequence frame grid, sorted by time. Each is placed on the
    /// timeline frame that shows the marker's source frame, by the frame convention of `sourceTime(at:frameDuration:)` /
    /// `timelineTime(forSource:frameDuration:)`: a reversed clip shows the frame starting at source `s` one frame before
    /// the instant it passes `s`. When the clip skips the marker's frame (fast speed) the marker sits on the frame playing
    /// across it.
    ///
    /// Range: a marker at the played range's start counts, one at its end does not (that frame is not shown). On a speed
    /// track a marker on the hull's end counts when the track passes that instant inside the clip (a turning point).
    /// A speed track that passes a source time more than once shows the marker at every visit: one entry per visit, all
    /// with the marker's `id`.
    ///
    /// `duration` is the marker's length on the clip (source length through a constant speed, snapped to frames); on a
    /// speed track it is kept as the source length.
    public func visibleMarkers(frameDuration fd: Time) -> [Marker] {
        guard let all = markers, !all.isEmpty, holdFrame == nil, !playsThroughZones, duration > .zero else { return [] }
        let lastFrame = max(.zero, (duration - fd).snappedDown(fd))
        func onGrid(_ local: Time) -> Time { min(max(local.snappedDown(fd), .zero), lastFrame) }
        var out: [Marker] = []
        for m in all {
            if let k = speedKeys {
                let hull = k.hull
                guard m.time >= hull.start, m.time <= hull.end else { continue }
                var seen: [Time] = []
                for v in k.localTimes(forSource: m.time) {
                    if m.time == hull.end, !(v > .zero && v < duration) { continue }
                    if v >= duration, !k.isReversed(at: max(.zero, v - fd)) { continue }   // the out point itself is not shown
                    // Ramp visits are solved in Double and rounded to 1/2^20 s: nudge so a frame boundary does not fall back.
                    let exact = v + Time(1, 1 << 19)
                    let early = v - fd
                    let local = onGrid(fd > .zero && early >= .zero && k.isReversed(at: early) ? early + Time(1, 1 << 19) : exact)
                    if seen.contains(local) { continue }
                    seen.append(local)
                    var x = m; x.time = local; x.duration = m.duration.snapped(to: fd)
                    out.append(x)
                }
                continue
            }
            guard m.time >= source.start, m.time < source.end else { continue }
            var x = m
            x.time = onGrid(reversed ? speed.unscale(source.end - m.time) - fd : speed.unscale(m.time - source.start))
            x.duration = speed.unscale(m.duration).snapped(to: fd)
            out.append(x)
        }
        return out.sorted { $0.time < $1.time }
    }
}
