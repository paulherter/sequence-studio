import Foundation
import SQCore

/// Per-caption position (monitor drag, Style tab nudge, reset). A caption without its own position follows the kit's.
extension EditorSession {
    /// Where a caption is drawn: its own position, else the project's kit position.
    public func effectiveCaptionPosition(_ item: CaptionItem) -> CaptionPosition { item.position ?? captionPosition }

    /// Gives the captions their own position. `continuesGesture` merges a drag or an offset stepper into one undo step.
    @discardableResult
    public func setCaptionItemPosition(_ ids: Set<CaptionItem.ID>, _ p: CaptionPosition, continuesGesture: Bool) -> Bool {
        if !continuesGesture { gestureCounter += 1 }
        return attempt("Move Caption", coalescing: "captionPos:\(gestureCounter)") { try $0.setCaptionItemPosition(ids, position: p) }
    }

    /// Hands the captions back to the kit position ("Reset to kit position"). One undo step.
    @discardableResult
    public func resetCaptionPositions(_ ids: Set<CaptionItem.ID>) -> Bool {
        let own = Set(captionItems.filter { ids.contains($0.id) && $0.position != nil }.map(\.id))
        guard !own.isEmpty else { return false }
        gestureCounter += 1
        return attempt("Reset Caption Position") { try $0.setCaptionItemPosition(own, position: nil) }
    }

    /// Every caption of the sequence (for "Reset" with the scope on all captions).
    public var allCaptionIDs: Set<CaptionItem.ID> { Set(captionItems.map(\.id)) }
}
