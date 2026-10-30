import Foundation
import SQCore
import SQText
import SQTranscribe

/// Which content section Controls shows for the selection. Text, Shape, Template and Graphic lead the column (before
/// Transform); Audio closes it. `captions` is not a clip: with no clip selected and a caption track in the sequence the
/// column shows that track's read-only caption list in Audio's place.
public enum ClipSectionMode: Equatable, Sendable {
    case none, text, audio, shape, matte, template, graphic, captions

    /// Whether the section leads the column (content before Transform) or closes it.
    public var leads: Bool { self == .text || self == .shape || self == .matte || self == .template || self == .graphic }

    /// The kind the Controls header names ("Text · 00:00:05:14"); nil = the clip's track kind.
    public var kindName: String? { leads ? title : nil }

    public static func resolve(_ clip: Clip?) -> ClipSectionMode {
        guard let c = clip else { return .none }
        if c.templateSlots != nil, c.sequence != nil { return .template }     // an applied title template (T3)
        if c.generator?.kind == GeneratorRef.text { return .text }
        if c.generator?.kind == GeneratorRef.shape { return .shape }
        if c.isColorMatte { return .matte }                                 // a flat color layer: its Color row
        if c.isGraphics { return .graphic }                                 // G7: a way into the Graphics panel
        return c.kind == .audio ? .audio : .none
    }

    public var title: String {
        switch self {
        case .none: ""
        case .text: "Text"
        case .audio: "Audio"
        case .shape: "Shape"
        case .matte: "Color Matte"
        case .template: "Template"
        case .graphic: "Graphic"
        case .captions: "All Captions"
        }
    }

    /// "3 layers" for the Graphic section and the Graphics panel header.
    public static func layerSummary(_ clip: Clip) -> String {
        let n = clip.graphics?.layers.count ?? 0
        return n == 1 ? "1 layer" : "\(n) layers"
    }
}

/// What the Graphics panel shows when the selection is not a graphics clip (audit G7).
public enum GraphicsEmptyState: Equatable, Sendable {
    /// A text or shape clip: its look is edited in Controls.
    case editedInControls
    /// Anything else (nothing, several clips, footage): a hint and New Graphics Clip.
    case noGraphic

    /// nil for a graphics clip (the panel shows its layers).
    public static func resolve(_ clip: Clip?) -> GraphicsEmptyState? {
        guard let c = clip else { return .noGraphic }
        if c.isGraphics { return nil }
        let k = c.generator?.kind
        return k == GeneratorRef.text || k == GeneratorRef.shape ? .editedInControls : .noGraphic
    }

    public var title: String {
        switch self {
        case .editedInControls: "Edited in Controls"
        case .noGraphic: "No graphics clip selected"
        }
    }

    public var hint: String {
        switch self {
        case .editedInControls: "This text or shape clip is edited in Controls. Make it a graphic to add more layers."
        case .noGraphic: "Select a graphics clip in the timeline to edit its layers, or make a new one."
        }
    }
}

/// Text layer templates offered in the Library (Text Templates): the built-in caption styles as ready-made titles,
/// plus the H1 additions "Title 2-Tier" (small line over a big line in one text clip) and the CTA end card (a graphic).
public enum TextTemplateCatalog {
    public struct Entry: Identifiable, Hashable, Sendable {
        public var id: String
        public var name: String
        public var template: TextTemplate
        /// The CTA end card: placed as a Graphics clip (`EditorSession.addCTAEndCard`), `template` is only a placeholder.
        public var isCTA = false
        /// CREATOR 7: a built-in sticker or lower third (`GraphicPresetCatalog` id), placed as a Graphics clip (`EditorSession.addGraphicPreset`).
        public var graphicPresetID: String?
        /// Shown in the Library's Kind column.
        public var kindLabel = "Text Template"
    }

    public static let placeholderText = "Your text"
    public static let title2TierID = "title-2-tier"

    /// "TOP LINE" small, tracked caps over a big heavy second line in the same text clip (`TextStyle.secondLine`, which may
    /// use another font): the paragraph break is the line split.
    public static var title2Tier: TextTemplate {
        let shadow = TextShadow(color: RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.6), angle: 135, distance: 4, blur: 10)
        let big = TextLineStyle(fontName: TextStyle.defaultFontName, size: 150, weight: .black, color: .white)
        let style = TextStyle(fontName: TextStyle.defaultFontName, size: 52, weight: .bold, color: .white, shadow: shadow, alignment: .center,
                              lineSpacing: 0, tracking: 8, allCaps: true, secondLine: big)
        return TextTemplate(name: "Title 2-Tier", text: "Pixel\n9 Pro", style: style)
    }

    /// Read from the live caption library each time, so the kit caption style and token values are current.
    public static var all: [Entry] {
        let lib = CaptionPresetLibrary.builtIn
        // The generated caption looks (`GeneratedCaptionLooks`) live in the Captions look gallery, not in this Library list.
        let captions = lib.styleIDs.filter { !$0.hasPrefix(GeneratedCaptionLooks.stylePrefix) }.map { id in
            let name = id.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
            return Entry(id: id, name: name,
                         template: TextTemplate(name: name, text: placeholderText, style: lib.style(for: id)))
        }
        let cta = Entry(id: CTAEndCard.id, name: CTAEndCard.name,
                        template: TextTemplate(name: CTAEndCard.name, text: CTAEndCard.label, style: TextStyle()), isCTA: true)
        let graphics = GraphicPresetCatalog.all.map { g -> Entry in
            let label = g.category.label
            let name = "\(g.name) \(label)"
            return Entry(id: g.id, name: name, template: TextTemplate(name: name, text: label, style: TextStyle()),
                         graphicPresetID: g.id, kindLabel: label)
        }
        return captions + [Entry(id: title2TierID, name: "Title 2-Tier", template: title2Tier), cta] + graphics
    }

    public static func entry(id: String) -> Entry? { all.first { $0.id == id } }
}
