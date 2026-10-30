import Foundation

/// Where tracking of a Magic mask is weak (MASK-UX 5.4 "confidence strip"). Nothing is stored for it: the stored matte
/// areas tell. A frame is weak when its matte shrank to a fraction of the typical one (the subject is nearly lost), when
/// the area jumped against the frame before (the follower grabbed another object or let go of part of the subject), or
/// when frames are missing (tracking skipped a stretch). Pure, in source seconds.
public enum MagicTrackHealth {
    public struct Sample: Sendable, Hashable {
        public var pts: Double
        /// Matte coverage of the frame, 0...1.
        public var area: Double
        public init(pts: Double, area: Double) { self.pts = pts; self.area = area }
    }

    public struct Span: Sendable, Hashable {
        public var start: Double, end: Double
        public init(start: Double, end: Double) { self.start = start; self.end = end }
    }

    /// A matte below this share of the median area is weak.
    public static let shrunkBelow = 0.4
    /// A change of area above this share of the previous frame's is weak.
    public static let jumpAbove = 0.6

    /// Weak stretches, merged, sorted. A weak frame covers its own time up to the next frame.
    public static func weakSpans(_ samples: [Sample]) -> [Span] {
        let s = samples.sorted { $0.pts < $1.pts }
        guard s.count >= 3 else { return [] }
        let gaps = zip(s, s.dropFirst()).map { $1.pts - $0.pts }.sorted()
        let spacing = max(gaps[gaps.count / 2], 1e-6)
        let areas = s.map(\.area).sorted()
        let median = areas[areas.count / 2]
        var out: [Span] = []
        func add(_ a: Double, _ b: Double) {
            if let last = out.last, a <= last.end + 1e-9 { out[out.count - 1].end = max(last.end, b) } else { out.append(Span(start: a, end: b)) }
        }
        for i in s.indices {
            let end = i + 1 < s.count ? s[i + 1].pts : s[i].pts + spacing
            if i + 1 < s.count, s[i + 1].pts - s[i].pts > spacing * 1.5 + 1e-6 { add(s[i].pts, s[i + 1].pts) }   // missing frames
            // An empty matte is a frame the subject was not found on: weak whatever the rest of the track looks like.
            var weak = s[i].area < median * shrunkBelow || s[i].area <= 0
            if i > 0, s[i - 1].area > 1e-6, abs(s[i].area - s[i - 1].area) / s[i - 1].area > jumpAbove { weak = true }
            if weak { add(s[i].pts, end) }
        }
        return out
    }

    public static func weakSeconds(_ spans: [Span]) -> Double { spans.reduce(0) { $0 + $1.end - $1.start } }

    /// Start of the first weak span beginning after `t` (the strip's "jump to the next weak frame"), nil past the last.
    public static func next(after t: Double, in spans: [Span]) -> Double? {
        spans.first { $0.start > t + 1e-9 }?.start
    }
}
