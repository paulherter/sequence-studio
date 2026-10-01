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
    /// Maps source time onto the timeline through the clip's speed and direction and keeps only what lies inside the
    /// clip's source range (cut at its ends). A reversed clip shows the captions' time span mirrored.
    public static func items(_ captions: [Caption], for clip: Clip) -> [CaptionItem] {
        return captions.compactMap { c in
            guard let s = c.range.intersection(clip.source), !s.isEmpty else { return nil }
            let a = clip.timelineTime(forSource: s.start), b = clip.timelineTime(forSource: s.end)
            let r = clip.reversed ? TimeRange(start: b, end: a) : TimeRange(start: a, end: b)
            guard !r.isEmpty else { return nil }
            return CaptionItem(lines: c.lines, range: r, styleRef: c.styleRef, animationRef: c.animationRef)
        }
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
