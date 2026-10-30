import Foundation
import SQCore
import SQDrawKit
import SQTimelineUI
import SQUIKit

/// The inline field over a word on the caption track (the Mac `CaptionWordEditor`): Return takes the text, Esc drops it,
/// Tab and Shift-Tab take it and move on to the next or previous word; a press elsewhere takes it too.
struct CaptionWordField: Sendable {
    enum Target: Equatable, Sendable {
        /// Retype this word.
        case word(CaptionWordRef)
        /// Type new words that go before word `at` (`tokens.count`: at the end).
        case insert(CaptionItem.ID, at: Int)

        var caption: CaptionItem.ID {
            switch self {
            case .word(let r): r.caption
            case .insert(let id, _): id
            }
        }
    }

    let target: Target
    /// The caption's words when the field opened: when they differ later (an undo, another panel), the field no longer
    /// stands on its word and what was typed is dropped.
    let opened: [String]
    var control: TextFieldControl

    /// The word hidden under the field while it is retyped.
    func hiddenWord(in caption: CaptionItem.ID) -> Int? {
        if case .word(let r) = target, r.caption == caption { return r.index }
        return nil
    }
}

/// Correcting captions on the caption track, translated from `TimelineView+CaptionWords`: the inline word field, Return
/// and Delete on the selected word, the word items of the context menu. The edits are SQCore (`Captions+Words.swift`);
/// each one is one `.commit` (one undo step) through `interaction.commitCaptionEdit`.
extension TimelinePanel {
    private func caption(_ id: CaptionItem.ID) -> (row: CaptionRow, item: CaptionItem, track: CaptionTrack)? {
        guard let (row, item) = CaptionWordLayout.locate(id, in: timeline, geometry: geometry),
              let track = timeline.captionTrack(row.track) else { return nil }
        return (row, item, track)
    }

    /// True while a word field is open (the panel takes every key).
    public var isEditingWord: Bool { wordField != nil }

    var hasVisibleWordSelection: Bool {
        guard let ref = interaction.wordSelection, let c = caption(ref.caption) else { return false }
        return CaptionWordLayout.showsWords(c.item, geometry: geometry)
    }

    /// True when the caption's words are shown, or would be at a zoom this timeline can reach.
    func canShowWords(_ item: CaptionItem) -> Bool {
        if CaptionWordLayout.showsWords(item, geometry: geometry) { return true }
        var reached = geometry
        reached.pointsPerSecond = TimelineZoom.clamp(CaptionWordLayout.zoomForWords(item), to: zoomLimits)
        return CaptionWordLayout.showsWords(item, geometry: reached)
    }

    // MARK: Opening

    /// Double-click on a caption: the word under the pointer becomes a field (a caption drawn as one block is zoomed in
    /// to word level first). nil, with the zoom untouched, when there is no word to edit there (the caller opens the
    /// Text panel).
    mutating func beginWordEditing(at p: CGPoint, caption id: CaptionItem.ID) -> [TimelineAction]? {
        guard let c = caption(id), !c.track.isLocked, !c.item.tokens.isEmpty, canShowWords(c.item) else { return nil }
        let zoom = geometry.pointsPerSecond, scroll = geometry.scrollX
        if !CaptionWordLayout.showsWords(c.item, geometry: geometry) {
            setZoom(pointsPerSecond: CaptionWordLayout.zoomForWords(c.item), anchorX: p.x)
        }
        guard let hit = CaptionWordLayout.hit(p, caption: id, in: timeline, geometry: geometry),
              let out = beginWordEditing(hit.ref) else {
            geometry.pointsPerSecond = zoom; geometry.scrollX = scroll
            return nil
        }
        return out
    }

    /// Opens the field on one word (zooms to word level and scrolls it into view when needed). nil when it cannot.
    public mutating func beginWordEditing(_ ref: CaptionWordRef) -> [TimelineAction]? {
        var out = finishWordField(commit: true)
        guard let c = caption(ref.caption), !c.track.isLocked else { return out.isEmpty ? nil : out }
        let words = c.item.effectiveWords
        guard words.indices.contains(ref.index), canShowWords(c.item) else { return out.isEmpty ? nil : out }
        showWordLevel(c.item, around: words[ref.index].range.start)
        guard CaptionWordLayout.showsWords(c.item, geometry: geometry) else { return out.isEmpty ? nil : out }
        out += selectWord(ref)
        open(CaptionWordField(target: .word(ref), opened: c.item.tokens, control: TextFieldControl(text: words[ref.index].text)))
        return out
    }

    /// Opens an empty field at a word boundary: what is typed goes before word `index`.
    public mutating func beginWordInsert(in id: CaptionItem.ID, at index: Int) -> [TimelineAction]? {
        let out = finishWordField(commit: true)
        guard let c = caption(id), !c.track.isLocked else { return out.isEmpty ? nil : out }
        let words = c.item.effectiveWords
        guard index >= 0, index <= words.count, canShowWords(c.item) else { return out.isEmpty ? nil : out }
        let at = index < words.count ? words[index].range.start : (words.last?.range.end ?? c.item.range.end)
        showWordLevel(c.item, around: at)
        guard CaptionWordLayout.showsWords(c.item, geometry: geometry) else { return out.isEmpty ? nil : out }
        open(CaptionWordField(target: .insert(id, at: index), opened: c.item.tokens, control: TextFieldControl(text: "")))
        return out
    }

    /// Return with a word selected: opens the same field a double-click opens.
    mutating func editSelectedWord() -> [TimelineAction]? {
        guard wordField == nil, gesture == nil, let ref = interaction.wordSelection, hasVisibleWordSelection, selection.isEmpty,
              captionSelection == [ref.caption] else { return nil }
        return beginWordEditing(ref)
    }

    private mutating func open(_ f: CaptionWordField) {
        var f = f
        f.control.alignment = .center
        f.control.mouseDown()                     // editing, everything selected (the Mac field selects all)
        wordField = f
    }

    private mutating func showWordLevel(_ item: CaptionItem, around t: Time) {
        if !CaptionWordLayout.showsWords(item, geometry: geometry) {
            let x = geometry.x(for: t), minX = TimelineGeometry.contentOriginX
            setZoom(pointsPerSecond: CaptionWordLayout.zoomForWords(item), anchorX: min(max(x, minX), max(size.width, minX)))
        }
        reveal(t)
    }

    /// Scrolls so that `t` is inside the visible tracks (a third in from the left); nothing when it already is.
    mutating func reveal(_ t: Time) {
        let minX = TimelineGeometry.contentOriginX
        let x = geometry.x(for: t), width = max(size.width - minX, 1)
        let margin = min(DrawTheme.Spacing.lg.cg * 2, width / 4)
        guard x < minX + margin || x > size.width - margin else { return }
        geometry.scrollX = max(geometry.scrollX + x - (minX + width / 3), 0)
        clampScroll()
    }

    /// `TimelineView.selectWord`: the word and its caption become the selection.
    mutating func selectWord(_ ref: CaptionWordRef?) -> [TimelineAction] {
        feedInteraction()
        if let ref {
            interaction.setSelection([])
            interaction.setCaptionSelection([ref.caption])
        }
        interaction.setWordSelection(ref)
        return refreshFromInteraction()
    }

    // MARK: The open field

    /// Where the field sits: over its word (never narrower than a short word needs), or centered on the boundary new
    /// words go to. nil when the word is gone.
    func wordFieldFrame() -> CGRect? {
        guard let f = wordField, let c = caption(f.target.caption) else { return nil }
        let words = c.item.effectiveWords
        let minWidth: CGFloat = 64
        switch f.target {
        case .word(let ref):
            guard words.indices.contains(ref.index) else { return nil }
            let box = CaptionWordLayout.box(words[ref.index].range, geometry: geometry, row: c.row)
            let w = max(box.width + 2 * DrawTheme.Spacing.xs.cg, minWidth)
            return CGRect(x: box.midX - w / 2, y: c.row.y, width: w, height: c.row.height)
        case .insert(_, let index):
            guard index <= words.count else { return nil }
            let t = index < words.count ? words[index].range.start : (words.last?.range.end ?? c.item.range.end)
            return CGRect(x: geometry.x(for: t) - minWidth / 2, y: c.row.y, width: minWidth, height: c.row.height)
        }
    }

    /// True while the caption the field was opened on still has the words it had then.
    private func stillStands(_ f: CaptionWordField) -> Bool {
        guard let c = caption(f.target.caption), !c.track.isLocked else { return false }
        return c.item.tokens == f.opened
    }

    /// The timeline changed from outside (undo, another panel): the field goes when its word is gone.
    mutating func wordFieldFollowsTimeline() {
        if let f = wordField, !stillStands(f) || wordFieldFrame() == nil { wordField = nil }
    }

    /// Keys while the field is open: every key is the field's.
    mutating func wordFieldKey(_ k: InputKey, modifiers mods: InputModifiers) -> [TimelineAction] {
        guard var f = wordField else { return [] }
        if k == InputKey.tab { return finishWordField(commit: true, step: mods.contains(.shift) ? -1 : 1) }
        switch k {
        case .enter: return finishWordField(commit: true)
        case .escape: return finishWordField(commit: false)
        default:
            _ = f.control.key(k, modifiers: mods)
            wordField = f
            return []
        }
    }

    /// A press while the field is open: inside keeps editing, elsewhere takes the text (the Mac field loses focus).
    mutating func wordFieldPress(_ p: CGPoint) -> [TimelineAction]? {
        guard wordField != nil else { return nil }
        // shortcut: a press inside the field keeps the caret where it is (no caret placement by pointer); add it with a
        // text-measuring hit test when the field needs mouse selection.
        if let r = wordFieldFrame(), r.contains(p) { return [] }
        return nil
    }

    /// Ends the field. `step` -1 / +1 opens the previous / next word afterwards (Tab).
    @discardableResult
    mutating func finishWordField(commit: Bool, step: Int = 0) -> [TimelineAction] {
        guard let f = wordField else { return [] }
        wordField = nil
        guard commit, stillStands(f) else { return [] }
        let text = f.control.editor?.string ?? f.control.text
        let typed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var out = timeline
        var first = 0, count = 0
        let id = f.target.caption
        let place = timeline.captionTracks.lazy.compactMap { tr in
            tr.items.firstIndex { $0.id == id }.map { (track: tr.id, item: $0) }
        }.first
        var actions: [TimelineAction] = []
        switch f.target {
        case .word(let ref):
            first = ref.index
            guard let c = caption(id), c.item.effectiveWords.indices.contains(ref.index) else { return [] }
            if c.item.effectiveWords[ref.index].text == typed {
                count = 1
            } else {
                guard let n = try? out.setCaptionWord(id, index: ref.index, text: typed) else { return [] }
                count = n
                let left = out.captionTracks.lazy.flatMap(\.items).first { $0.id == id }?.tokens.count ?? 0
                let select = left == 0 ? nil : CaptionWordRef(caption: id, index: min(ref.index, left - 1))
                actions += applyCaptionEdit(out, undoName: typed.isEmpty ? "Delete Word" : "Edit Word", captions: [id], word: select)
            }
        case .insert(_, let index):
            first = index
            guard !typed.isEmpty, let n = try? out.insertCaptionWord(id, at: index, text: typed), n > 0 else { return [] }
            count = n
            actions += applyCaptionEdit(out, undoName: n == 1 ? "Insert Word" : "Insert Words", captions: [id],
                                        word: CaptionWordRef(caption: id, index: index))
        }
        guard step != 0,
              let next = word(from: id, index: step > 0 ? first + count : first - 1, forward: step > 0, was: place) else { return actions }
        return actions + (beginWordEditing(next) ?? [])
    }

    /// The word at `index` of caption `id`, or past its ends the first word of the next caption (the last word of the
    /// previous one) on the same track. A caption that is gone (its last word deleted) is continued from `place`.
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

    /// `applyCaptionEdit`: a word edit made outside a gesture becomes the panel's timeline and one session commit.
    public mutating func applyCaptionEdit(_ out: Timeline, undoName: String, captions: Set<CaptionItem.ID>, word: CaptionWordRef?) -> [TimelineAction] {
        guard out != timeline else { return [] }
        feedInteraction()
        let commit = interaction.commitCaptionEdit(out, undoName: undoName, captions: captions, word: word)
        return refreshFromInteraction() + [.commit(commit)]
    }

    // MARK: Word edits

    /// Delete with a word selected: removes that word. nil when no word is selected or shown, or more than its caption
    /// is selected: Delete then keeps its meaning.
    mutating func deleteSelectedWord() -> [TimelineAction]? {
        guard gesture == nil, let ref = interaction.wordSelection, hasVisibleWordSelection, selection.isEmpty,
              captionSelection == [ref.caption] else { return nil }
        return deleteWord(ref)
    }

    mutating func deleteWord(_ ref: CaptionWordRef) -> [TimelineAction]? {
        var out = timeline
        guard (try? out.deleteCaptionWord(ref.caption, index: ref.index)) != nil else { return nil }
        let left = out.captionTracks.lazy.flatMap(\.items).first { $0.id == ref.caption }?.tokens.count ?? 0
        return applyCaptionEdit(out, undoName: "Delete Word", captions: [ref.caption],
                                word: left == 0 ? nil : CaptionWordRef(caption: ref.caption, index: min(ref.index, left - 1)))
    }

    /// Splits a caption so that word `index` starts the second one.
    mutating func splitCaption(_ id: CaptionItem.ID, beforeWord index: Int) -> [TimelineAction] {
        var out = timeline
        guard let (_, second) = try? out.splitCaption(id, beforeWord: index) else { return [] }
        return applyCaptionEdit(out, undoName: "Split Caption", captions: [second], word: nil)
    }

    /// Joins a caption with the one before or after it on its track.
    mutating func joinCaption(_ id: CaptionItem.ID, with side: CaptionNeighbor) -> [TimelineAction] {
        var out = timeline
        guard let joined = try? out.joinCaption(id, with: side) else { return [] }
        return applyCaptionEdit(out, undoName: "Join Captions", captions: [joined], word: nil)
    }

    // MARK: Drawing

    /// The open field over its word (hidden while the word is outside the tracks, like the Mac field).
    func drawWordField(_ cv: inout Canvas, clip: CGRect) {
        guard let f = wordField, let r = wordFieldFrame(), r.minX >= clip.minX, r.maxX <= clip.maxX else { return }
        cv.fill(r.insetBy(dx: 0, dy: 1), theme.timeline)
        f.control.draw(&cv, in: r, theme: theme, focused: true)
    }
}
