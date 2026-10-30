import Foundation
import SQUIKit
import SQCore
import SQTranscribe

/// Caption edits of the Captions panel, the timeline and the Program monitor. Each call is one undo step
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
        let track = currentCaptionTrack?.id
        let ok = attempt("Add Caption") { made = try $0.addCaption(at: t, duration: Time(3, 1).snapped(to: tl.frameDuration), track: track) }
        if ok, let made { select(clips: [], captions: [made]) }
        return ok ? made : nil
    }

    /// Search and replace over all captions; returns the number of replacements (nil: refused).
    @discardableResult
    public func replaceCaptionText(find: String, with new: String, caseSensitive: Bool) -> Int? {
        var n: Int?
        _ = attempt("Replace Caption Text") { n = try $0.replaceCaptionText(find: find, with: new, caseSensitive: caseSensitive) }
        return n          // nil when the edit threw (every caption track locked)
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

    /// Adds `items` to the current caption track (the first one, or the one picked in the Captions panel; created when there is none) as one undo step, replacing nothing outside their range:
    /// existing captions that overlap an item are removed first (Create Captions on a second clip keeps the first clip's).
    @discardableResult
    public func addCaptions(_ items: [CaptionItem]) -> Bool {
        guard !items.isEmpty else { return false }
        let target = currentCaptionTrack?.id
        return attempt("Create Captions") { t in
            let existing = target.flatMap { t.captionTrack($0) }?.items ?? []
            let kept = existing.filter { e in !items.contains { $0.range.overlaps(e.range) } }
            _ = try t.replaceCaptions(kept + items, track: target)
        }
    }

    /// Imports an `.srt`, `.vtt` or `.ass` file onto the caption track (cue times are sequence times), one undo step. Returns the number of
    /// captions added, or nil with `lastError` set when the file could not be read or holds no cues.
    @discardableResult
    public func importSRT(data: Data, format: SubtitleReader.Format = .srt) -> Int? {
        let doc: SRTReader.Document
        let label = format == .srt ? "SRT" : format == .vtt ? "WebVTT" : "ASS"
        do { doc = try SubtitleReader.parse(data: data, format: format) } catch {
            setError("Could not read the \(label) file: \(error)")
            return nil
        }
        let items = doc.captions.map {
            CaptionItem(lines: $0.lines, range: $0.range, styleRef: $0.styleRef, animationRef: $0.animationRef)
        }
        guard !items.isEmpty else { setError(SQL10n.format("The %@ file has no captions.", label)); return nil }
        return addCaptions(items) ? items.count : nil
    }
}

extension EditorSession {
    /// One-click fast-captions pass on the current caption track: short chunks along the word timings, no overlaps, tidy gaps.
    /// One undo step. Returns the number of captions after the pass (nil: nothing to do or refused, `lastError` explains).
    @discardableResult
    public func tidyCaptions(options: CaptionTidyOptions = .tikTok) -> Int? {
        guard let tl = activeTimeline, let track = currentCaptionTrack else { setError("There are no captions to tidy."); return nil }
        guard !track.isLocked else { setError("Unlock the caption track first."); return nil }
        let tidy = CaptionTidy.tidy(track.items, options: options, frameDuration: tl.frameDuration)
        guard !tidy.isEmpty else { setError("There are no captions to tidy."); return nil }
        guard tidy != track.items else { return tidy.count }
        return attempt("Tidy Captions") { _ = try $0.replaceCaptions(tidy, track: track.id) } ? tidy.count : nil
    }
}
