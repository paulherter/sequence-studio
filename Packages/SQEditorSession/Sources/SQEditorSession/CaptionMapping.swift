import SQCore
import SQText
import SQTranscribe

/// Maps captions produced from a transcript (source time of the clip's media) onto the timeline.
public enum CaptionMapping {
    /// Maps source time onto the timeline through the clip's speed and direction and keeps only what lies inside the
    /// clip's source range (cut at its ends). A reversed clip shows the captions' time span mirrored.
    /// With `frameDuration` the ranges are put on the frame grid (nearest frame, at least one frame long): spoken
    /// word times fall between frames, captions must not.
    public static func items(_ captions: [Caption], for clip: Clip, frameDuration: Time? = nil) -> [CaptionItem] {
        let items: [CaptionItem] = captions.compactMap { c in
            guard let s = c.range.intersection(clip.source), !s.isEmpty else { return nil }
            let a = clip.timelineTime(forSource: s.start), b = clip.timelineTime(forSource: s.end)
            let r = TimeRange(start: min(a, b), end: max(a, b))            // reversed or remapped: either order
            guard !r.isEmpty else { return nil }
            return CaptionItem(lines: c.lines, range: r, styleRef: c.styleRef, animationRef: c.animationRef,
                               words: timelineWords(c.words, in: r, clip: clip))
        }
        guard let fd = frameDuration else { return items }
        return snapped(items, to: fd)
    }

    /// The spoken words of a caption on the timeline (karaoke): source times through the clip's speed, clamped into the
    /// caption's range so a caption cut by the clip edge keeps one timed word per word. A reversed clip has no usable
    /// word order, so its captions spread their words instead.
    static func timelineWords(_ words: [CaptionWord], in r: TimeRange, clip: Clip) -> [CaptionWord] {
        guard !clip.reversed else { return [] }
        return words.map { w in
            let a = min(max(clip.timelineTime(forSource: w.range.start), r.start), r.end)
            let b = min(max(clip.timelineTime(forSource: w.range.end), a), r.end)
            return CaptionWord(text: w.text, range: TimeRange(start: a - r.start, end: b - r.start), confidence: w.confidence)   // relative to the caption
        }
    }

    /// Nearest frame for both ends; a caption that collapses gets one frame when the next one leaves room, else it goes.
    /// Sorted, non-overlapping input stays non-overlapping.
    public static func snapped(_ items: [CaptionItem], to fd: Time) -> [CaptionItem] {
        var out: [CaptionItem] = []
        let sorted = items.sorted { $0.range.start < $1.range.start }
        for (i, it) in sorted.enumerated() {
            var s = it.range.start.snapped(to: fd), e = it.range.end.snapped(to: fd)
            if let last = out.last, s < last.range.end { s = last.range.end }
            if e <= s {
                let next = i + 1 < sorted.count ? sorted[i + 1].range.start.snapped(to: fd) : nil
                guard next == nil || next! >= s + fd else { continue }
                e = s + fd
            }
            var c = it
            c.shiftWordOrigin(by: s - it.range.start)   // word times are relative to the start
            c.range = TimeRange(start: s, end: e)
            out.append(c)
        }
        return out
    }
}

extension CaptionMapping {
    /// All clips that play the same media (a cut interview, or the video and audio halves of one recording): the
    /// captions of each clip's part, in time order. Where two clips cover the same time (linked video + audio) the
    /// first one wins, so the result never overlaps.
    public static func items(_ captions: [Caption], forClips clips: [Clip], frameDuration: Time? = nil) -> [CaptionItem] {
        let sorted = clips.sorted { $0.start < $1.start }
        var out: [CaptionItem] = []
        for clip in sorted {
            for item in items(captions, for: clip, frameDuration: frameDuration) where !out.contains(where: { $0.range.overlaps(item.range) }) {
                out.append(item)
            }
        }
        return out.sorted { $0.range.start < $1.range.start }
    }
}
