import Foundation
import SQCore

/// Portable part (the drawing is in TrackConfidenceStrip.swift, Mac only).
/// MASK-UX 5.4: amber marks along the bottom of a clip with a tracked Magic mask where tracking is weak
/// (`MagicTrackHealth`); nothing where it holds. Tokens only.
public enum TrackConfidenceStrip {
    public static let height: CGFloat = 3

    /// Column ranges (0...width, in clip-local px) whose source time lies in a weak span. `source` maps the clip's
    /// fraction 0...1 to source seconds (through speed and reverse), sampled every `step` px.
    nonisolated public static func weakRanges(width: CGFloat, step: CGFloat, source: (Double) -> Double,
                                              spans: [MagicTrackHealth.Span]) -> [ClosedRange<CGFloat>] {
        guard width > 0, step > 0, !spans.isEmpty else { return [] }
        var out: [ClosedRange<CGFloat>] = []
        var x: CGFloat = 0
        while x < width {
            let t = source(Double(min(x + step / 2, width) / width))
            if spans.contains(where: { t >= $0.start && t <= $0.end }) {
                let hi = min(x + step, width)
                if let last = out.last, last.upperBound >= x - 1e-6 { out[out.count - 1] = last.lowerBound...hi } else { out.append(x...hi) }
            }
            x += step
        }
        return out
    }

    /// Click band of the strip: its height plus 3 px of slack above, so the 3 px strip is hittable.
    nonisolated public static func hitBand(clipRect: CGRect) -> CGRect {
        CGRect(x: clipRect.minX, y: clipRect.maxY - height - 3, width: clipRect.width, height: height + 3)
    }

    /// Where a click on the strip at timeline time `t` jumps the playhead: the start (on the timeline) of the weak stretch
    /// under it, clamped into the clip. nil when the click is not on a weak stretch.
    nonisolated public static func jumpTarget(clip: Clip, spans: [MagicTrackHealth.Span], at t: Time, frameDuration: Time) -> Time? {
        let s = clip.sourceTime(at: t, frameDuration: frameDuration)
        let sec = Double(s.value) / Double(s.timescale)
        guard let span = spans.first(where: { sec >= $0.start && sec <= $0.end }) else { return nil }
        func at(_ v: Double) -> Time {
            clip.timelineTime(forSource: Time(Int64((v * 600).rounded()), 600), frameDuration: frameDuration)
        }
        let early = min(at(span.start), at(span.end))
        return min(max(early, clip.timeline.start), clip.timeline.end - frameDuration)
    }

    /// Timeline times where the clip's weak stretches begin (`MagicTrackHealth.weakStarts`, shared with the shared window).
    nonisolated public static func weakStarts(clip: Clip, spans: [MagicTrackHealth.Span], frameDuration: Time) -> [Time] {
        MagicTrackHealth.weakStarts(clip: clip, spans: spans, frameDuration: frameDuration)
    }

    /// "Go to Next Weak Tracking" (`MagicTrackHealth.nextWeakStart`).
    nonisolated public static func nextWeakStart(after t: Time, clips: [Clip], spans: (Clip) -> [MagicTrackHealth.Span]?,
                                                 frameDuration: Time) -> Time? {
        MagicTrackHealth.nextWeakStart(after: t, clips: clips, spans: spans, frameDuration: frameDuration)
    }

    /// Columns (clip-local px) where a weak stretch begins in clip order: the amber "tracking lost here" markers.
    nonisolated public static func markerColumns(width: CGFloat, step: CGFloat, source: (Double) -> Double,
                                                 spans: [MagicTrackHealth.Span]) -> [CGFloat] {
        weakRanges(width: width, step: step, source: source, spans: spans).map(\.lowerBound)
    }
}
