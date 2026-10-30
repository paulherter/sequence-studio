import AppKit
import SQCore

/// Fast Cut: drag the attach thread of an attached clip along its host (Selection tool, no modifier). The drag previews
/// on the view's timeline and reports once on mouse up through `onSetAttachPoint`, so it is one undo step. Escape
/// restores the timeline from before the drag.
extension TimelineView {
    func beginAttachDrag(at p: CGPoint, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard toolState.timelineTool == .selection, timeline.isFastCut, onSetAttachPoint != nil,
              modifiers.intersection([.command, .option, .shift, .control]).isEmpty,
              let id = AttachPointDrag.hit(at: p, in: timeline, geometry: geometry) else { return false }
        // A trim edge of the host under the marker keeps its trim meaning (an attach point on a cut is moved by its thread).
        if case .clip(_, let zone) = geometry.hitTest(p, in: timeline), zone != .body { return false }
        onPointerDown?()
        attachDrag = (id, timeline, timeline.tracks.lazy.flatMap(\.clips).first { $0.id == id }.map { c in
            c.start + (c.attachment?.point ?? .zero)
        } ?? .zero)
        NSCursor.resizeLeftRight.set()
        return true
    }

    func updateAttachDrag(to p: CGPoint) -> Bool {
        guard var d = attachDrag else { return false }
        let snapping = toolState.snapping != interaction.snapInverted
        if let t = AttachPointDrag.target(x: p.x, clip: d.clip, in: d.original, geometry: geometry, playhead: playhead, snapping: snapping),
           t != d.time {
            var preview = d.original
            if (try? preview.setAttachPoint(d.clip, at: t)) != nil {
                d.time = t
                attachDrag = d
                setTimeline(preview)
                needsDisplay = true
            }
        }
        return true
    }

    func endAttachDrag(at p: CGPoint) -> Bool {
        guard attachDrag != nil else { return false }
        _ = updateAttachDrag(to: p)
        guard let d = attachDrag else { return true }
        attachDrag = nil
        NSCursor.arrow.set()
        setTimeline(d.original)                       // the host's edit brings the new timeline back
        let start = d.original.tracks.lazy.flatMap(\.clips).first { $0.id == d.clip }
        if let start, start.start + (start.attachment?.point ?? .zero) != d.time { onSetAttachPoint?(d.clip, d.time) }
        needsDisplay = true
        return true
    }
}
