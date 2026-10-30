import AppKit
import SQCore

/// The inline field over a word on the caption track. Return takes the text, Escape drops it, Tab and Shift-Tab take
/// it and move on to the next or previous word; losing focus takes it too.
@MainActor
final class CaptionWordEditor: NSObject, NSTextFieldDelegate {
    enum Target: Equatable {
        /// Retype this word.
        case word(CaptionWordRef)
        /// Type new words that go before word `at` (`tokens.count`: at the end).
        case insert(CaptionItem.ID, at: Int)

        var caption: CaptionItem.ID {
            switch self {
            case .word(let r): return r.caption
            case .insert(let id, _): return id
            }
        }
    }

    let target: Target
    /// The caption's words when the field opened. When they differ at the end (an undo, another panel edited the
    /// caption meanwhile), the field no longer stands on the word it was opened for and what was typed is dropped.
    let opened: [String]
    let field: SQTextField
    /// `text` nil: canceled. `step`: -1 / 0 / +1 word to edit next. `refocus`: the keyboard goes back to the timeline.
    var onFinish: ((_ text: String?, _ step: Int, _ refocus: Bool) -> Void)?
    private var done = false

    init(target: Target, text: String, opened: [String]) {
        self.target = target
        self.opened = opened
        field = SQTextField(string: text)
        super.init()
        field.delegate = self
        field.alignment = .center
        field.setAccessibilityLabel("Caption word")
    }

    /// The word hidden under the field while it is retyped.
    func hiddenWord(in caption: CaptionItem.ID) -> Int? {
        if case .word(let r) = target, r.caption == caption { return r.index }
        return nil
    }

    func finish(commit: Bool, step: Int = 0, refocus: Bool = false) {
        guard !done else { return }
        done = true
        let text = commit ? field.stringValue : nil
        let report = onFinish
        onFinish = nil
        field.delegate = nil
        field.removeFromSuperview()
        report?(text, step, refocus)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): finish(commit: true, refocus: true)
        case #selector(NSResponder.insertTab(_:)): finish(commit: true, step: 1, refocus: true)
        case #selector(NSResponder.insertBacktab(_:)): finish(commit: true, step: -1, refocus: true)
        case #selector(NSResponder.cancelOperation(_:)): finish(commit: false, refocus: true)
        default: return false
        }
        return true
    }

    func controlTextDidEndEditing(_ note: Notification) { finish(commit: true) }
}

/// Correcting captions on the caption track: the inline word field, the word items of the context menu, find and
/// replace, Delete on a word, the cursors on word edges. The edits themselves are SQCore (`Captions+Words.swift`);
/// each one goes through `applyCaptionEdit`, so each is one undo step.
extension TimelineView {
    private var contentMinX: CGFloat { TimelineGeometry.contentOriginX }

    private func caption(_ id: CaptionItem.ID) -> (row: CaptionRow, item: CaptionItem, track: CaptionTrack)? {
        guard let (row, item) = CaptionWordLayout.locate(id, in: timeline, geometry: geometry),
              let track = timeline.captionTrack(row.track) else { return nil }
        return (row, item, track)
    }

    /// True when the word selection is on screen as a box (a caption drawn as one block has no word to act on).
    var hasVisibleWordSelection: Bool {
        guard let ref = wordSelection, let c = caption(ref.caption) else { return false }
        return CaptionWordLayout.showsWords(c.item, geometry: geometry)
    }

    // MARK: Inline field

    /// True when the caption's words are shown, or would be at a zoom this timeline can reach.
    func canShowWords(_ item: CaptionItem) -> Bool {
        if CaptionWordLayout.showsWords(item, geometry: geometry) { return true }
        var reached = geometry
        reached.pointsPerSecond = TimelineZoom.clamp(CaptionWordLayout.zoomForWords(item), to: zoomLimits)
        return CaptionWordLayout.showsWords(item, geometry: reached)
    }

    /// Double-click on a caption: the word under the pointer becomes a field. A caption drawn as one block is zoomed
    /// in to word level first (around the pointer). False, with the zoom untouched, when there is no word to edit
    /// there: no words, a locked track, or words the zoom cannot reach (the caller opens the Text panel).
    @discardableResult
    func beginWordEditing(at p: CGPoint, caption id: CaptionItem.ID) -> Bool {
        guard let c = caption(id), !c.track.isLocked, !c.item.tokens.isEmpty, canShowWords(c.item) else { return false }
        if !CaptionWordLayout.showsWords(c.item, geometry: geometry) {
            setZoom(pointsPerSecond: CaptionWordLayout.zoomForWords(c.item), anchorX: p.x, motion: false)
        }
        guard let hit = CaptionWordLayout.hit(p, caption: id, in: timeline, geometry: geometry) else { return false }
        return beginWordEditing(hit.ref)
    }

    /// Opens the field on one word (zooms to word level and scrolls it into view when needed).
    @discardableResult
    public func beginWordEditing(_ ref: CaptionWordRef) -> Bool {
        wordEditor?.finish(commit: true)
        guard let c = caption(ref.caption), !c.track.isLocked else { return false }
        let words = c.item.effectiveWords
        guard words.indices.contains(ref.index), canShowWords(c.item) else { return false }
        showWordLevel(c.item, around: words[ref.index].range.start)
        guard CaptionWordLayout.showsWords(c.item, geometry: geometry) else { return false }
        selectWord(ref)
        install(CaptionWordEditor(target: .word(ref), text: words[ref.index].text, opened: c.item.tokens))
        return true
    }

    /// Return with a word selected: opens the same field a double-click opens. False when no word is selected and shown.
    @discardableResult
    public func editSelectedWord() -> Bool {
        guard wordEditor == nil, let ref = wordSelection, hasVisibleWordSelection, selection.isEmpty,
              captionSelection == [ref.caption] else { return false }
        return beginWordEditing(ref)
    }

    /// Opens an empty field at a word boundary: what is typed is inserted before word `index`.
    @discardableResult
    public func beginWordInsert(in id: CaptionItem.ID, at index: Int) -> Bool {
        wordEditor?.finish(commit: true)
        guard let c = caption(id), !c.track.isLocked else { return false }
        let words = c.item.effectiveWords
        guard index >= 0, index <= words.count, canShowWords(c.item) else { return false }
        let at = index < words.count ? words[index].range.start : (words.last?.range.end ?? c.item.range.end)
        showWordLevel(c.item, around: at)
        guard CaptionWordLayout.showsWords(c.item, geometry: geometry) else { return false }
        install(CaptionWordEditor(target: .insert(id, at: index), text: "", opened: c.item.tokens))
        return true
    }

    /// Types into the open field and ends it as the key would (tests; the field itself needs a key window).
    func finishWordEditing(text: String?, step: Int = 0) {
        guard let e = wordEditor else { return }
        if let text { e.field.stringValue = text }
        e.finish(commit: text != nil, step: step, refocus: true)
    }

    private func showWordLevel(_ item: CaptionItem, around t: Time) {
        if !CaptionWordLayout.showsWords(item, geometry: geometry) {
            let x = geometry.x(for: t)
            setZoom(pointsPerSecond: CaptionWordLayout.zoomForWords(item), anchorX: min(max(x, contentMinX), max(bounds.width, contentMinX)), motion: false)
        }
        reveal(t)
    }

    /// Scrolls so that `t` is inside the visible tracks (a third in from the left); nothing when it already is.
    func reveal(_ t: Time) {
        let x = geometry.x(for: t), width = max(bounds.width - contentMinX, 1)
        let margin = min(Theme.Spacing.lg * 2, width / 4)
        guard x < contentMinX + margin || x > bounds.width - margin else { return }
        scroll(toX: max(geometry.scrollX + x - (contentMinX + width / 3), 0))
    }

    private func install(_ editor: CaptionWordEditor) {
        wordEditor = editor
        editor.onFinish = { [weak self, weak editor] text, step, refocus in
            guard let self, let editor else { return }
            // Typed for a caption that changed under the field: nothing is written.
            wordEditorFinished(editor.target, text: stillStands(editor) ? text : nil, step: step, refocus: refocus)
        }
        addSubview(editor.field)
        positionWordEditor()
        window?.makeFirstResponder(editor.field)
        editor.field.currentEditor()?.selectAll(nil)
        needsDisplay = true
    }

    /// Where the field sits: over its word (never narrower than a short word needs), or centered on the boundary new
    /// words go to. Nil when the word is gone.
    func wordEditorFrame(_ target: CaptionWordEditor.Target) -> CGRect? {
        guard let c = caption(target.caption) else { return nil }
        let words = c.item.effectiveWords
        let minWidth: CGFloat = 64
        switch target {
        case .word(let ref):
            guard words.indices.contains(ref.index) else { return nil }
            let box = CaptionWordLayout.box(words[ref.index].range, geometry: geometry, row: c.row)
            let w = max(box.width + 2 * Theme.Spacing.xs, minWidth)
            return CGRect(x: box.midX - w / 2, y: c.row.y, width: w, height: c.row.height)
        case .insert(_, let index):
            guard index <= words.count else { return nil }
            let t = index < words.count ? words[index].range.start : (words.last?.range.end ?? c.item.range.end)
            return CGRect(x: geometry.x(for: t) - minWidth / 2, y: c.row.y, width: minWidth, height: c.row.height)
        }
    }

    /// Keeps the field on its word while the timeline scrolls or zooms; it hides while the word is outside the tracks.
    func positionWordEditor() {
        guard let e = wordEditor else { return }
        guard stillStands(e), let f = wordEditorFrame(e.target) else { e.finish(commit: false); return }
        e.field.frame = f
        e.field.isHidden = f.minX < contentMinX || f.maxX > bounds.width
    }

    /// True while the caption the field was opened on still has the words it had then (same caption, same word at
    /// the same index, same text).
    private func stillStands(_ e: CaptionWordEditor) -> Bool {
        guard let c = caption(e.target.caption), !c.track.isLocked else { return false }
        return c.item.tokens == e.opened
    }

    private func wordEditorFinished(_ target: CaptionWordEditor.Target, text: String?, step: Int, refocus: Bool) {
        wordEditor = nil
        if refocus { window?.makeFirstResponder(self) }
        needsDisplay = true
        guard let text else { return }
        let typed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var out = timeline
        // The words that stand where the field was: `first ..< first + count`.
        var first = 0, count = 0
        let id = target.caption
        // Where the caption stands, should the edit remove it (its last word deleted): Tab goes on from there.
        let place = timeline.captionTracks.lazy.compactMap { tr in
            tr.items.firstIndex { $0.id == id }.map { (track: tr.id, item: $0) }
        }.first
        switch target {
        case .word(let ref):
            first = ref.index
            guard let c = caption(id), c.item.effectiveWords.indices.contains(ref.index) else { return }
            if c.item.effectiveWords[ref.index].text == typed {
                count = 1
            } else {
                guard let n = try? out.setCaptionWord(id, index: ref.index, text: typed) else { return }
                count = n
                let left = out.captionTracks.lazy.flatMap(\.items).first { $0.id == id }?.tokens.count ?? 0
                let select = left == 0 ? nil : CaptionWordRef(caption: id, index: min(ref.index, left - 1))
                applyCaptionEdit(out, undoName: typed.isEmpty ? "Delete Word" : "Edit Word", captions: [id], word: select)
            }
        case .insert(_, let index):
            first = index
            guard !typed.isEmpty, let n = try? out.insertCaptionWord(id, at: index, text: typed), n > 0 else { return }
            count = n
            applyCaptionEdit(out, undoName: n == 1 ? "Insert Word" : "Insert Words", captions: [id],
                             word: CaptionWordRef(caption: id, index: index))
        }
        guard step != 0 else { return }
        if let next = word(from: id, index: step > 0 ? first + count : first - 1, forward: step > 0, was: place) { beginWordEditing(next) }
    }

    /// The word at `index` of caption `id`, or, when the index is past its ends, the first word of the next caption
    /// (the last word of the previous one) on the same track. A caption that is gone (its last word was deleted) is
    /// continued from `place`, where it stood: the caption now there is the next one.
    private func word(from id: CaptionItem.ID, index: Int, forward: Bool, was place: (track: CaptionTrack.ID, item: Int)?) -> CaptionWordRef? {
        let track: CaptionTrack
        var i: Int
        if let tr = timeline.captionTracks.first(where: { $0.items.contains { $0.id == id } }),
           let k = tr.items.firstIndex(where: { $0.id == id }) {
            if tr.items[k].tokens.indices.contains(index) { return CaptionWordRef(caption: id, index: index) }
            track = tr
            i = k + (forward ? 1 : -1)
        } else if let place, let tr = timeline.captionTrack(place.track) {
            track = tr
            i = forward ? place.item : place.item - 1
        } else { return nil }
        while track.items.indices.contains(i) {
            let n = track.items[i].tokens.count
            if n > 0 { return CaptionWordRef(caption: track.items[i].id, index: forward ? 0 : n - 1) }
            i += forward ? 1 : -1
        }
        return nil
    }

    /// The timeline changed from outside (undo, another panel): the field goes when its word is gone, the find popup
    /// searches again.
    func captionWordToolsFollowTimeline() {
        if wordEditor != nil { positionWordEditor() }
        captionSearch?.timelineChanged()
    }

    // MARK: Word edits

    /// Delete with a word selected: removes that word (its time becomes a pause; the caption goes with its last word).
    /// False when no word is selected or shown, or more than its caption is selected: Delete then keeps its meaning.
    @discardableResult
    public func deleteSelectedWord() -> Bool {
        guard let ref = wordSelection, hasVisibleWordSelection, selection.isEmpty, captionSelection == [ref.caption] else { return false }
        return deleteWord(ref)
    }

    @discardableResult
    func deleteWord(_ ref: CaptionWordRef) -> Bool {
        var out = timeline
        guard (try? out.deleteCaptionWord(ref.caption, index: ref.index)) != nil else { return false }
        let left = out.captionTracks.lazy.flatMap(\.items).first { $0.id == ref.caption }?.tokens.count ?? 0
        applyCaptionEdit(out, undoName: "Delete Word", captions: [ref.caption],
                         word: left == 0 ? nil : CaptionWordRef(caption: ref.caption, index: min(ref.index, left - 1)))
        return true
    }

    /// Splits a caption so that word `index` starts the second one.
    @discardableResult
    public func splitCaption(_ id: CaptionItem.ID, beforeWord index: Int) -> Bool {
        var out = timeline
        guard let (_, second) = try? out.splitCaption(id, beforeWord: index) else { return false }
        applyCaptionEdit(out, undoName: "Split Caption", captions: [second], word: nil)
        return true
    }

    /// Joins a caption with the one before or after it on its track.
    @discardableResult
    public func joinCaption(_ id: CaptionItem.ID, with side: CaptionNeighbor) -> Bool {
        var out = timeline
        guard let joined = try? out.joinCaption(id, with: side) else { return false }
        applyCaptionEdit(out, undoName: "Join Captions", captions: [joined], word: nil)
        return true
    }

    // MARK: Context menu

    /// Word and caption items for a right-click on a caption (they go above the host's caption items).
    func captionWordMenuItems(at p: CGPoint) -> [SQMenuItem] {
        guard case .caption(let id, _) = geometry.hitTest(p, in: timeline), let c = caption(id), !c.track.isLocked else { return [] }
        var items: [SQMenuItem] = []
        if let hit = CaptionWordLayout.hit(p, caption: id, in: timeline, geometry: geometry) {
            let ref = hit.ref
            items += [
                SQMenuItem(title: "Edit Word", icon: .symbol(.text)) { [weak self] in self?.beginWordEditing(ref) },
                SQMenuItem(title: "Insert Word Before", icon: .symbol(.pasteInsert)) { [weak self] in self?.beginWordInsert(in: id, at: ref.index) },
                SQMenuItem(title: "Insert Word After", icon: .symbol(.plus)) { [weak self] in self?.beginWordInsert(in: id, at: ref.index + 1) },
                SQMenuItem(title: "Delete Word", icon: .symbol(.trash)) { [weak self] in self?.deleteWord(ref) },
                .separator,
                SQMenuItem(title: "Split Caption Before This Word", icon: .symbol(.columns2), isEnabled: ref.index > 0) { [weak self] in
                    self?.splitCaption(id, beforeWord: ref.index)
                },
            ]
        }
        let i = c.track.items.firstIndex { $0.id == id } ?? 0
        items += [
            SQMenuItem(title: "Join with Previous Caption", icon: .symbol(.arrowLeftToLine), isEnabled: i > 0) { [weak self] in
                self?.joinCaption(id, with: .previous)
            },
            SQMenuItem(title: "Join with Next Caption", icon: .symbol(.arrowRightToLine), isEnabled: i + 1 < c.track.items.count) { [weak self] in
                self?.joinCaption(id, with: .next)
            },
            .separator,
            SQMenuItem(title: "Find and Replace in Captions\u{2026}", icon: .symbol(.search)) { [weak self] in self?.showCaptionSearch() },
        ]
        return items
    }

    // MARK: Find and replace

    /// Opens find and replace for the caption tracks (anchored on the first caption row). False when the timeline has
    /// no captions: the caller keeps its own Find.
    @discardableResult
    public func showCaptionSearch() -> Bool {
        guard window != nil, timeline.captionTracks.contains(where: { !$0.items.isEmpty }),
              let row = geometry.captionRows(for: timeline).first else { return false }
        wordEditor?.finish(commit: true)
        let popup = captionSearch ?? makeCaptionSearch()
        captionSearch = popup
        let y = min(max(row.y, TimelineGeometry.rulerHeight), max(bounds.height - row.height, 0))
        popup.show(relativeTo: CGRect(x: contentMinX + Theme.Spacing.md, y: y, width: CaptionSearchPopup.width, height: row.height), of: self)
        return true
    }

    func makeCaptionSearch() -> CaptionSearchPopup {
        let popup = CaptionSearchPopup()
        popup.timeline = { [weak self] in self?.timeline ?? Timeline(name: "", frameDuration: Time(1, 30), tracks: []) }
        popup.playhead = { [weak self] in self?.playhead ?? .zero }
        popup.onShowMatch = { [weak self] m in self?.showCaptionMatch(m) }
        popup.onHighlightMatch = { [weak self] m in self?.selectWord(CaptionWordRef(caption: m.caption, index: m.words.lowerBound)) }
        popup.onReplace = { [weak self] out, name in
            guard let self else { return }
            applyCaptionEdit(out, undoName: name, captions: captionSelection, word: nil)
        }
        return popup
    }

    /// Return, Next, Previous or Replace went to a match: its first word and caption are selected, the playhead goes to
    /// it, it scrolls into view. (Typing in the find field only selects the word: see `onHighlightMatch`.)
    func showCaptionMatch(_ m: CaptionTextMatch) {
        selectWord(CaptionWordRef(caption: m.caption, index: m.words.lowerBound))
        onSeek?(m.time)
        reveal(m.time)
    }

    // MARK: Cursors

    /// Resize cursors on the word edges that retime (the caption's own edges keep their trim cursor).
    func addCaptionWordCursorRects(in content: CGRect) {
        guard toolState.timelineTool == .selection, geometry.pointsPerSecond >= CaptionWordLayout.wordLevelPointsPerSecond else { return }
        let grab = CaptionWordLayout.edgeGrab
        for row in geometry.captionRows(for: timeline) {
            guard row.maxY > content.minY, row.y < content.maxY, let track = timeline.captionTrack(row.track), !track.isLocked else { continue }
            let items = track.items
            var i = max(CaptionWordLayout.firstIndex(endingAfter: geometry.time(atX: content.minX), in: items) - 1, 0)
            while i < items.count {
                let item = items[i]
                i += 1
                let x0 = geometry.x(for: item.range.start), x1 = geometry.x(for: item.range.end)
                if x1 < content.minX { continue }
                if x0 > content.maxX { break }
                guard CaptionWordLayout.showsWords(item, geometry: geometry) else { continue }
                let handle = TimelineGeometry.trimHandleWidth(forClipWidth: x1 - x0)
                for w in item.effectiveWords {
                    let a = geometry.x(for: w.range.start), b = geometry.x(for: w.range.end)
                    guard b - a >= CaptionWordLayout.minWidthForEdges else { continue }
                    for x in [a, b - grab] where x >= x0 + handle && x + grab <= x1 - handle {
                        let r = CGRect(x: x, y: row.y, width: grab, height: row.height).intersection(content)
                        if !r.isEmpty { addCursorRect(r, cursor: .resizeLeftRight) }
                    }
                }
            }
        }
    }
}
