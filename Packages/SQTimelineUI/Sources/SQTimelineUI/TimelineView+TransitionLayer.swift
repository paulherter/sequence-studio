import AppKit
import SQCore

/// Transition layer clips (DECISIONS 2026-10-05) on the timeline: the center marker (the cut), its drag, the end drags
/// (symmetric around the cut; Option = this end only) and the lead-in / lead-out ramp drawn over the clip.
extension TimelineView {
    private var layerSnapping: Bool { toolState.snapping != interaction.snapInverted }

    /// True when the press hit a transition layer's center marker or end and was handled here (the body falls through to the
    /// normal clip gestures: select, move).
    func transitionLayerMouseDown(_ p: CGPoint, event: NSEvent) -> Bool {
        guard event.clickCount == 1, let hit = TransitionLayerLayout.hitTest(p, in: timeline, geometry: geometry),
              let r = timeline.resolvedTransitionLayer(hit.id) else { return false }
        setSelectedTransition(nil, notify: true)
        if selection != [hit.id] { onSelectionChange?([hit.id], []) }
        let edge: Time = hit.zone == .head ? r.span.start : hit.zone == .tail ? r.span.end : r.cut
        transitionState.layerDrag = TransitionViewState.LayerDrag(id: hit.id, zone: hit.zone, startX: p.x, cut: edge)
        return true
    }

    func transitionLayerMouseDragged(_ p: CGPoint, event: NSEvent) -> Bool {
        guard var d = transitionState.layerDrag else { return false }
        if !d.began && abs(p.x - d.startX) < TimelineInteraction.dragThreshold { return true }
        let fd = timeline.format.frameDuration
        let frames = (geometry.time(atX: p.x) - geometry.time(atX: d.startX)).frameIndex(frameDuration: fd)
        var target = d.cut + fd * frames
        if layerSnapping, let track = timeline.tracks.first(where: { $0.clips.contains { $0.id == d.id } }) {
            target = TransitionLayerLayout.snapped(target, to: TransitionLayerLayout.snapTimes(below: track.id, in: timeline, playhead: playhead),
                                                   geometry: geometry)
        }
        let key = target.frameIndex(frameDuration: fd)
        if d.began && key == d.lastFrames { return true }
        switch d.zone {
        case .cut:
            onTransitionLayerCut?(d.id, target, d.began)
        case .head, .tail:
            let edge: ClipEdge = d.zone == .head ? .head : .tail
            let delta = (target - d.cut) - d.moved
            if delta != .zero, let moved = onTransitionLayerResize?(d.id, edge, delta, !event.modifierFlags.contains(.option), d.began) {
                d.moved = d.moved + moved
            }
        }
        d.began = true; d.lastFrames = key
        transitionState.layerDrag = d
        return true
    }

    // MARK: Drawing

    func drawTransitionLayers(rows: [TrackRow], clip: CGRect) {
        let fd = timeline.format.frameDuration
        for row in rows where row.kind == .video {
            guard row.maxY > clip.minY, row.y < clip.maxY, let track = drawTrack(row.track) else { continue }
            for c in track.clips where c.isTransitionLayer {
                guard let r = c.resolvedTransitionLayer(frameDuration: fd) else { continue }
                let x0 = geometry.x(for: r.span.start), x1 = geometry.x(for: r.span.end)
                guard x1 >= clip.minX, x0 <= clip.maxX else { continue }
                let selected = selection.contains(c.id)
                let box = CGRect(x: x0, y: row.y + 1, width: x1 - x0, height: max(row.height - 2, 1))
                let cx = geometry.x(for: r.cut)
                // Lead-in rises to the cut, lead-out falls from it: the shape of the mix.
                let ramp = NSBezierPath()
                ramp.move(to: CGPoint(x: box.minX, y: box.maxY - 2))
                ramp.line(to: CGPoint(x: cx, y: box.minY + 2))
                ramp.line(to: CGPoint(x: box.maxX, y: box.maxY - 2))
                ramp.lineWidth = 1
                (selected ? Theme.Colors.onClip : Theme.Colors.label2).setStroke()
                ramp.stroke()
                if selected {
                    Theme.Colors.onClip.setFill()
                    CGRect(x: box.minX + 1, y: box.minY + 3, width: 2, height: box.height - 6).fill()
                    CGRect(x: box.maxX - 3, y: box.minY + 3, width: 2, height: box.height - 6).fill()
                }
                drawCutMarker(x: cx, y: box.minY, height: box.height, selected: selected)
            }
        }
    }

    /// The center marker: a line through the row with a small downward triangle on top.
    func drawCutMarker(x: CGFloat, y: CGFloat, height: CGFloat, selected: Bool) {
        let color = selected ? Theme.Colors.accent : Theme.Colors.label
        color.setFill()
        CGRect(x: x - 1, y: y, width: 2, height: height).fill()
        let tri = NSBezierPath()
        tri.move(to: CGPoint(x: x - 5, y: y)); tri.line(to: CGPoint(x: x + 5, y: y)); tri.line(to: CGPoint(x: x, y: y + 6))
        tri.close()
        tri.fill()
    }

    func drawDropBox(_ rect: CGRect) {
        Theme.Colors.accentTint.setFill()
        rect.fill()
        Theme.Colors.accent.setStroke()
        let path = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        path.stroke()
    }
}
