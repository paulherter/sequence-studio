import Foundation
import SQCore
import SQEditorSession
import SQLibrary
import SQText

/// One pickable text or graphic template of the Text panel's Templates tab: a built-in (`TextTemplateCatalog`) or a
/// template the user saved to the Library (text template, title block, multi-layer title template).
public struct TextTemplateTile: Identifiable, Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case builtIn(String)
        case user(UUID, PresetKind)
    }
    /// The text a tile shows when the template has none (`TextPresetPreview.sampleText` on the Mac).
    public static let sampleText = "Text"

    public var source: Source
    public var name: String
    /// Drawn with the real text renderer when there is no saved picture.
    public var style: TextStyle?
    public var sampleText: String
    /// PNG of a saved multi-layer template.
    public var thumbnail: Data?

    public var id: String {
        switch source {
        case .builtIn(let id): "builtin:\(id)"
        case .user(let id, _): "user:\(id.uuidString)"
        }
    }

    /// The Library's text-like items in the order the tab shows them: the user's own first (they made them for reuse),
    /// then the built-ins.
    public static func tiles(presets: [PresetItem], builtIns: [TextTemplateCatalog.Entry]) -> [TextTemplateTile] {
        let own = presets.compactMap { p -> TextTemplateTile? in
            switch p.kind {
            case .textTemplate, .animatedTextTemplate:
                let t = try? TextTemplate.decode(from: p.payload)
                let text = (t?.text.isEmpty ?? true) ? sampleText : (t?.text ?? "")
                return TextTemplateTile(source: .user(p.id, p.kind), name: p.name, style: t?.style, sampleText: text)
            case .titleTemplate:
                let png = (try? TitleTemplatePreset(preset: p))?.thumbnail
                return TextTemplateTile(source: .user(p.id, p.kind), name: p.name, style: nil, sampleText: p.name, thumbnail: png)
            case .titleBlock:
                return TextTemplateTile(source: .user(p.id, p.kind), name: p.name, style: nil, sampleText: p.name)
            default: return nil
            }
        }
        let built = builtIns.map { e in
            TextTemplateTile(source: .builtIn(e.id), name: e.name, style: e.graphicPresetID == nil && !e.isCTA ? e.template.style : nil,
                             sampleText: e.template.text.isEmpty ? sampleText : e.template.text)
        }
        return own + built
    }

    /// The tiles whose name contains `query` (case-insensitive); all of them for an empty query.
    public static func filter(_ tiles: [TextTemplateTile], query: String) -> [TextTemplateTile] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? tiles : tiles.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    /// The Library's use counter key of the tile (`PresetKey`).
    public var presetKey: String {
        switch source {
        case .builtIn(let id): PresetKey.builtIn(id)
        case .user(let id, _): PresetKey.user(id)
        }
    }
}

/// Placing a picked template at the playhead: the Mac `EditorPanels.placeTextTemplate`, `insertTitleBlock` and
/// `insertTitleTemplate`, shared by the Mac host and the Windows shell.
@MainActor
public enum TextTemplatePlacement {
    /// Places `tile` (`presets` = the Library's items, for a saved one). Returns the status line, nil when there is none.
    @discardableResult
    public static func place(_ tile: TextTemplateTile, presets: [PresetItem], session: EditorSession) -> String? {
        switch tile.source {
        case .builtIn(let id):
            guard let entry = TextTemplateCatalog.entry(id: id) else { return nil }
            if entry.isCTA { session.addCTAEndCard(); return nil }
            if let g = entry.graphicPresetID { session.addGraphicPreset(g); return nil }
            session.addTextClip(template: entry.template)
            return nil
        case .user(let id, let kind):
            guard let item = presets.first(where: { $0.id == id }) else { return nil }
            if kind == .titleBlock || kind == .titleTemplate { return insertTitle(item, at: nil, session: session) }
            guard let template = try? TextTemplate.decode(from: item.payload) else { return SQL10n.string("The template could not be read.") }
            session.addTextClip(template: template)
            return nil
        }
    }

    /// A saved title block or multi-layer title template at `time` (nil = the playhead); returns the status line.
    public static func insertTitle(_ item: PresetItem, at time: Time?, session: EditorSession) -> String {
        if item.kind == .titleTemplate {
            guard let preset = try? TitleTemplatePreset(preset: item) else { return SQL10n.string("The template could not be read.") }
            session.stopPlayback()
            guard session.insertTitleTemplate(preset.template, at: time) != nil else {
                return session.lastError ?? SQL10n.string("The template could not be placed.")
            }
            session.seek(to: time ?? session.playhead)
            return SQL10n.string("Template placed. Edit its text in Controls.")
        }
        guard let block = try? TitleBlock(preset: item) else { return SQL10n.string("The title block could not be read.") }
        session.stopPlayback()
        guard !session.insertTitleBlock(block, at: time).isEmpty else {
            return session.lastError ?? SQL10n.string("The title block could not be placed.")
        }
        session.seek(to: time ?? session.playhead)
        return SQL10n.string("Title block placed. Double-click a line to type.")
    }
}
