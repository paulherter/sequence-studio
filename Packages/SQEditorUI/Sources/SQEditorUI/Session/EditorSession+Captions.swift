import Foundation
import SQCore

/// Caption edits of the Text panel, the timeline and the Program monitor. Each call is one undo step
/// (typing into one caption merges into one step per editing session).
extension EditorSession {
    /// Caption items of the active timeline in time order.
    public var captionItems: [CaptionItem] {
        (activeTimeline?.captionTracks.flatMap(\.items) ?? []).sorted { $0.range.start < $1.range.start }
    }

    public func captionItem(_ id: CaptionItem.ID) -> CaptionItem? { captionItems.first { $0.id == id } }

    /// The caption under the playhead (visible tracks), if any.
    public var captionAtPlayhead: CaptionItem? { activeTimeline?.captions(at: playhead).first?.item }

    /// Text of one caption; line breaks in `text` become lines. `continuesGesture` merges typing into one step.
    @discardableResult
    public func setCaptionText(_ id: CaptionItem.ID, _ text: String, continuesGesture: Bool = false) -> Bool {
        if !continuesGesture { gestureCounter += 1 }
        let lines = text.components(separatedBy: "\n")
        return attempt("Edit Caption", coalescing: "caption:\(id):\(gestureCounter)") { try $0.setCaptionText(id, lines: lines) }
    }

    /// Splits the caption under `time` (default: the playhead) in two there.
    @discardableResult
    public func splitCaption(at time: Time? = nil) -> Bool {
        let t = (time ?? playhead).snapped(to: activeTimeline?.frameDuration ?? Time(1, 30))
        guard let item = activeTimeline?.captions(at: t).first?.item else { setError("There is no caption at the playhead."); return false }
        guard t > item.range.start else { setError("Move the playhead inside the caption."); return false }
        var second: CaptionItem.ID?
        let ok = attempt("Split Caption") { second = try $0.splitCaption(item.id, at: t).1 }
        if ok, let second { select(clips: [], captions: [second]) }
        return ok
    }

    /// Merges the selected captions (two or more on one track).
    @discardableResult
    public func mergeSelectedCaptions() -> Bool {
        guard captionSelection.count >= 2 else { setError("Select two or more captions to merge."); return false }
        var merged: CaptionItem.ID?
        let ok = attempt("Merge Captions") { merged = try $0.mergeCaptions(captionSelection) }
        if ok, let merged { select(clips: [], captions: [merged]) }
        return ok
    }

    @discardableResult
    public func deleteSelectedCaptions() -> Bool {
        guard !captionSelection.isEmpty else { return false }
        let ids = captionSelection
        let ok = attempt("Delete Captions") { t in for id in ids { try t.deleteCaption(id) } }
        if ok { select(clips: selection, captions: []) }
        return ok
    }

    /// New empty caption at the playhead (up to 3 s, cut short by the next one); it is selected so it can be typed into.
    @discardableResult
    public func addCaptionAtPlayhead() -> CaptionItem.ID? {
        guard let tl = activeTimeline else { return nil }
        let t = playhead.snapped(to: tl.frameDuration)
        var made: CaptionItem.ID?
        let ok = attempt("Add Caption") { made = try $0.addCaption(at: t, duration: Time(3, 1).snapped(to: tl.frameDuration)) }
        if ok, let made { select(clips: [], captions: [made]) }
        return ok ? made : nil
    }

    /// Search and replace over all captions; returns the number of replacements (nil: refused).
    @discardableResult
    public func replaceCaptionText(find: String, with new: String, caseSensitive: Bool) -> Int? {
        var n = 0
        let ok = attempt("Replace Caption Text") { n = try $0.replaceCaptionText(find: find, with: new, caseSensitive: caseSensitive) }
        guard ok || n == 0 else { return nil }
        return n
    }

    /// Caption style (and optionally animation) of every caption on every caption track.
    @discardableResult
    public func setCaptionStyle(styleRef: String, animationRef: String? = nil) -> Bool {
        guard let tl = activeTimeline, !tl.captionTracks.isEmpty else { return false }
        let ids = tl.captionTracks.map(\.id)
        return attempt("Caption Style") { t in
            for id in ids { try t.setCaptionStyle(styleRef: styleRef, animationRef: animationRef, track: id) }
        }
    }

    /// Adds `items` to the first caption track as one undo step, replacing nothing outside their range:
    /// existing captions that overlap an item are removed first (Create Captions on a second clip keeps the first clip's).
    @discardableResult
    public func addCaptions(_ items: [CaptionItem]) -> Bool {
        guard !items.isEmpty else { return false }
        return attempt("Create Captions") { t in
            let existing = t.captionTracks.first?.items ?? []
            let kept = existing.filter { e in !items.contains { $0.range.overlaps(e.range) } }
            _ = try t.replaceCaptions(kept + items)
        }
    }
}
