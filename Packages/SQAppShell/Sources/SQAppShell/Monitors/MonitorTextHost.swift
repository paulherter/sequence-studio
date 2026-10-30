import Foundation
import SQCore
import SQDrawKit
import SQDrawMonitor
import SQEditorSession
import SQInspectorUI
import SQText

/// The Program monitor's text work in the shared shell (App/Sources/EditorPanels.swift `typeToolAct`, `createText`,
/// `beginGraphicTextEditing`, `pickGraphicText`, `beginTextEditing` translated): the Type tool, double-click editing,
/// the click that picks a graphic's text layer and the on-canvas text field (`MonitorTextField`). Typing goes to the
/// layer at once; a new text left empty leaves no undo trace, a new one with text is one "Add Text" step. A Type tool
/// click on existing text opens it with the caret at the clicked character (the portable raster's caret map), a
/// double-click with the caret at the end (MonitorTextInteraction `caretAtClick`).
@MainActor
public final class MonitorTextHost {
    private enum Editing {
        case graphic(layer: UUID, clip: Clip.ID, isNew: Bool, depth: Int)
        case clip(Clip.ID, template: TextTemplate, animations: AnimationSet?, isNew: Bool, depth: Int, first: Bool)
        /// A caption opened by a double-click on its text (EditorPanels `captionEditing`): typing is one undo step.
        case caption(CaptionItem.ID, first: Bool)
    }

    private let session: EditorSession
    private unowned let panel: MonitorPanel
    /// The Graphics panel's editor (lazy in the app: asked for on use).
    public var graphics: () -> GraphicsEditor? = { nil }
    private var editing: Editing?
    /// The edited text's style and box (the caret map lays the text out with them) and the last map made.
    private var caretStyle: (style: TextStyle, box: TextBox?)?
    private var caretCache: (text: String, style: TextStyle, box: TextBox?, map: MonitorTextField.Carets?)?

    init(session: EditorSession, panel: MonitorPanel) {
        self.session = session
        self.panel = panel
        panel.onTypeClick = { [weak self] p in self?.typeToolAct(at: p, box: nil) }
        panel.onTypeBox = { [weak self] c, s in self?.typeToolAct(at: c, box: TextBox(width: s.x, height: s.y)) }
        panel.onTextDoubleClick = { [weak self] p in self?.doubleClick(at: p) }
        let f = panel.textField
        f.onEdited = { [weak self] in self?.edited($0) }
        f.onEnded = { [weak self] in self?.ended($0) }
        f.onStyleToggle = { [weak self] in self?.toggleStyle($0) }
        f.caretSource = { [weak self] in self?.carets(for: $0) }
    }

    /// The caret map of `text` in the edited style, layer px from the text frame's top-left (cached per text and style).
    private func carets(for text: String) -> MonitorTextField.Carets? {
        guard let cs = caretStyle else { return nil }
        if let c = caretCache, c.text == text, c.style == cs.style, c.box == cs.box { return c.map }
        let map = PortableTextRenderer.caretMap(text: text, style: cs.style, maxWidth: cs.box?.width, boxHeight: cs.box?.height)
            .map { m in
                MonitorTextField.Carets(lines: m.lines.map { .init(top: CGFloat($0.top), height: CGFloat($0.height)) },
                                        carets: m.carets.map { .init(line: $0.line, x: CGFloat($0.x)) })
            }
        caretCache = (text, cs.style, cs.box, map)
        return map
    }

    public var isEditing: Bool { panel.textField.isEditing }

    // MARK: Type tool

    /// `GraphicsEditor.typeToolOutcome` for a click (`box` nil) or a drag at `position` (sequence px).
    private func typeToolAct(at position: Vec2, box: TextBox?) {
        guard let g = graphics() else { return }
        // Existing text of a Graphic that is not selected: select that Graphic, the click then edits the layer.
        selectGraphic(ofTextAt: position, g)
        // No Graphic under the playhead selected and no text under the pointer: the targeted Graphic takes the text.
        let active = g.clip.map { $0.timeline.contains(session.playhead) } == true
        if !active, textClip(at: position) == nil { g.adoptCreateTarget() }
        let hit = textClip(at: position)
        var pointText = false
        if let hit, let c = session.activeTimeline?.tracks.lazy.flatMap(\.clips).first(where: { $0.id == hit }),
           let ref = c.generator, let (t, _) = try? TextGenerator.decode(ref) { pointText = t.box == nil }
        switch g.typeToolOutcome(at: position, box: box, textClipHit: hit, hitIsPointText: pointText) {
        case .editLayer(let id):
            g.select([id])
            beginGraphic(id, g, isNew: false, depth: 0, selectAll: false, caretAt: position)
        case .addLayer(let at, let areaBox):
            session.stopPlayback()
            let depth = session.undoDepth
            guard let id = g.addText(at: at, box: areaBox) else { return }
            beginGraphic(id, g, isNew: true, depth: depth, selectAll: true)
        case .editTextClip(let id):
            session.stopPlayback()
            session.select(clips: [id])
            beginClip(id, isNew: false, depth: 0, caretAt: position)
        case .newGraphic(_, let b): createText(at: position, box: b, g)
        }
    }

    /// Type tool on empty canvas: a new Graphic clip with one text layer, typed at once (one "Add Text" step).
    private func createText(at position: Vec2, box: TextBox?, _ g: GraphicsEditor) {
        session.stopPlayback()
        let depth = session.undoDepth
        // Never over footage: with no free video track above the picture a new track goes on top (same undo step).
        let seconds = Int64(AppSettings.load().defaultTextSeconds)
        guard session.addGraphicsClip(duration: Time(seconds, 1), neverOverwrite: true) != nil else { return }
        g.sync()
        guard let map = g.mapping, let id = g.addText(at: map.canvasPoint(fromSequence: position), box: box.map {
            let d = map.canvasDelta(fromSequence: Vec2($0.width, $0.height)); return TextBox(width: abs(d.x), height: abs(d.y))
        }) else {
            session.rewindUndo(toDepth: depth); g.sync(); return
        }
        session.seek(to: session.playhead)   // an empty sequence clamped the engine to 0: show the new text now
        beginGraphic(id, g, isNew: true, depth: depth, selectAll: true)
    }

    /// Select tool double-click on the picture: edits the graphic text layer or the text clip under the pointer.
    private func doubleClick(at position: Vec2) {
        guard !isEditing else { return }
        if let g = graphics(), let hit = selectGraphic(ofTextAt: position, g), g.clip?.id == hit.clip {
            g.select([hit.layer])
            beginGraphic(hit.layer, g, isNew: false, depth: 0, selectAll: false)
        } else if let id = textClip(at: position) {
            session.select(clips: [id])
            beginClip(id, isNew: false, depth: 0)
        }
    }

    /// Double-click on a caption's text in the monitor (EditorPanels.beginCaptionEditing): the field opens over it.
    func beginCaptionEditing(at position: Vec2) {
        guard !isEditing, let tl = session.displayTimeline,
              let id = CaptionMonitorHit.caption(at: position, in: tl, time: session.playhead,
                                                 library: CaptionLookRegistry.shared.library(for: session.project)),
              let item = session.captionItem(id) else { return }
        session.stopPlayback()
        session.select(clips: [], captions: [id])
        let e = CaptionMonitorHit.editTarget(for: item, canvas: tl.format, library: CaptionLookRegistry.shared.library(for: session.project))
        editing = .caption(id, first: true)
        let f = panel.textField
        f.sequenceSize = CGSize(width: tl.format.displayWidth, height: tl.format.height)
        captionStyle(e.style, e.box)
        f.begin(text: item.lines.joined(separator: "\n"), target: e.target, selectAll: false)
    }

    private func captionStyle(_ s: TextStyle, _ box: TextBox) {
        let f = panel.textField
        f.fontSize = s.size
        f.isBox = true
        f.lineSpacing = s.lineSpacing
        f.alignment = switch s.alignment { case .left: 0; case .center: 0.5; case .right: 1 }
        caretStyle = (s, box)
    }

    /// Select tool click: a graphic's text layer above the clip `pickClip` found (or where nothing else is) selects that
    /// graphic and the layer. True when it did (EditorPanels.pickGraphicText).
    func pickGraphicText(at p: Vec2, above trackIndex: Int?) -> Bool {
        // shortcut: the layer hit is the topmost over all tracks, not the topmost on a targeted track (as on the Mac).
        guard let g = graphics(), let hit = g.textLayerHit(atSequence: p), let tl = session.displayTimeline,
              TextHitTest.hitWins(hit.trackIndex, over: trackIndex, tracks: tl.tracks) else { return false }
        session.select(clips: [hit.clip])
        g.sync()
        g.select([hit.layer])
        return true
    }

    @discardableResult
    private func selectGraphic(ofTextAt position: Vec2, _ g: GraphicsEditor) -> GraphicsEditor.TextLayerHit? {
        guard let hit = g.textLayerHit(atSequence: position) else { return nil }
        if g.clip?.id != hit.clip { session.select(clips: [hit.clip]); g.sync() }
        return hit
    }

    private func textClip(at p: Vec2) -> Clip.ID? {
        guard let tl = session.displayTimeline else { return nil }
        return TextHitTest.topmostTextClip(at: p, in: tl, project: session.project, time: session.playhead)
    }

    // MARK: The field

    private func beginGraphic(_ id: UUID, _ g: GraphicsEditor, isNew: Bool, depth: Int, selectAll: Bool, caretAt: Vec2? = nil) {
        g.select([id])
        guard let clip = g.clip, let target = g.textEditTarget(for: id), let template = g.textTemplate else { return }
        session.stopPlayback()
        g.beginGesture()
        editing = .graphic(layer: id, clip: clip.id, isNew: isNew, depth: depth)
        open(template, target: target, selectAll: selectAll, caretAt: caretAt)
    }

    private func beginClip(_ id: Clip.ID, isNew: Bool, depth: Int, caretAt: Vec2? = nil) {
        guard let clip = session.displayedSelectedClip, clip.id == id, let ref = clip.generator,
              let (template, animations) = try? TextGenerator.decode(ref), let target = clipTarget(clip) else { return }
        session.stopPlayback()
        editing = .clip(id, template: template, animations: animations, isNew: isNew, depth: depth, first: true)
        open(template, target: target, selectAll: false, caretAt: caretAt)
    }

    private func clipTarget(_ clip: Clip) -> OverlayTarget? {
        guard let tl = session.displayTimeline else { return nil }
        return OverlayTarget.make(clip: clip, project: session.project, timeline: tl, at: session.playhead,
                                  variant: session.activeVariantID)
    }

    private func open(_ template: TextTemplate, target: OverlayTarget, selectAll: Bool, caretAt: Vec2?) {
        let f = panel.textField
        if let tl = session.displayTimeline { f.sequenceSize = CGSize(width: tl.format.displayWidth, height: tl.format.height) }
        style(template)
        f.begin(text: template.text, target: target, selectAll: selectAll, caretAt: caretAt)
    }

    private func style(_ t: TextTemplate) {
        let f = panel.textField
        f.fontSize = t.style.size
        f.isBox = t.box != nil
        f.lineSpacing = t.style.lineSpacing
        f.alignment = switch t.style.alignment { case .left: 0; case .center: 0.5; case .right: 1 }
        caretStyle = (t.style, t.box)
    }

    private func edited(_ text: String) {
        switch editing {
        case .graphic(let layer, let clip, _, _):
            guard let g = graphics(), g.isEditingValid(layer: layer, clip: clip) else { panel.textField.end(); return }
            g.updateText("Edit Text") { $0.text = text }
        case .clip(let id, var template, let animations, let isNew, let depth, let first):
            template.text = text
            session.updateTextClip(id, template: template, animations: animations, continuesGesture: !first)
            editing = .clip(id, template: template, animations: animations, isNew: isNew, depth: depth, first: false)
        case .caption(let id, let first):
            _ = session.setCaptionText(id, text, continuesGesture: !first)
            editing = .caption(id, first: false)
        case nil: break
        }
    }

    private func ended(_ text: String) {
        let e = editing
        editing = nil
        caretStyle = nil
        caretCache = nil
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch e {
        case .graphic(let layer, let clip, let isNew, let depth):
            guard let g = graphics() else { return }
            g.endGesture()
            guard isNew, g.isEditingValid(layer: layer, clip: clip) else { return }
            if empty { g.discardNewLayer(rewindingTo: depth) }      // an empty new layer leaves no trace
            else { session.foldUndo(fromDepth: depth, name: "Add Text") }
        case .clip(let id, _, _, let isNew, let depth, _):
            guard isNew else { return }
            if empty { _ = session.discardTextClip(id, rewindingTo: depth) }
            else { session.foldUndo(fromDepth: depth, name: "Add Text") }
        case .caption, nil: break
        }
    }

    /// Ctrl+B / Ctrl+I while editing: bold between Bold and Regular, italic on and off, for the whole text.
    private func toggleStyle(_ t: MonitorTextField.StyleToggle) {
        func flip(_ s: inout TextStyle) {
            switch t {
            case .bold: s.weight = s.weight >= .bold ? .regular : .bold
            case .italic: s.italic.toggle()
            }
        }
        switch editing {
        case .graphic(let layer, let clip, _, _):
            guard let g = graphics(), g.isEditingValid(layer: layer, clip: clip) else { return }
            g.updateText(t == .bold ? "Bold" : "Italic") { flip(&$0.style) }
        case .clip(let id, var template, let animations, let isNew, let depth, let first):
            flip(&template.style)
            session.updateTextClip(id, template: template, animations: animations, continuesGesture: !first)
            editing = .clip(id, template: template, animations: animations, isNew: isNew, depth: depth, first: false)
        case .caption, nil: break      // a caption's look is its style preset (Captions panel), not the field
        }
    }

    /// Per frame while editing: the field follows the layer (typing grows it, the playhead moves it); a layer that is
    /// gone (undo, another selection) ends the edit.
    func sync() {
        guard isEditing else { return }
        switch editing {
        case .graphic(let layer, let clip, _, _):
            guard let g = graphics(), g.isEditingValid(layer: layer, clip: clip),
                  let target = g.textEditTarget(for: layer) else { panel.textField.end(); return }
            if let t = g.textTemplate { style(t) }
            panel.textField.retarget(target)
        case .clip(let id, let template, _, _, _, _):
            guard let clip = session.displayedSelectedClip, clip.id == id, let target = clipTarget(clip) else {
                panel.textField.end(); return
            }
            style(template)
            panel.textField.retarget(target)
        case .caption(let id, _):
            guard let item = session.captionItem(id), let tl = session.displayTimeline else { panel.textField.end(); return }
            let e = CaptionMonitorHit.editTarget(for: item, canvas: tl.format, library: CaptionLookRegistry.shared.library(for: session.project))
            captionStyle(e.style, e.box)
            panel.textField.retarget(e.target)
        case nil: panel.textField.end()
        }
    }

    /// A press outside the monitor ends the edit (the Mac field loses focus).
    func pressOutside() { if isEditing { panel.textField.end() } }
}
