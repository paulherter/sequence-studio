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
    /// Transition layer clip drags (center marker, ends) and the drop on an empty track spot.
    struct LayerDrag {
        var id: Clip.ID
        var zone: TransitionLayerZone
        var startX: CGFloat
        var cut: Time
        /// How far the dragged end has moved so far (the model clamps; the next delta is measured against this).
        var moved: Time = .zero
        var lastFrames: Int64 = 0
        var began = false
    }
    var layerDrag: LayerDrag?
    var layerDrop: TransitionLayerDropTarget?
}

/// Transition boxes: drawing, click / double-click / drag, and the drop target of a transition dragged from the Effects panel.
extension TimelineView {
    // MARK: Selection

    public var selectedTransition: Transition.ID? { transitionState.selected }

    /// Selects a transition (nil clears). Clip selection is cleared like Premiere; the host mirrors it into the session.
    public func setSelectedTransition(_ id: Transition.ID?, notify: Bool = true, keepClips: Bool = false) {
        guard transitionState.selected != id else { return }
        transitionState.selected = id
        if id != nil, !keepClips, !selection.isEmpty || !captionSelection.isEmpty { clearClipSelectionForTransition() }
        if notify { onTransitionSelect?(id, keepClips) }
        needsDisplay = true
    }

    // MARK: Mouse (called from TimelineView before the normal gesture reducer)

    /// True when the press hit a transition box and was handled here.
    func transitionMouseDown(_ p: CGPoint, event: NSEvent) -> Bool {
        // Boxes only answer to the Selection tool: Razor, Ripple, Roll, Slip, Slide... act on the clips beneath them.
        guard toolState.timelineTool == .selection else { return false }
        if transitionLayerMouseDown(p, event: event) { return true }
        guard let hit = TransitionLayout.hitTest(p, in: timeline, geometry: geometry) else { return false }
        setSelectedTransition(hit.id, keepClips: event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command))
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
        if transitionLayerMouseDragged(p, event: event) { return true }
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
        if transitionState.layerDrag != nil { transitionState.layerDrag = nil; return true }
        guard transitionState.drag != nil else { return false }
        transitionState.drag = nil
        return true
    }

    // MARK: Drop from the Effects panel

    func updateTransitionDrop(kind: TransitionKind, at p: CGPoint) -> Bool {
        let target = TransitionLayout.dropTarget(at: p, kind: kind, in: timeline, geometry: geometry)
        let layer = target == nil ? layerDropTarget(kind: kind, at: p) : nil
        if target != transitionState.dropTarget || layer != transitionState.layerDrop {
            transitionState.dropTarget = target; transitionState.layerDrop = layer; needsDisplay = true
        }
        return target != nil || layer != nil
    }

    /// A cut or clip end nearby wins; otherwise a layer kind over an empty spot of a video track becomes a transition layer.
    private func layerDropTarget(kind: TransitionKind, at p: CGPoint) -> TransitionLayerDropTarget? {
        let d = transitionLayerDuration?(kind) ?? timeline.format.frameDuration * 20
        return TransitionLayerLayout.dropTarget(at: p, kind: kind, in: timeline, geometry: geometry, playhead: playhead, duration: d)
    }

    func commitTransitionDrop(kind: TransitionKind, at p: CGPoint) -> Bool {
        guard let t = TransitionLayout.dropTarget(at: p, kind: kind, in: timeline, geometry: geometry) else {
            guard let l = layerDropTarget(kind: kind, at: p) else { return false }
            onDropTransitionLayer?(kind, l)
            return true
        }
        if kind.isElement {
            switch t.point {
            case .head(let c): onDropElementTransition?(kind, t.track, c, t.bothEnds ? [.head, .tail] : [.head])
            case .tail(let c): onDropElementTransition?(kind, t.track, c, [.tail])
            case .cut: return false
            }
            return true
        }
        onDropTransition?(kind, t.track, t.point, t.alignment)
        return true
    }

    // MARK: Cursors

    func addTransitionCursorRects() {
        let fd = timeline.format.frameDuration
        for row in geometry.rows(for: timeline) {
            guard let track = drawTrack(row.track) else { continue }
            if row.kind == .video, !track.isLocked {
                for c in track.clips where c.isTransitionLayer {
                    guard let r = c.resolvedTransitionLayer(frameDuration: fd) else { continue }
                    let x0 = geometry.x(for: r.span.start), x1 = geometry.x(for: r.span.end), e = TransitionLayerLayout.edgeWidth(forWidth: x1 - x0)
                    let m = TransitionLayerLayout.markerReach, cx = geometry.x(for: r.cut)
                    addCursorRect(CGRect(x: x0, y: row.y, width: e, height: row.height), cursor: .resizeLeftRight)
                    addCursorRect(CGRect(x: x1 - e, y: row.y, width: e, height: row.height), cursor: .resizeLeftRight)
                    addCursorRect(CGRect(x: cx - m, y: row.y, width: 2 * m, height: row.height), cursor: .resizeLeftRight)
                }
            }
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
            guard row.maxY > clip.minY, row.y < clip.maxY, let track = drawTrack(row.track), !track.transitions.isEmpty else { continue }
            for r in track.resolvedTransitions(frameDuration: fd) {
                let box = TransitionLayout.rect(r, row: row, geometry: geometry)
                guard box.maxX >= clip.minX, box.minX <= clip.maxX else { continue }
                drawTransition(r, box: box, selected: r.id == transitionState.selected)
            }
        }
        drawTransitionLayers(rows: rows, clip: clip)
        if let l = transitionState.layerDrop {
            drawDropBox(l.rect)
            drawCutMarker(x: geometry.x(for: l.cut), y: l.rect.minY, height: l.rect.height, selected: true)
        }
        if let t = transitionState.dropTarget, let row = rows.first(where: { $0.track == t.track }) {
            _ = row
            for rect in [t.rect] + (t.tailRect.map { [$0] } ?? []) {
                Theme.Colors.accentTint.setFill()
                rect.fill()
                Theme.Colors.accent.setStroke()
                let path = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
                path.lineWidth = 2
                path.stroke()
            }
        }
    }

    /// The parts of a transition box that show a held edge frame (box-relative x ranges, before and after the cut).
    static func heldHatchRects(_ r: ResolvedTransition, box: CGRect) -> [CGRect] {
        let total = Double(r.frames)
        guard total > 0, r.isHeld else { return [] }
        let fd = r.frameDuration
        let before = Double(r.before.frameIndex(frameDuration: fd)), after = Double(r.after.frameIndex(frameDuration: fd))
        let cutX = box.minX + box.width * CGFloat(before / total)
        var out: [CGRect] = []
        if r.heldBefore > 0 {
            let w = box.width * CGFloat(Double(r.heldBefore) / total)
            out.append(CGRect(x: cutX - w, y: box.minY, width: w, height: box.height))
        }
        if r.heldAfter > 0 {
            let w = box.width * CGFloat(min(Double(r.heldAfter), after) / total)
            out.append(CGRect(x: cutX, y: box.minY, width: w, height: box.height))
        }
        return out
    }

    private func drawHeldHatch(_ r: ResolvedTransition, box: CGRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let stripes = NSBezierPath()
        for area in Self.heldHatchRects(r, box: box) {
            NSBezierPath(rect: area.insetBy(dx: 0, dy: 1)).addClip()
            var x = area.minX - area.height
            while x < area.maxX {
                stripes.move(to: CGPoint(x: x, y: area.minY)); stripes.line(to: CGPoint(x: x + area.height, y: area.maxY))
                x += 5
            }
            Theme.TimelineSkin.transitionIssue.setStroke()
            stripes.lineWidth = 1
            stripes.stroke()
            stripes.removeAllPoints()
            NSGraphicsContext.restoreGraphicsState(); NSGraphicsContext.saveGraphicsState()
        }
    }

    private func drawTransition(_ r: ResolvedTransition, box: CGRect, selected: Bool) {
        let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: Theme.Radius.small, yRadius: Theme.Radius.small)
        Theme.Colors.clipShade.setFill()
        path.fill()
        // The dissolve mark: a diagonal from the incoming to the outgoing side.
        (selected ? Theme.Colors.onClip : Theme.Colors.label2).setStroke()
        let diag = NSBezierPath()
        diag.move(to: CGPoint(x: box.minX + 1, y: box.maxY - 2)); diag.line(to: CGPoint(x: box.maxX - 1, y: box.minY + 2))
        diag.lineWidth = 1
        diag.stroke()
        (selected ? Theme.Selection.outline : Theme.Colors.label2).setStroke()
        path.lineWidth = selected ? Theme.Selection.outlineWidth : 1
        path.stroke()
        // Repeated frames (no media beyond the cut, Premiere's striped warning): red hatch over the part that holds an
        // edge frame, before the cut (incoming held) and / or after it (outgoing held).
        if r.isHeld { drawHeldHatch(r, box: box) }
        // Insufficient media: the box is shorter than requested; a small red tick on its right edge says so.
        if r.isClamped {
            Theme.Colors.red.setFill()
            CGRect(x: box.maxX - 3, y: box.minY + 1, width: 2, height: box.height - 2).fill()
        }
        if box.width >= 74, box.height >= 28 {
            let name = r.kind.name as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: Theme.Typography.caption, .foregroundColor: Theme.Colors.onClip]
            let size = name.size(withAttributes: attrs)
            if size.width + 10 < box.width {
                // Below the clip's name strip, so the two labels never overlap.
                name.draw(at: CGPoint(x: box.midX - size.width / 2, y: box.maxY - size.height - 3), withAttributes: attrs)
            }
        }
    }
}
