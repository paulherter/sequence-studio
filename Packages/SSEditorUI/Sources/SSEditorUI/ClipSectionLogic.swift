import Foundation
import SSCore
import SSText
import SSTranscribe

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
    /// Shifts by `clip.start - clip.source.start` and keeps only what lies inside the clip (cut at its ends).
    public static func items(_ captions: [Caption], for clip: Clip) -> [CaptionItem] {
        let offset = clip.start - clip.source.start
        let bounds = clip.timeline
        return captions.compactMap { c in
            let shifted = TimeRange(start: c.range.start + offset, duration: c.range.duration)
            guard let r = shifted.intersection(bounds), !r.isEmpty else { return nil }
            return CaptionItem(lines: c.lines, range: r, styleRef: c.styleRef, animationRef: c.animationRef)
        }
    }
}

extension CaptionMapping {
    /// All clips that play the same media (a cut interview, or the video and audio halves of one recording): the
    /// captions of each clip's part, in time order. Where two clips cover the same time (linked video + audio) the
    /// first one wins, so the result never overlaps.
    public static func items(_ captions: [Caption], forClips clips: [Clip]) -> [CaptionItem] {
        let sorted = clips.sorted { $0.start < $1.start }
        var out: [CaptionItem] = []
        for clip in sorted {
            for item in items(captions, for: clip) where !out.contains(where: { $0.range.overlaps(item.range) }) {
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
