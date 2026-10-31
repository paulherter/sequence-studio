import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import SQCore
import SQDrawKit
import SQEditorSession
import SQTranscribe
import SQUIKit

/// The Transcribe tab of the Text panel on the shared toolkit: `CaptionsPanelView` translated. Transcribe (the whole
/// sequence), the language, a progress line while it runs, then the transcript: hovering marks a word, a click seeks to
/// it, a double-click types into it (Return or Escape ends it), the search row marks every match, and Create Captions…
/// sits in the footer. State lives in `CaptionsPanelModel`; the host owns one model per sequence.
/// shortcut: no mascot beside the progress bar (the Mac `SQMascotPlace.captionsRunning` view) and no search-field
/// magnifier; a match inside a word is marked on exactly its characters, a match across a space only inside the words.
/// Coordinates: points, y down, (0, 0) = the tab's top-left.
@MainActor public final class TranscriptTabDraw {
    public var theme = DrawTheme()
    public var size = CGSize(width: 320, height: 400)
    public var clock: @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime }
    /// The sequence's transcript model; nil = nothing to show (no sequence).
    public var model: CaptionsPanelModel? {
        didSet { if model !== oldValue { resetView() } }
    }
    public var onMenu: (@MainActor (_ items: [SQMenuItem], _ anchor: CGRect) -> Void)?
    /// Create Captions… (the host's dialog over the model).
    public var onCreateCaptions: (@MainActor () -> Void)?
    /// Mark All: the hit times and the search text (the host adds the markers as one undo step).
    public var onMarkHits: (@MainActor ([Time], String) -> Void)?
    /// "Replace the transcript?" is due (the host asks, then answers the model).
    public var onConfirmOverwrite: (@MainActor () -> Void)?
    public var playhead: @MainActor () -> Time = { .zero }

    public enum Control: Hashable { case transcribe, language, cancel, search, prev, next, markAll, text, create }

    private(set) var search = TextFieldControl()
    private var searchTerm: String { search.editor?.string ?? search.text }
    private var currentMatch: NSRange?
    private var matchLabel: String?
    private(set) var hoveredWord: Int?
    /// The word being typed into (its index) and its field.
    private(set) var editing: (index: Int, field: TextFieldControl)?
    private(set) var scrollY: CGFloat = 0
    private var focus: Control?
    private var hover: Control?
    private var pressed: Control?
    private var languageOpen = false
    private var counter = ClickCounter()
    private var overwriteAsked = false

    public init() {
        search.alignment = .left
        search.fontSize = CGFloat(DrawTheme.TypeSize.body)
        search.placeholder = "Find in transcript"
    }

    private func resetView() {
        search = {
            var f = TextFieldControl(); f.alignment = .left; f.fontSize = CGFloat(DrawTheme.TypeSize.body)
            f.placeholder = "Find in transcript"; return f
        }()
        currentMatch = nil; matchLabel = nil; hoveredWord = nil; editing = nil; scrollY = 0; focus = nil; overwriteAsked = false
    }

    // MARK: State (CaptionsPanelView.refresh)

    enum Phase { case idle, running(Double), ready, failed(String) }

    var phase: Phase {
        guard let m = model else { return .idle }
        switch m.state {
        case .idle: return .idle
        case .transcribing(let p): return .running(p)
        case .ready: return m.transcript == nil ? .idle : .ready
        case .failed(let s): return .failed(s)
        }
    }

    var isRunning: Bool { if case .running = phase { return true }; return false }
    var isReady: Bool { if case .ready = phase { return true }; return false }
    var isIdle: Bool { if case .idle = phase { return true }; return false }

    static let editHint = "Editing text. Return or Esc keeps it; Cmd+Z undoes the edit."

    var transcribeTitle: String {
        guard let m = model else { return "Transcribe" }
        if isRunning { return "Transcribing…" }
        if case .failed = phase { return "Try Again" }
        return m.transcript == nil ? "Transcribe" : "Transcribe Again"
    }

    /// One filled button per state: Transcribe or Try Again; the quiet Transcribe Again; Transcribing… is dimmed.
    var transcribeIsAccent: Bool {
        guard let m = model, !isRunning else { return false }
        if case .failed = phase { return true }
        return m.transcript == nil
    }

    var statusText: String {
        guard let m = model else { return "" }
        if editing != nil { return SQL10n.string(Self.editHint) }
        switch m.state {
        case .idle:
            return SQL10n.string(m.canTranscribe ? "Not transcribed yet." : "Nothing audible in this sequence.")
        case .transcribing(let p):
            return m.statusNote.map { SQL10n.string($0) + "..." } ?? SQL10n.format("Transcribing %@ %%", String(Int((p * 100).rounded())))
        case .ready:
            let n = m.editedWordIDs.count
            return m.isOutdated
                ? SQL10n.string("The timeline changed since this transcript. Transcribe again.")
                : SQL10n.format(n > 0 ? "%@ words, %@ edited" : "%@ words", String(m.transcript?.words.count ?? 0), String(n))
        case .failed(let msg):
            return msg.hasPrefix("Transcription failed") ? SQL10n.string(msg) : SQL10n.string("Transcription failed.") + " " + SQL10n.string(msg)
        }
    }

    func languageTitle(_ id: String) -> String { Locale.current.localizedString(forIdentifier: id) ?? id }

    // MARK: Layout (CaptionsPanelView.build: a vertical stack, 8 pt apart and inset, hidden rows collapse)

    // shortcut: the Mac `Theme` values at UI scale 1 (SQUIKit's Theme is AppKit): Spacing.sm 8, xs 4, quietField 22;
    // upgrade when SQUIKit's tokens move into a portable file.
    static let pad: CGFloat = 8
    static let rowHeight: CGFloat = 22
    static let topGap: CGFloat = 3          // measured on the Mac render: button to language popup
    static let lineHeight: CGFloat = 22
    static let linePad: CGFloat = 5         // NSTextContainer.lineFragmentPadding
    static let insetY: CGFloat = 4
    static let statusHeight: CGFloat = 14
    static let iconWidth: CGFloat = 22
    /// Widths measured from the canvas the tab drew last (no atlas: a letter is 6.5 points).
    private var transcribeWidth: CGFloat = 78
    private var languageWidth: CGFloat = 186
    private var markAllWidth: CGFloat = 70
    private var cancelWidth: CGFloat = 60
    private var createWidth: CGFloat = 130

    private struct Frames {
        var transcribe, language, cancel, status, search, prev, next, markAll, bar, text, create, progress: CGRect
    }

    private func frames() -> Frames {
        let p = Self.pad, h = Self.rowHeight, inner = max(size.width - 2 * p, 0)
        let tr = CGRect(x: p, y: 0, width: transcribeWidth, height: h)
        let lang = CGRect(x: tr.maxX + Self.topGap, y: 0, width: languageWidth, height: h)
        var y = h + p
        var progress = CGRect.zero, cancel = CGRect.zero, status = CGRect.zero, search = CGRect.zero
        var bar = CGRect.zero, prev = CGRect.zero, next = CGRect.zero, mark = CGRect.zero
        if isRunning {
            cancel = CGRect(x: size.width - p - cancelWidth, y: y, width: cancelWidth, height: h)
            progress = CGRect(x: p, y: y + (h - 4) / 2, width: max(cancel.minX - 10 - p, 0), height: 4)
            y += h + p
        }
        if !isIdle {
            status = CGRect(x: p, y: y, width: inner, height: Self.statusHeight)
            y += Self.statusHeight + p
        }
        if isReady {
            mark = CGRect(x: size.width - p - markAllWidth, y: y, width: markAllWidth, height: h)
            next = CGRect(x: mark.minX - 4 - Self.iconWidth, y: y, width: Self.iconWidth, height: h)
            prev = CGRect(x: next.minX - 4 - Self.iconWidth, y: y, width: Self.iconWidth, height: h)
            search = CGRect(x: p, y: y, width: max(prev.minX - 4 - p - countWidth - (countWidth > 0 ? 4 : 0), 40), height: h)
            y += h + p
            bar = CGRect(x: p, y: y, width: inner, height: 2)
            y += 2 + p
        }
        let create = CGRect(x: size.width - p - createWidth, y: size.height - p - h, width: createWidth, height: h)
        let text = isReady ? CGRect(x: p, y: y, width: inner, height: max(create.minY - p - y, 0)) : .zero
        return Frames(transcribe: tr, language: lang, cancel: cancel, status: status, search: search, prev: prev, next: next,
                      markAll: mark, bar: bar, text: text, create: create, progress: progress)
    }

    private var countWidth: CGFloat { matchLabel == nil ? 0 : 44 }

    func frameForTests(_ k: Control) -> CGRect { frame(k) }

    private func frame(_ k: Control) -> CGRect {
        let f = frames()
        switch k {
        case .transcribe: return f.transcribe
        case .language: return f.language
        case .cancel: return f.cancel
        case .search: return f.search
        case .prev: return f.prev
        case .next: return f.next
        case .markAll: return f.markAll
        case .text: return f.text
        case .create: return isReady ? f.create : .zero
        }
    }

    func control(at p: CGPoint) -> Control? {
        [Control.transcribe, .language, .cancel, .search, .prev, .next, .markAll, .text, .create].first {
            let r = frame($0); return r.width > 0 && r.contains(p)
        }
    }

    // MARK: Words (the transcript wrapped in 22 pt lines)

    struct Placed { var index: Int; var rect: CGRect; var text: String; var range: NSRange }
    private var placed: [Placed] = []
    private var contentHeight: CGFloat = 0
    private var layoutKey = ""
    private var layoutHadAtlas = false

    /// Lays the words out in the text area's width; cached on the text, the width and the atlas.
    private func layoutWords(_ c: Canvas?, width: CGFloat) {
        guard let m = model, let t = m.transcript else { placed = []; contentHeight = 0; layoutKey = ""; return }
        let hasAtlas = c?.atlas != nil
        let key = "\(Int(width))|\(m.wordRanges.count)|\(t.text)"
        if key == layoutKey, hasAtlas == layoutHadAtlas { return }
        layoutKey = key; layoutHadAtlas = hasAtlas
        let fs = CGFloat(DrawTheme.TypeSize.title)
        func w(_ s: String) -> CGFloat { hasAtlas ? c?.size(of: s, fontSize: fs).width ?? 0 : CGFloat(s.count) * fs * 0.55 }
        let space = w(" "), ns = t.text as NSString, avail = Swift.max(width - 2 * Self.linePad, 1)
        var x: CGFloat = 0, line = 0
        placed = []
        for (i, r) in m.wordRanges.enumerated() where NSMaxRange(r) <= ns.length {
            let s = ns.substring(with: r), sw = w(s)
            if x > 0, x + sw > avail { line += 1; x = 0 }
            placed.append(Placed(index: i, rect: CGRect(x: Self.linePad + x, y: Self.insetY + CGFloat(line) * Self.lineHeight,
                                                        width: sw, height: Self.lineHeight), text: s, range: r))
            x += sw + space
        }
        contentHeight = Self.insetY * 2 + CGFloat(line + 1) * Self.lineHeight
    }

    private func clampScroll(_ viewHeight: CGFloat) {
        scrollY = Swift.min(Swift.max(scrollY, 0), Swift.max(contentHeight - viewHeight, 0))
    }

    private func word(at p: CGPoint) -> Placed? {
        let t = frame(.text)
        let q = CGPoint(x: p.x - t.minX, y: p.y - t.minY + scrollY)
        // A gap between words belongs to the word before it, like the text view's insertion point.
        var best: Placed?
        for w in placed where w.rect.minY <= q.y && q.y < w.rect.maxY && w.rect.minX - 3 <= q.x { best = w }
        return best.flatMap { q.x <= $0.rect.maxX + 3 ? $0 : nil }
    }

    // MARK: Actions

    private var matches: [NSRange] {
        TranscriptSearch.matches(in: model?.transcript?.text ?? "", find: searchTerm, caseSensitive: false)
    }

    /// Moves to the next or previous match, shows it and puts the playhead on that word.
    func stepSearch(forward: Bool) {
        guard let m = model else { return }
        let ms = matches
        let here = currentMatch?.location ?? (forward ? -1 : (m.transcript?.text as NSString?)?.length ?? 0)
        guard let i = TranscriptSearch.step(ms, from: here, forward: forward) else { return }
        currentMatch = ms[i]
        matchLabel = SQL10n.format("%@ of %@", String(i + 1), String(ms.count))
        if let w = placed.first(where: { NSLocationInRange(ms[i].location, $0.range) || $0.range.location >= ms[i].location }) {
            let h = frame(.text).height
            if w.rect.minY < scrollY { scrollY = w.rect.minY - Self.insetY }
            else if w.rect.maxY > scrollY + h { scrollY = w.rect.maxY - h + Self.insetY }
            clampScroll(h)
        }
        m.seek(toCharacter: ms[i].location)
    }

    func markAll() {
        guard let m = model else { return }
        m.flushEdits()
        let times = matches.compactMap { r in m.wordIndex(atCharacter: r.location).flatMap { m.transcript?.words[$0].range.start } }
        guard !times.isEmpty else { return }
        onMarkHits?(times, searchTerm)
    }

    func beginEditing(word i: Int) {
        guard let m = model, m.state == .ready, let w = placed.first(where: { $0.index == i }) else { return }
        hoveredWord = nil
        var f = TextFieldControl(text: w.text)
        f.alignment = .left; f.fontSize = CGFloat(DrawTheme.TypeSize.title)
        f.mouseDown()
        editing = (i, f)
        focus = .text
    }

    /// Writes the typed word into the transcript text (the model's debounced edit, flushed at once) and closes the field.
    func endEditing(keep: Bool) {
        guard var e = editing, let m = model else { editing = nil; return }
        editing = nil
        guard keep, let w = placed.first(where: { $0.index == e.index }) else { return }
        let typed = e.field.commit() ?? e.field.text
        guard typed != w.text, let text = m.transcript?.text as NSString? else { return }
        m.textChanged(text.replacingCharacters(in: w.range, with: typed))
        m.flushEdits()
    }

    private func languageMenu() -> [SQMenuItem] {
        guard let m = model else { return [] }
        return m.languages.map { id in
            SQMenuItem(title: languageTitle(id), isChecked: id == m.language) { [weak m] in m?.language = id }
        }
    }

    // MARK: Session to UI

    /// Per draw: the playhead word, the overwrite question.
    public func sync() {
        guard let m = model else { return }
        m.updatePlayhead(playhead())
        if m.needsOverwriteConfirmation {
            if !overwriteAsked { overwriteAsked = true; onConfirmOverwrite?() }
        } else { overwriteAsked = false }
    }

    // MARK: Drawing

    /// No sequence open: the empty state instead of the tab (TextPanelView.emptyLabel).
    var showsEmptyState: Bool { model == nil }
    static let noSequenceTitle = "No sequence open", noSequenceHint = "Open a sequence to transcribe it and create captions"

    public func draw(_ c: inout Canvas) {
        sync()
        let t = theme, fs = CGFloat(DrawTheme.TypeSize.body)
        c.fill(CGRect(origin: .zero, size: size), t.panel)
        guard let m = model else {
            // TextPanelView.emptyLabel: no sequence, no transcript page.
            c.drawEmptyState(title: SQL10n.string(Self.noSequenceTitle), hint: SQL10n.string(Self.noSequenceHint),
                             in: CGRect(origin: .zero, size: size), theme: t)
            return
        }
        measure(c, m)
        let f = frames(), enabledTop = m.canTranscribe && !isRunning
        InspectorDraw.button(&c, title: SQL10n.string(transcribeTitle), in: f.transcribe, hovering: hover == .transcribe,
                             pressed: pressed == .transcribe, enabled: enabledTop, accent: transcribeIsAccent, t)
        let lang = m.languages.contains(m.language) ? languageTitle(m.language) : m.language
        InspectorDraw.popup(&c, title: lang, in: f.language, hovering: hover == .language, open: languageOpen, enabled: enabledTop, t)

        if isRunning {
            if case .running(let p) = phase { InspectorDraw.progress(&c, fraction: p, in: f.progress, t) }
            InspectorDraw.button(&c, title: SQL10n.string("Cancel"), in: f.cancel, hovering: hover == .cancel,
                                 pressed: pressed == .cancel, enabled: true, t)
        }
        if isIdle {
            // The empty state under the top row: 15 pt semibold heading, 11 pt hint, centered in the rest of the panel.
            let top = Self.rowHeight, mid = top + (size.height - top) / 2
            c.draw(statusText, in: CGRect(x: Self.pad, y: mid - 18, width: size.width - 2 * Self.pad, height: 20),
                   fontSize: 15, t.label, align: .center, face: c.semibold)
            if m.canTranscribe {
                c.draw(SQL10n.string("The words of the sequence appear here."),
                       in: CGRect(x: Self.pad, y: mid + 4, width: size.width - 2 * Self.pad, height: 16), fontSize: fs, t.label2, align: .center)
            }
            return
        }
        var failed = false
        if case .failed = phase { failed = true }
        c.draw(statusText, in: f.status, fontSize: fs, failed ? t.red : (editing != nil ? t.accent : t.label3))
        guard isReady else { return }

        // Search row.
        var sf = search
        sf.hovering = hover == .search
        sf.draw(&c, in: f.search, theme: t, focused: focus == .search)
        if sf.text.isEmpty, !sf.isEditing {
            c.draw(SQL10n.string("Find in transcript"), in: f.search.insetBy(dx: 6, dy: 0), fontSize: fs, t.label3)
        }
        if let l = matchLabel ?? (searchTerm.isEmpty ? nil : SQL10n.string("No match")) {
            c.draw(l, in: CGRect(x: f.search.maxX + 4, y: f.search.minY, width: f.prev.minX - f.search.maxX - 8, height: f.search.height),
                   fontSize: fs, t.label3)
        }
        let hits = matches
        for (k, dir) in [(Control.prev, InspectorDraw.Direction.up), (.next, .down)] {
            let r = frame(k), on = !hits.isEmpty
            InspectorDraw.button(&c, title: "", in: r, hovering: hover == k, pressed: pressed == k, enabled: on, t)
            InspectorDraw.chevron(&c, in: r, direction: dir, t.label.alpha(on ? t.label.a : t.label.a * InspectorTokens.disabledAlpha), size: 8)
        }
        InspectorDraw.button(&c, title: SQL10n.string("Mark All"), in: f.markAll, hovering: hover == .markAll, pressed: pressed == .markAll,
                             enabled: !hits.isEmpty && !m.isOutdated, t)
        c.fill(roundedRect: f.bar, radius: 1, t.accentFill)
        drawText(&c, m, in: f.text)
        InspectorDraw.button(&c, title: SQL10n.string("Create Captions…"), in: f.create, hovering: hover == .create,
                             pressed: pressed == .create, enabled: m.canCreateCaptions, accent: true, t)
    }

    /// Button and popup widths from the canvas (SQButton.intrinsicContentSize; the popup is as wide as its widest item).
    private func measure(_ c: Canvas, _ m: CaptionsPanelModel) {
        transcribeWidth = InspectorDraw.buttonWidth(c, title: SQL10n.string(transcribeTitle))
        markAllWidth = InspectorDraw.buttonWidth(c, title: SQL10n.string("Mark All"))
        cancelWidth = InspectorDraw.buttonWidth(c, title: SQL10n.string("Cancel"))
        createWidth = InspectorDraw.buttonWidth(c, title: SQL10n.string("Create Captions…"))
        let fs = CGFloat(DrawTheme.TypeSize.body)
        // SQPopup measures the first 64 items only.
        let titles = m.languages.prefix(64).map(languageTitle) + [languageTitle(m.language)]
        let widest = titles.map { c.size(of: $0, fontSize: fs).width }.max() ?? 0
        // SQPopup.intrinsicContentSize: title inset 10 + text + gap 8 + chevron 7 + inset 7.
        // shortcut: the canvas measure snaps glyph advances to the pixel grid and runs 0.44 pt under
        // NSString on average; half a point of slack (one pixel at 2x) matches the Mac popup in most
        // cases. Upgrade when the canvas measures with the platform text shaper.
        languageWidth = max(ceil(widest + 0.5 + 10 + 8 + 7 + 7), 120)
    }

    private func drawText(_ c: inout Canvas, _ m: CaptionsPanelModel, in r: CGRect) {
        let t = theme, fs = CGFloat(DrawTheme.TypeSize.title)
        layoutWords(c, width: r.width)
        clampScroll(r.height)
        let edit = editing != nil
        let page = edit ? t.content.lifted(0.06) : t.panel
        c.fill(roundedRect: r, radius: CGFloat(DrawTheme.Radius.control), page)
        c.saveGState()
        c.clip(to: r)
        c.translateBy(x: r.minX, y: r.minY - scrollY)
        let current = m.currentWordID, words = m.transcript?.words ?? []
        let hits = matches
        for w in placed where w.rect.maxY > scrollY && w.rect.minY < scrollY + r.height {
            let word = w.index < words.count ? words[w.index] : nil
            if edit, editing?.index == w.index { continue }
            let isCurrent = word?.id == current
            if hoveredWord == w.index, !edit {
                c.fill(w.rect, t.fillHover)
            }
            if isCurrent { c.fill(w.rect, t.accentTint) }
            for h in hits {
                let i = NSIntersectionRange(h, w.range)
                guard i.length > 0 else { continue }
                let ns = w.text as NSString
                let x0 = c.size(of: ns.substring(to: i.location - w.range.location), fontSize: fs).width
                let x1 = c.size(of: ns.substring(to: NSMaxRange(i) - w.range.location), fontSize: fs).width
                let hit = CGRect(x: w.rect.minX + x0, y: w.rect.minY, width: x1 - x0, height: w.rect.height)
                c.fill(hit, h == currentMatch ? t.yellow : t.yellow.alpha(0.35))
            }
            let onCurrentMatch = currentMatch.map { NSIntersectionRange($0, w.range).length > 0 } ?? false
            c.draw(w.text, in: w.rect, fontSize: fs, isCurrent ? t.onClip : (onCurrentMatch ? DrawColor.black : t.label))
            if let word, word.isEdited || word.isUnsure {
                let col = word.isUnsure ? t.warning : t.yellow
                c.fill(CGRect(x: w.rect.minX, y: w.rect.maxY - 5, width: w.rect.width, height: 1), col)
            }
        }
        if let e = editing, let w = placed.first(where: { $0.index == e.index }) {
            e.field.draw(&c, in: w.rect.insetBy(dx: -6, dy: 0), theme: t, focused: true)
        }
        c.restoreGState()
        if edit { c.stroke(roundedRect: r.insetBy(dx: 1, dy: 1), radius: CGFloat(DrawTheme.Radius.control), width: 2, t.accent) }
    }

    // MARK: Pointer and keys

    public func mouseMoved(to p: CGPoint?) {
        hover = p.flatMap(control)
        guard let p, hover == .text, editing == nil else { hoveredWord = nil; return }
        hoveredWord = word(at: p)?.index
    }

    public func mouseDown(at p: CGPoint, modifiers m: InputModifiers = [], clickCount: Int? = nil) {
        let n = clickCount ?? counter.press(x: Float(p.x), y: Float(p.y), now: clock())
        let k = control(at: p)
        if k != .search, search.isEditing { _ = search.commit() }
        if k != .text, editing != nil { endEditing(keep: true) }
        pressed = k
        switch k {
        case .search?: focus = .search; search.mouseDown()
        case .text?:
            focus = .text
            guard editing == nil, let w = word(at: p) else { return }
            if n >= 2 { beginEditing(word: w.index) } else { model?.seek(toCharacter: w.range.location) }
        case .language?:
            pressed = nil
            languageOpen = true
            let f = frame(.language)
            if model?.canTranscribe == true, !isRunning { onMenu?(languageMenu(), f) }
            languageOpen = false
        default: focus = k
        }
    }

    public func mouseDragged(to p: CGPoint) {}

    public func mouseUp(at p: CGPoint) {
        let k = pressed
        pressed = nil
        guard let k, control(at: p) == k, let m = model else { return }
        switch k {
        case .transcribe where m.canTranscribe && !isRunning: m.transcribe()
        case .cancel: m.cancelTranscription()
        case .prev: stepSearch(forward: false)
        case .next: stepSearch(forward: true)
        case .markAll: markAll()
        case .create where m.canCreateCaptions: onCreateCaptions?()
        default: break
        }
    }

    public func scroll(at p: CGPoint, dy: CGFloat) -> Bool {
        guard control(at: p) == .text else { return false }
        let before = scrollY
        scrollY -= dy
        clampScroll(frame(.text).height)
        return scrollY != before
    }

    /// Keys: the word field first (Return or Escape ends it), then the search field (Return = next, Shift+Return = previous).
    public func key(_ k: InputKey, modifiers m: InputModifiers) -> Bool {
        if var e = editing {
            if k == .enter { endEditing(keep: true); return true }
            if k == .escape { endEditing(keep: true); return true }
            _ = e.field.key(k, modifiers: m)
            editing = e
            return true
        }
        if search.isEditing {
            if k == .enter { stepSearch(forward: !m.contains(.shift)); return true }
            if k == .escape { search.cancel(); return true }
            let before = searchTerm
            _ = search.key(k, modifiers: m)
            if searchTerm != before { currentMatch = nil; matchLabel = nil }
            return true
        }
        return false
    }

    public func help(at p: CGPoint) -> String? {
        switch control(at: p) {
        case .transcribe: SQL10n.string("Transcribes the speech of the whole sequence")
        case .prev: SQL10n.string("Previous match (Shift+Return)")
        case .next: SQL10n.string("Next match (Return)")
        case .markAll: SQL10n.string("Set a marker at every match, named after the search text")
        case .create where model?.canCreateCaptions == false:
            SQL10n.string("The timeline changed since this transcript. Transcribe again.")
        case .text:
            hoveredWord.flatMap { i in
                (model?.transcript?.words).flatMap { $0.indices.contains(i) && $0[i].isUnsure ? SQL10n.string("Unsure word") : nil }
            }
        default: nil
        }
    }
}
