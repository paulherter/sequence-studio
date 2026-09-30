import Foundation
import SSCore
import SSText
import SSTranscribe

/// Which inspector the Properties panel shows for the current selection (docs/UX.md: Properties).
public enum PropertiesMode: Equatable, Sendable {
    case none, text, audio, captions, clip

    /// Caption selection wins, then a single clip by kind. Several clips: no inspector.
    public static func resolve(selectedClip: Clip?, captionSelectionCount: Int) -> PropertiesMode {
        if captionSelectionCount > 0 { return .captions }
        guard let c = selectedClip else { return .none }
        if c.generator?.kind == GeneratorRef.text { return .text }
        return c.kind == .audio ? .audio : .clip
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

/// Text layer templates offered in the Text panel: the built-in caption styles as ready-made titles.
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
