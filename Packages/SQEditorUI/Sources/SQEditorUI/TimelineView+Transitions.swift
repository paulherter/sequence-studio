import AppKit
import SQCore

/// View state of transitions on the timeline (kept in one struct so `TimelineView` gains a single stored property).
struct TransitionViewState {
    var selected: Transition.ID?
    struct Drag {
        var hit: TransitionHit
        var original: ResolvedTransition
        var startX: CGFloat
        var lastFrames: Int64 = 0
        var began = false
    }
    var drag: Drag?
    var dropTarget: TransitionDropTarget?
}

/// Transition boxes: drawing, click / double-click / drag, and the drop target of a transition dragged from the Effects panel.
extension TimelineView {
    // MARK: Selection

    public var selectedTransition: Transition.ID? { transitionState.selected }

    /// Selects a transition (nil clears). Clip selection is cleared like Premiere; the host mirrors it into the session.
    public func setSelectedTransition(_ id: Transition.ID?, notify: Bool = true) {
        guard transitionState.selected != id else { return }
        transitionState.selected = id
        if id != nil, !selection.isEmpty || !captionSelection.isEmpty { clearClipSelectionForTransition() }
        if notify { onTransitionSelect?(id) }
        needsDisplay = true
    }

    // MARK: Mouse (called from TimelineView before the normal gesture reducer)

    /// True when the press hit a transition box and was handled here.
    func transitionMouseDown(_ p: CGPoint, event: NSEvent) -> Bool {
        guard let hit = TransitionLayout.hitTest(p, in: timeline, geometry: geometry) else { return false }
        setSelectedTransition(hit.id)
        if event.clickCount == 2 {
            onTransitionDoubleClick?(hit.id)
            return true
        }
        guard let track = timeline.track(hit.track),
              let r = track.resolvedTransitions(frameDuration: timeline.format.frameDuration).first(where: { $0.id == hit.id })
        else { return true }
        transitionState.drag = TransitionViewState.Drag(hit: hit, original: r, startX: p.x)
        return true
    }

    func transitionMouseDragged(_ p: CGPoint, event: NSEvent) -> Bool {
        guard var d = transitionState.drag else { return false }
        let frames = (geometry.time(atX: p.x) - geometry.time(atX: d.startX)).frameIndex(frameDuration: geometry.frameDuration)
        if frames == d.lastFrames && d.began { return true }
        if !d.began && abs(p.x - d.startX) < TimelineInteraction.dragThreshold { return true }
        let change = TransitionLayout.drag(d.original, zone: d.hit.zone, frames: frames, oneSide: event.modifierFlags.contains(.shift))
        onTransitionChange?(d.hit.id, change, d.began)
        d.began = true; d.lastFrames = frames
        transitionState.drag = d
        return true
    }

    func transitionMouseUp(_ p: CGPoint, event: NSEvent) -> Bool {
        guard transitionState.drag != nil else { return false }
        transitionState.drag = nil
        return true
    }

    // MARK: Drop from the Effects panel

    func updateTransitionDrop(kind: TransitionKind, at p: CGPoint) -> Bool {
        let target = TransitionLayout.dropTarget(at: p, kind: kind, in: timeline, geometry: geometry)
        if target != transitionState.dropTarget { transitionState.dropTarget = target; needsDisplay = true }
        return target != nil
    }

    func commitTransitionDrop(kind: TransitionKind, at p: CGPoint) -> Bool {
        guard let t = TransitionLayout.dropTarget(at: p, kind: kind, in: timeline, geometry: geometry) else { return false }
        onDropTransition?(kind, t.track, t.point, t.alignment)
        return true
    }

    // MARK: Cursors

    func addTransitionCursorRects() {
        for row in geometry.rows(for: timeline) {
            guard let track = timeline.track(row.track) else { continue }
            for r in track.resolvedTransitions(frameDuration: timeline.format.frameDuration) {
                let box = TransitionLayout.rect(r, row: row, geometry: geometry)
                let e = TransitionLayout.edgeWidth(forWidth: box.width)
                addCursorRect(CGRect(x: box.minX, y: box.minY, width: e, height: box.height), cursor: .resizeLeftRight)
                addCursorRect(CGRect(x: box.maxX - e, y: box.minY, width: e, height: box.height), cursor: .resizeLeftRight)
                addCursorRect(CGRect(x: box.minX + e, y: box.minY, width: max(box.width - 2 * e, 0), height: box.height), cursor: .openHand)
            }
        }
    }

    // MARK: Drawing

    func drawTransitions(rows: [TrackRow], clip: CGRect) {
        let fd = timeline.format.frameDuration
        for row in rows {
            guard row.maxY > clip.minY, row.y < clip.maxY, let track = timeline.track(row.track), !track.transitions.isEmpty else { continue }
            for r in track.resolvedTransitions(frameDuration: fd) {
                let box = TransitionLayout.rect(r, row: row, geometry: geometry)
                guard box.maxX >= clip.minX, box.minX <= clip.maxX else { continue }
                drawTransition(r, box: box, selected: r.id == transitionState.selected)
            }
        }
        if let t = transitionState.dropTarget, let row = rows.first(where: { $0.track == t.track }) {
            _ = row
            Theme.Colors.accentTint.setFill()
            t.rect.fill()
            Theme.Colors.accent.setStroke()
            let path = NSBezierPath(rect: t.rect.insetBy(dx: 1, dy: 1))
            path.lineWidth = 2
            path.stroke()
        }
    }

    private func drawTransition(_ r: ResolvedTransition, box: CGRect, selected: Bool) {
        let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
        (selected ? Theme.Colors.accentTint : NSColor.black.withAlphaComponent(0.34)).setFill()
        path.fill()
        // The dissolve mark: a diagonal from the incoming to the outgoing side.
        NSColor.white.withAlphaComponent(selected ? 0.9 : 0.55).setStroke()
        let diag = NSBezierPath()
        diag.move(to: CGPoint(x: box.minX + 1, y: box.maxY - 2)); diag.line(to: CGPoint(x: box.maxX - 1, y: box.minY + 2))
        diag.lineWidth = 1
        diag.stroke()
        (selected ? Theme.Colors.accent : NSColor.white.withAlphaComponent(0.7)).setStroke()
        path.lineWidth = selected ? 2 : 1
        path.stroke()
        // Insufficient media: the box is shorter than requested; a small red tick on its right edge says so.
        if r.isClamped {
            Theme.Colors.red.setFill()
            CGRect(x: box.maxX - 3, y: box.minY + 1, width: 2, height: box.height - 2).fill()
        }
        if box.width >= 74, box.height >= 28 {
            let name = r.kind.name as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: Theme.Fonts.clip, .foregroundColor: Theme.Colors.onClip]
            let size = name.size(withAttributes: attrs)
            if size.width + 10 < box.width {
                // Below the clip's name strip, so the two labels never overlap.
                name.draw(at: CGPoint(x: box.midX - size.width / 2, y: box.maxY - size.height - 3), withAttributes: attrs)
            }
        }
    }
}
