import Foundation
import SQCore
import SQText
import SQTranscribe

/// Which extra section Effect Controls shows above Motion (Premiere: Text for text clips, Audio for audio clips).
public enum ClipSectionMode: Equatable, Sendable {
    case none, text, audio

    public static func resolve(_ clip: Clip?) -> ClipSectionMode {
        guard let c = clip else { return .none }
        if c.generator?.kind == GeneratorRef.text { return .text }
        return c.kind == .audio ? .audio : .none
    }

    public var title: String {
        switch self {
        case .none: ""
        case .text: "Text"
        case .audio: "Audio"
        }
    }
}

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
            return CaptionItem(lines: c.lines, range: r, styleRef: c.styleRef, animationRef: c.animationRef)
        }
        guard let fd = frameDuration else { return items }
        return snapped(items, to: fd)
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

/// Text layer templates offered in the Library (Text Templates): the built-in caption styles as ready-made titles.
public enum TextTemplateCatalog {
    public struct Entry: Identifiable, Hashable, Sendable {
        public var id: String
        public var name: String
        public var template: TextTemplate
    }

    public static let placeholderText = "Your text"

    public static let all: [Entry] = {
        let lib = CaptionPresetLibrary.builtIn
        return lib.styleIDs.map { id in
            let name = id.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
            return Entry(id: id, name: name,
                         template: TextTemplate(name: name, text: placeholderText, style: lib.style(for: id)))
        }
    }()

    public static func entry(id: String) -> Entry? { all.first { $0.id == id } }
}
