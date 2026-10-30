import Foundation
import SQCore
import SQLibrary

/// Title blocks in the Library: a selection of text, shape and adjustment clips with their element transitions, saved
/// once and placed again on free tracks at the playhead. The library item is a `.titleBlock` preset (`TitleBlock`).
extension EditorSession {
    /// True when the selection can be saved as a title block: only generator clips, at least one.
    public var canSaveSelectionAsTitleBlock: Bool {
        guard let t = activeTimeline else { return false }
        return t.isMediaFree(selection)
    }

    /// The selection as a title block; nil with a fresh `lastError` when something selected has media (or nothing is).
    public func titleBlockFromSelection() -> TitleBlock? {
        guard let t = activeTimeline, !selection.isEmpty else { setError("Select the title clips first."); return nil }
        guard t.isMediaFree(selection), let cb = t.clipboard(copying: selection), let block = TitleBlock(block: cb) else {
            setError("A title block holds only text, shape and adjustment clips. Deselect clips with media.")
            return nil
        }
        return block
    }

    /// Places `block` at `time` (default the playhead) on free tracks above whatever plays there, as one undo step; the
    /// first text clip ends up selected so typing replaces it. Returns the new clips (empty when refused, `lastError` says why).
    @discardableResult
    public func insertTitleBlock(_ block: TitleBlock, at time: Time? = nil) -> [Clip.ID] {
        guard let tlID = activeTimelineID, let t = activeTimeline else { setError("Open a sequence first."); return [] }
        let start = (time ?? playhead).snapped(to: t.frameDuration)
        var ids: [Clip.ID] = []
        do {
            try perform("Insert Title Block") { p in
                try p.edit(tlID) { ids = try $0.placeBlock(block.block, at: start) }
            }
        } catch { setError(Self.message(for: error)); return [] }
        let texts = zip(ids, block.block.entries).filter { $0.1.clip.generator?.kind == GeneratorRef.text }.map(\.0)
        if let first = texts.first ?? ids.first { select(clips: [first]) }
        return ids
    }
}
