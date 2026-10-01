import Foundation
import SSCore

/// Premiere-style timeline operations on the selection: clipboard, link, nudge, edge trims, gaps, markers.
extension EditorSession {
    // MARK: Clipboard

    /// Cmd+C. False when no clip is selected.
    @discardableResult
    public func copySelection() -> Bool {
        guard let t = activeTimeline, let cb = t.clipboard(copying: selection) else { return false }
        clipboard = cb
        return true
    }

    /// Cmd+X: copy, then lift (Premiere's Cut leaves a gap; Cmd+Shift+X is not bound).
    public func cutSelection() {
        guard copySelection() else { return }
        deleteSelection(ripple: false)
    }

    /// Cmd+V (overwrite at the playhead on the targeted tracks) or Cmd+Shift+V (insert). The pasted clips become the selection.
    public func pasteClipboard(insert: Bool = false) {
        guard let cb = clipboard, !cb.isEmpty else { return }
        let at = playhead
        var made: [Clip.ID] = []
        let done = attempt(insert ? "Paste Insert" : "Paste") { made = try $0.paste(cb, at: at, insert: insert) }
        if done { select(clips: Set(made)) }
    }

    // MARK: Link

    /// Cmd+L: unlinks when the selection is one linked group, otherwise links the selected clips.
    public func toggleLinkSelection() {
        guard let t = activeTimeline else { return }
        let clips = t.tracks.flatMap(\.clips).filter { selection.contains($0.id) }
        guard clips.count >= 2 || clips.contains(where: { $0.link != nil }) else { return }
        let ids = selection
        let links = Set(clips.map(\.link))
        if links.count == 1, links.first! != nil { attempt("Unlink") { try $0.unlink(ids) } }
        else if clips.count >= 2 { attempt("Link") { try $0.link(ids) } }
        else { attempt("Unlink") { try $0.unlink(ids) } }
    }

    // MARK: Nudge, edge trims, extend, gaps

    /// Cmd+Left / Cmd+Right (Shift: 5 frames): moves the selected clips by whole frames.
    public func nudgeSelection(frames n: Int) {
        guard !selection.isEmpty, let t = activeTimeline else { return }
        let ids = selection, d = t.frameDuration * Int64(n)
        attempt("Nudge") { _ = try $0.nudge(ids, by: d) }
    }

    /// Opt+Left / Opt+Right with an edit selected: moves the selected edge(s) by `n` frames.
    public func trimEdges(_ sel: EdgeSelection, frames n: Int) {
        guard let t = activeTimeline else { return }
        let edits = EdgeEdits.trim(sel, by: t.frameDuration * Int64(n), in: t)
        run(edits, EdgeEdits.isRoll(sel, in: t) ? "Roll Edit" : (sel.ripple ? "Ripple Trim" : "Trim Clip"), sel: sel)
    }

    /// E: moves the selected edit to the playhead.
    public func extendEdit(_ sel: EdgeSelection) {
        guard let t = activeTimeline else { return }
        let edits = EdgeEdits.extend(sel, to: playhead, in: t)
        run(edits, "Extend Edit", sel: sel)
    }

    private func run(_ edits: [TimelineEdit], _ name: String, sel: EdgeSelection) {
        guard !edits.isEmpty else { return }
        attempt(name) { t in for e in edits { try e.apply(to: &t) } }
    }

    /// Delete on a selected gap: ripple-deletes it.
    public func closeGap(_ gap: GapSelection) {
        attempt("Ripple Delete") { _ = try $0.closeGap(on: gap.track, at: gap.range.start) }
    }

    // MARK: Rename and label

    /// Context menu Rename: the one selected clip. A blank name is ignored.
    public func renameSelectedClip(to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, let id = selection.first, selection.count == 1 else { return }
        attempt("Rename Clip") { t in
            guard var c = t.tracks.lazy.compactMap({ $0.clips.first { $0.id == id } }).first else { return }
            c.name = n
            try t.replaceClip(c)
        }
    }

    /// Context menu Label: colour of the selected clips (nil = back to the default of its type).
    public func setLabel(_ label: LabelColor?) {
        let ids = selection
        guard !ids.isEmpty else { return }
        attempt("Label") { t in
            for c in t.tracks.flatMap(\.clips) where ids.contains(c.id) && c.label != label {
                var n = c; n.label = label
                try t.replaceClip(n)
            }
        }
    }

    // MARK: Selection and marks

    /// Cmd+A: every clip of the active sequence.
    public func selectAllClips() {
        guard let t = activeTimeline else { return }
        select(clips: Set(t.tracks.flatMap(\.clips).map(\.id)))
    }

    /// `/`: In/Out around the selected clips.
    public func markSelection() {
        guard let t = activeTimeline else { return }
        let ranges = t.tracks.flatMap(\.clips).filter { selection.contains($0.id) }.map(\.timeline)
        guard let lo = ranges.map(\.start).min(), let hi = ranges.map(\.end).max() else { return }
        attempt("Mark Selection") { $0.inOut = TimeRange(start: lo, end: hi) }
    }

    /// Shift+M / Cmd+Shift+M.
    public func goToNextMarker() { if let m = activeTimeline?.nextMarker(after: playhead) { seek(to: m.time) } }
    public func goToPreviousMarker() { if let m = activeTimeline?.previousMarker(before: playhead) { seek(to: m.time) } }
}
