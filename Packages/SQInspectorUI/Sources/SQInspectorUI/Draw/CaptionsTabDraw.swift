import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import SQCore
import SQDrawKit
import SQEditorSession
import SQText
import SQTranscribe
import SQUIKit

/// The Captions tab of the Captions panel on the shared toolkit: `CaptionsTabView` translated. Find / Replace With /
/// Replace All / Match Case, the captions of the sequence as a list (start time, text; a click selects and seeks,
/// Command and Shift extend, a double-click or Return types into the caption: one undo step per Return), the row
/// context menu (split, merge, look, tidy, translate, add, new track, import, export, delete), and the footer with the
/// caption count and Create Captions…. Everything edits through `EditorSession` as on the Mac.
/// Coordinates: points, y down, (0, 0) = the tab's top-left.
@MainActor public final class CaptionsTabDraw {
    public let session: EditorSession
    public var theme = DrawTheme()
    public var size = CGSize(width: 320, height: 400)
    public var clock: @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime }
    public var onMenu: (@MainActor (_ items: [SQMenuItem], _ anchor: CGRect) -> Void)?
    public var onSeek: (@MainActor (Time) -> Void)?
    public var onStatus: (@MainActor (String) -> Void)?
    /// Create Captions… (the host's dialog over `CaptionsPanelModel`); nil = no transcript, the button is dimmed.
    public var onCreateCaptions: (@MainActor () -> Void)?
    /// Import Subtitles… / Export SRT…: the host asks for a file.
    public var onImportSRT: (@MainActor () -> Void)?
    public var onExportSRT: (@MainActor () -> Void)?
    /// Why Create Captions is dimmed (its tooltip).
    public var createHint = "Transcribe the sequence first"

    public enum Control: Hashable { case find, replace, replaceAll, matchCase, list, create }

    private(set) var list = CaptionListDraw()
    private(set) var find = TextFieldControl()
    private(set) var replace = TextFieldControl()
    private(set) var matchCase = false
    /// The caption being typed into and its field (over the row's text column).
    private(set) var editing: (id: CaptionItem.ID, field: TextFieldControl)?
    /// A row is open for typing.
    public var isEditingCaption: Bool { editing != nil }
    private(set) var focus: Control?
    private var hover: Control?
    private var pressed: Control?
    private var anchor: Int?
    private var counter = ClickCounter()
    private var translationTargets: [(code: String, name: String)] = []
    private var translationTargetsLoaded = false

    public init(session: EditorSession) {
        self.session = session
        find.alignment = .left; replace.alignment = .left
        find.fontSize = CGFloat(DrawTheme.TypeSize.body); replace.fontSize = find.fontSize
        list.insets = (Self.pad, Self.pad)
        sync()
    }

    // MARK: Layout (CaptionsTabView.layout)

    // shortcut: the Mac `Theme` values at UI scale 1 (SQUIKit's Theme is AppKit): Spacing.sm 6, Metrics.quietField 22;
    // upgrade when SQUIKit's tokens move into a portable file.
    static let pad: CGFloat = 6
    static let fieldHeight: CGFloat = 22
    static let gap: CGFloat = 6
    static let footerHeight: CGFloat = 38
    static let replaceAllWidth: CGFloat = 92
    static let createWidth: CGFloat = 132

    func frame(_ k: Control) -> CGRect {
        let w = size.width, pad = Self.pad, fh = Self.fieldHeight, inner = max(w - 2 * pad, 0)
        let rowY = pad + fh + Self.gap, checkY = rowY + fh + Self.gap, top = checkY + fh + 8
        switch k {
        case .find: return CGRect(x: pad, y: pad, width: inner, height: fh)
        case .replace: return CGRect(x: pad, y: rowY, width: max(inner - Self.replaceAllWidth - 8, 40), height: fh)
        case .replaceAll: return CGRect(x: w - pad - Self.replaceAllWidth, y: rowY, width: Self.replaceAllWidth, height: fh)
        case .matchCase: return CGRect(x: pad, y: checkY, width: 120, height: fh)
        case .list: return CGRect(x: 0, y: top, width: w, height: max(size.height - Self.footerHeight - top, 0))
        case .create:
            return CGRect(x: w - pad - Self.createWidth, y: size.height - Self.footerHeight + (Self.footerHeight - fh) / 2,
                          width: Self.createWidth, height: fh)
        }
    }

    func control(at p: CGPoint) -> Control? {
        [Control.find, .replace, .replaceAll, .matchCase, .list, .create].first { frame($0).contains(p) }
    }

    // MARK: Model

    var rows: [CaptionListModel.Row] { list.model.rows }
    var selectedIDs: [CaptionItem.ID] { rows.map(\.id).filter { session.captionSelection.contains($0) } }
    private var findText: String { find.editor?.string ?? find.text }

    /// Reads the sequence's captions, the selection and the playhead.
    public func sync() {
        if let tl = session.activeTimeline {
            let drop = tl.frameDuration == Time(1001, 30000) || tl.frameDuration == Time(1001, 60000)
            _ = list.setModel(CaptionListModel(timeline: tl, timecode: Timecode(frameDuration: tl.frameDuration, dropFrame: drop)))
        } else {
            _ = list.setModel(CaptionListModel())
        }
        list.setSelected(session.captionSelection)
        list.setPlayhead(session.playhead)
        list.clampScroll(height: frame(.list).height)
        if let e = editing, !rows.contains(where: { $0.id == e.id }) { editing = nil }
        loadTranslationTargets()
    }

    private func loadTranslationTargets() {
        guard !translationTargetsLoaded else { return }
        translationTargetsLoaded = true
        #if !os(Windows)
        Task { @MainActor [weak self] in self?.translationTargets = await CaptionTranslator.supportedTargets() }
        #endif
        // shortcut: no caption translation on Windows (Apple Translation only); the row stays dimmed until a Windows translator exists.
    }

    /// Footer text: the caption count, or the match count while a Find text is set.
    var hint: String {
        if !findText.isEmpty {
            let n = session.activeTimeline?.captionMatches(find: findText, caseSensitive: matchCase).count ?? 0
            return n == 0 ? SQL10n.string("No match") : SQL10n.format("%@ of %@ match", String(n), String(rows.count))
        }
        let tracks = session.activeTimeline?.captionTracks.count ?? 0
        return SQL10n.plural(rows.count, one: "%@ caption", other: "%@ captions")
            + (tracks > 1 ? SQL10n.format(" on %@ tracks", String(tracks)) : "")
    }

    // MARK: Actions

    /// Return in Find: the next caption that matches (Shift: the one before), from the selected caption or the playhead.
    func stepFind(forward: Bool) {
        guard let tl = session.activeTimeline, !findText.isEmpty else { return }
        let items = session.captionItems, sel = selectedIDs
        let from = sel.count == 1 ? (items.first { $0.id == sel[0] }?.range.start ?? session.playhead) : session.playhead
        guard let next = tl.captionMatch(find: findText, caseSensitive: matchCase, from: from, forward: forward) else { return }
        session.select(clips: [], captions: [next])
        if let it = items.first(where: { $0.id == next }) { onSeek?(it.range.start) }
        sync()
        if let i = rows.firstIndex(where: { $0.id == next }) { reveal(i) }
    }

    func replaceAll() {
        guard !findText.isEmpty else { return }
        if findText == replace.text { onStatus?(SQL10n.string("Find and Replace are the same: nothing to change.")); return }
        let skipped = session.activeTimeline?.captionTracks.contains(where: \.isLocked) == true
            ? SQL10n.string(" Locked caption tracks were skipped.") : ""
        if let n = session.replaceCaptionText(find: findText, with: replace.text, caseSensitive: matchCase) {
            onStatus?(n == 0 ? SQL10n.string("No match.") + skipped
                             : SQL10n.plural(n, one: "Replaced %@ time.", other: "Replaced %@ times.") + skipped)
        }
        sync()
    }

    /// Opens typing on the caption's row (a double-click, Return on one selected row, Add Caption at Playhead).
    public func beginEditing(_ id: CaptionItem.ID) {
        sync()
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        commitEditing()
        endFieldEditing()
        session.select(clips: [], captions: [id])
        list.setSelected([id])
        reveal(i)
        var f = TextFieldControl(text: rows[i].text)
        f.alignment = .left; f.fontSize = CGFloat(DrawTheme.TypeSize.body)
        f.mouseDown()
        editing = (id, f)
        focus = .list
    }

    /// Writes the typed caption text (one undo step) and closes the row field.
    func commitEditing() {
        guard var e = editing else { return }
        editing = nil
        let text = e.field.commit() ?? e.field.text            // a Return in the field already committed it
        if text != rows.first(where: { $0.id == e.id })?.text {
            _ = session.setCaptionText(e.id, text)
        }
        sync()
    }

    private func endFieldEditing() {
        if find.isEditing { _ = find.commit() }
        if replace.isEditing { _ = replace.commit() }
    }

    private func reveal(_ i: Int) {
        let h = frame(.list).height, top = CGFloat(i) * CaptionListDraw.rowHeight
        let y = list.scrollY
        if top < y { _ = list.scroll(dy: y - top, height: h) }
        else if top + CaptionListDraw.rowHeight > y + h { _ = list.scroll(dy: -(top + CaptionListDraw.rowHeight - y - h), height: h) }
    }

    func addCaption() {
        if let id = session.addCaptionAtPlayhead() { beginEditing(id) }
    }

    /// Rows of the right-click menu (the clicked row is selected first).
    func contextItems() -> [SQMenuItem] {
        let n = selectedIDs.count
        let atPlayhead = session.activeTimeline?.captions(at: session.playhead).isEmpty == false
        let looks = CaptionPresetLibrary.builtIn.styleIDs.map { id in
            SQMenuItem(title: AnimationPresetName.title(for: id), isEnabled: n >= 1) { [weak self] in
                _ = self?.session.setSelectedCaptionStyle(id); self?.sync()
            }
        }
        let translations = translationTargets.map { (code, name) in
            SQMenuItem(title: name) { [weak self] in self?.translate(to: code) }
        }
        return [
            SQMenuItem(title: "Edit in Text", isEnabled: n == 1) { [weak self] in
                if let self, let id = selectedIDs.first { beginEditing(id) }
            },
            SQMenuItem(title: "Split Caption at Playhead", isEnabled: atPlayhead) { [weak self] in _ = self?.session.splitCaption(); self?.sync() },
            SQMenuItem(title: "Merge Captions", isEnabled: n >= 2) { [weak self] in _ = self?.session.mergeSelectedCaptions(); self?.sync() },
            .separator,
            SQMenuItem(title: "Look", isEnabled: n >= 1, submenu: looks),
            SQMenuItem(title: "Reset to Track Look", isEnabled: n >= 1 && session.selectedCaptionsHaveOverrides) { [weak self] in
                _ = self?.session.resetSelectedCaptionsToTrackLook(); self?.sync()
            },
            .separator,
            SQMenuItem(title: "Tidy for Short Video", isEnabled: !rows.isEmpty) { [weak self] in self?.tidy() },
            SQMenuItem(title: "Translate Captions", isEnabled: !rows.isEmpty && !translationTargets.isEmpty, submenu: translations),
            .separator,
            SQMenuItem(title: "Add Caption at Playhead", isEnabled: session.activeTimeline != nil) { [weak self] in self?.addCaption() },
            SQMenuItem(title: "New Caption Track", isEnabled: session.activeTimeline != nil) { [weak self] in self?.newTrack() },
            SQMenuItem(title: "Import Subtitles\u{2026}", isEnabled: onImportSRT != nil) { [weak self] in self?.onImportSRT?() },
            SQMenuItem(title: "Export SRT\u{2026}", isEnabled: !rows.isEmpty && onExportSRT != nil) { [weak self] in self?.onExportSRT?() },
            .separator,
            SQMenuItem(title: "Delete", shortcut: "\u{232B}", isEnabled: n >= 1) { [weak self] in _ = self?.session.deleteSelectedCaptions(); self?.sync() },
        ]
    }

    private func tidy() {
        if let n = session.tidyCaptions() { onStatus?(SQL10n.plural(n, one: "Tidied: %@ caption.", other: "Tidied: %@ captions.")) }
        sync()
    }

    private func newTrack() {
        if let id = session.addCaptionTrack(), let name = session.activeTimeline?.captionTrack(id)?.name {
            onStatus?(SQL10n.format("Added %@.", name))
        }
        sync()
    }

    private func translate(to code: String) {
        #if !os(Windows)
        onStatus?(SQL10n.string("Translating…"))
        Task { @MainActor [weak self] in
            guard let self else { return }
            let made = await session.translateCaptions(to: code)
            if let made, let name = session.activeTimeline?.captionTrack(made)?.name { onStatus?(SQL10n.format("Added %@.", name)) }
            else if let e = session.lastError { onStatus?(e) }
            sync()
        }
        #endif
    }

    /// A click on row `i`: plain selects it (and seeks), Command toggles it, Shift selects the range from the anchor.
    private func select(row i: Int, modifiers m: InputModifiers) {
        var ids = Set(selectedIDs)
        let id = rows[i].id
        if m.contains(.shift), let a = anchor, rows.indices.contains(a) {
            ids = Set(rows[min(a, i)...max(a, i)].map(\.id))
        } else if m.contains(.command) {
            if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
            anchor = i
        } else {
            ids = [id]; anchor = i
        }
        session.select(clips: [], captions: ids)
        list.setSelected(ids)
        if ids.count == 1, ids.contains(id) { onSeek?(rows[i].range.start) }
    }

    // MARK: Subtitle files (the host picks the file)

    /// File types Import Subtitles… accepts.
    public static let subtitleExtensions = SubtitleReader.fileExtensions

    /// Reads a picked subtitle file onto the caption track (one undo step) and reports the count or the reason.
    public func importSubtitles(data: Data, fileExtension: String) {
        let format = SubtitleReader.format(forExtension: fileExtension.lowercased()) ?? .srt
        if let n = session.importSRT(data: data, format: format) {
            onStatus?(SQL10n.plural(n, one: "Imported %@ caption.", other: "Imported %@ captions."))
        } else {
            onStatus?(session.lastError ?? SQL10n.string("Could not import the subtitle file."))
        }
        sync()
    }

    /// What Export SRT… writes: the captions of every visible caption track, in time order.
    public var exportItems: [CaptionItem] {
        (session.activeTimeline?.captionTracks ?? []).filter(\.isVisible).flatMap(\.items).sorted { $0.range.start < $1.range.start }
    }

    // MARK: Drawing

    public func draw(_ c: inout Canvas) {
        sync()
        let t = theme, fs = CGFloat(DrawTheme.TypeSize.body)
        c.fill(CGRect(origin: .zero, size: size), t.panel)
        drawField(&c, find, .find, placeholder: "Find")
        drawField(&c, replace, .replace, placeholder: "Replace With")
        InspectorDraw.button(&c, title: SQL10n.string("Replace All"), in: frame(.replaceAll), hovering: hover == .replaceAll,
                             pressed: pressed == .replaceAll, enabled: !findText.isEmpty && !rows.isEmpty, t)
        let mc = frame(.matchCase), box = CGRect(x: mc.minX, y: mc.midY - 7, width: 14, height: 14)
        InspectorDraw.checkbox(&c, matchCase ? .on : .off, box: box, hovering: hover == .matchCase, pressed: pressed == .matchCase,
                               enabled: true, t)
        c.draw(SQL10n.string("Match Case"), in: CGRect(x: box.maxX + 6, y: mc.minY, width: mc.width - 20, height: mc.height),
               fontSize: fs, t.label)

        let lf = frame(.list)
        if rows.isEmpty {
            let mid = lf.midY
            c.draw(SQL10n.string("No captions yet"), in: CGRect(x: Self.pad, y: mid - 20, width: lf.width - 2 * Self.pad, height: 18),
                   fontSize: fs, t.label2, align: .center)
            _ = c.drawWrapped(SQL10n.string("Transcribe the sequence first, then create captions from the transcript."),
                          in: CGRect(x: Self.pad * 3, y: mid, width: max(lf.width - 6 * Self.pad, 0), height: 40),
                          fontSize: CGFloat(DrawTheme.TypeSize.caption), lineHeight: 15, t.label3)
        } else {
            c.saveGState()
            c.translateBy(x: lf.minX, y: lf.minY)
            list.draw(&c, width: lf.width, height: lf.height, theme: t)
            if let e = editing, let i = rows.firstIndex(where: { $0.id == e.id }) {
                let col = list.columns(row: i, width: lf.width).text
                if col.maxY > 0, col.minY < lf.height {
                    c.clip(to: CGRect(x: 0, y: 0, width: lf.width, height: lf.height))
                    e.field.draw(&c, in: col.insetBy(dx: -4, dy: 1), theme: t, focused: true)
                }
            }
            c.restoreGState()
        }

        // Footer: a line, the count, Create Captions….
        let fy = size.height - Self.footerHeight
        c.fill(CGRect(x: 0, y: fy, width: size.width, height: 1), t.divider)
        let cf = frame(.create)
        c.draw(hint, in: CGRect(x: Self.pad, y: fy, width: max(cf.minX - 2 * Self.pad, 0), height: Self.footerHeight),
               fontSize: fs, t.label3)
        InspectorDraw.button(&c, title: SQL10n.string("Create Captions…"), in: cf, hovering: hover == .create,
                             pressed: pressed == .create, enabled: onCreateCaptions != nil, accent: true, t)
    }

    private func drawField(_ c: inout Canvas, _ f: TextFieldControl, _ k: Control, placeholder: String) {
        var f = f
        f.hovering = hover == k
        let r = frame(k)
        f.draw(&c, in: r, theme: theme, focused: focus == k)
        if f.text.isEmpty, !f.isEditing {
            c.draw(SQL10n.string(placeholder), in: r.insetBy(dx: 6, dy: 0), fontSize: f.fontSize, theme.label3)
        }
    }

    // MARK: Pointer and keys

    public func mouseMoved(to p: CGPoint?) {
        hover = p.flatMap(control)
        if let p, hover == .list {
            let lf = frame(.list)
            list.hovered = list.row(at: CGPoint(x: p.x - lf.minX, y: p.y - lf.minY), height: lf.height)
        } else { list.hovered = nil }
    }

    public func mouseDown(at p: CGPoint, modifiers m: InputModifiers = [], clickCount: Int? = nil) {
        let n = clickCount ?? counter.press(x: Float(p.x), y: Float(p.y), now: clock())
        let k = control(at: p)
        pressed = k
        // Leaving a field commits it.
        if k != .find, find.isEditing { _ = find.commit() }
        if k != .replace, replace.isEditing { _ = replace.commit() }
        switch k {
        case .find?: commitEditing(); focus = .find; find.mouseDown()
        case .replace?: commitEditing(); focus = .replace; replace.mouseDown()
        case .list?:
            focus = .list
            let lf = frame(.list)
            let q = CGPoint(x: p.x - lf.minX, y: p.y - lf.minY)
            guard let i = list.row(at: q, height: lf.height) else {
                commitEditing()
                if !m.contains(.secondary) { session.select(clips: [], captions: []); list.setSelected([]) }
                return
            }
            if let e = editing, e.id == rows[i].id { return }         // a press in the open field keeps typing
            commitEditing()
            if m.contains(.secondary) {
                if !session.captionSelection.contains(rows[i].id) { select(row: i, modifiers: []) }
                pressed = nil
                onMenu?(contextItems(), CGRect(x: p.x, y: p.y, width: 1, height: 1))
                return
            }
            select(row: i, modifiers: m)
            if n == 2, !m.contains(.command), !m.contains(.shift) { beginEditing(rows[i].id) }
        default:
            commitEditing()
            focus = k
        }
    }

    public func mouseDragged(to p: CGPoint) {}

    public func mouseUp(at p: CGPoint) {
        let k = pressed
        pressed = nil
        guard let k, control(at: p) == k else { return }
        switch k {
        case .replaceAll: replaceAll()
        case .matchCase: matchCase.toggle()
        case .create: onCreateCaptions?()
        default: break
        }
    }

    /// The wheel scrolls the list.
    public func scroll(at p: CGPoint, dy: CGFloat) -> Bool {
        guard control(at: p) == .list else { return false }
        return list.scroll(dy: dy, height: frame(.list).height)
    }

    /// Keys: the open field first (Return in Find steps to the next match), then the list (Return types into the one
    /// selected caption, Delete removes the selected captions, Command-A selects all, Up / Down move the selection).
    public func key(_ k: InputKey, modifiers m: InputModifiers) -> Bool {
        if var e = editing {
            let done = e.field.key(k, modifiers: m)
            editing = e
            if done != nil || k == .escape {
                if k == .escape, done == nil { editing = nil; return true }
                commitEditing()
            }
            return true
        }
        if find.isEditing {
            if k == .enter { _ = find.commit(); stepFind(forward: !m.contains(.shift)); find.mouseDown(); return true }
            if k == .escape { find.cancel(); return true }
            _ = find.key(k, modifiers: m)
            return true
        }
        if replace.isEditing {
            if k == .enter { _ = replace.commit(); replaceAll(); return true }
            _ = replace.key(k, modifiers: m)
            return true
        }
        guard focus == .list else { return false }
        let sel = selectedIDs
        switch k {
        case .enter where sel.count == 1: beginEditing(sel[0]); return true
        case .delete, .backspace:
            guard !sel.isEmpty else { return false }
            _ = session.deleteSelectedCaptions(); sync(); return true
        case .character("a") where m.contains(.command):
            session.select(clips: [], captions: Set(rows.map(\.id))); sync(); return true
        case .up, .down:
            guard !rows.isEmpty else { return false }
            let cur = sel.last.flatMap { id in rows.firstIndex { $0.id == id } } ?? (k == .up ? rows.count : -1)
            let i = min(max(cur + (k == .up ? -1 : 1), 0), rows.count - 1)
            select(row: i, modifiers: m.contains(.shift) ? .shift : [])
            reveal(i)
            return true
        default: return false
        }
    }

    public func help(at p: CGPoint) -> String? {
        switch control(at: p) {
        case .create: onCreateCaptions == nil ? SQL10n.string(createHint) : nil
        case .matchCase: SQL10n.string("Match Case")
        default: nil
        }
    }
}
