import Foundation

/// Pause shortening ("Remove Silences"): turns detected pauses into frame-aligned ripple cuts that leave a fixed pad
/// of the pause on each side. A timeline edit; the media is never changed. Always run by an explicit command.
public enum SilenceRemoval {
    /// Cuts for `silences` (timeline time). Each pause loses everything except `padding` at both ends; the cut is
    /// shrunk to whole frames (start rounded up, end rounded down) so no cut lands between frames. Pauses that leave
    /// less than one frame to cut are dropped. Sorted, non-overlapping.
    public static func cuts(silences: [TimeRange], padding: Time, frameDuration: Time) -> [TimeRange] {
        var out: [TimeRange] = []
        for s in silences.sorted(by: { $0.start < $1.start }) {
            let a = ceilFrame(s.start + padding, frameDuration), b = FadeKeys.snapDown(s.end - padding, frameDuration)
            guard b - a >= frameDuration else { continue }
            if let last = out.last, a < last.end { continue }
            out.append(TimeRange(start: a, duration: b - a))
        }
        return out
    }

    private static func ceilFrame(_ t: Time, _ frame: Time) -> Time {
        let n = t.frameIndex(frameDuration: frame)
        let f = frame * n
        return f == t ? f : frame * (n + 1)
    }
}

extension Clip {
    /// Timeline range that plays the source range `r` (through speed and direction), clamped to the clip.
    public func timelineRange(forSource r: TimeRange) -> TimeRange? {
        let a = timelineTime(forSource: r.start), b = timelineTime(forSource: r.end)
        let lo = max(min(a, b), start), hi = min(max(a, b), timeline.end)
        return hi > lo ? TimeRange(start: lo, duration: hi - lo) : nil
    }
}

extension Timeline {
    /// Ripple-deletes every cut on `tracks` (and every sync-locked track, like Extract). All or nothing. Cuts are
    /// processed from the end so earlier ones keep their position. Returns the total time removed.
    @discardableResult
    public mutating func removeCuts(_ cuts: [TimeRange], tracks ids: [Track.ID]) throws -> Time {
        var work = self
        var removed = Time.zero
        for c in cuts.sorted(by: { $0.start > $1.start }) {
            removed = removed + (try work.extract(c, tracks: ids))
        }
        self = work
        return removed
    }
}
