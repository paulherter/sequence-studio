import Foundation

/// Weak tracking on the timeline (the confidence strip and "Go to Next Weak Tracking"): `MagicTrackHealth`'s source-time
/// spans mapped through a clip's speed, direction and trim. Pure; the AppKit strip and the shared window both use it.
extension MagicTrackHealth {
    /// Timeline times where the clip's weak stretches begin (earlier timeline edge, so reversed clips work), clamped into
    /// the clip, sorted. Stretches outside the clip's source range are left out.
    public static func weakStarts(clip: Clip, spans: [Span], frameDuration: Time) -> [Time] {
        let lo = Double(clip.source.start.value) / Double(clip.source.start.timescale)
        let hi = Double(clip.source.end.value) / Double(clip.source.end.timescale)
        func at(_ v: Double) -> Time {
            clip.timelineTime(forSource: Time(Int64((v * 600).rounded()), 600), frameDuration: frameDuration)
        }
        let last = clip.timeline.end - frameDuration
        return spans.filter { $0.end > lo && $0.start < hi }.map { span in
            let a = at(min(max(span.start, lo), hi)), b = at(min(max(span.end, lo), hi))
            return min(max(min(a, b), clip.timeline.start), last)
        }.sorted()
    }

    /// "Go to Next Weak Tracking": the earliest weak-stretch start after `t` over `clips`. `spans` gives each clip's weak
    /// stretches, nil for clips without a tracked Magic mask.
    public static func nextWeakStart(after t: Time, clips: [Clip], spans: (Clip) -> [Span]?, frameDuration: Time) -> Time? {
        clips.compactMap { c in spans(c).flatMap { weakStarts(clip: c, spans: $0, frameDuration: frameDuration).first { $0 > t } } }.min()
    }
}
