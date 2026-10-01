import AppKit
import SQCore

/// State of one opacity rubber band drag (kept in `TimelineView.opacityDrag`).
struct OpacityDrag {
    var gesture: OpacityLineGesture
    var track: Track.ID
    var last: Clip
}

/// Mouse handling of the opacity rubber band on video clips. Selection tool only, rows that are tall enough, clips where
/// the line is shown (selected, keyed, or not at 100 %). Same phases as the volume band, so the host applies both alike.
extension TimelineView {
    /// The video clip, its track and its drawn rectangle under a view point, when the opacity line applies there.
    private func opacityTarget(at p: CGPoint) -> (clip: Clip, track: Track.ID, rect: CGRect)? {
        guard toolState.tool == .selection,
              let row = geometry.rows(for: timeline).first(where: { p.y >= $0.y && p.y < $0.maxY }),
              row.kind == .video, OpacityLine.isAvailable(rowHeight: row.height),
              let track = timeline.track(row.track), !track.isLocked else { return nil }
        guard let clip = track.clips.first(where: { geometry.x(for: $0.timeline.start) - 6 <= p.x && p.x < geometry.x(for: $0.timeline.end) + 6 }),
              OpacityLine.isVisible(clip: clip, selected: selection.contains(clip.id), rowHeight: row.height)
        else { return nil }
        let x0 = geometry.x(for: clip.timeline.start), x1 = geometry.x(for: clip.timeline.end)
        return (clip, track.id, CGRect(x: x0, y: row.y, width: x1 - x0, height: row.height))
    }

    func beginOpacityDrag(at p: CGPoint, event: NSEvent) -> Bool {
        // A transition box sits on the clip edge and wins over the line underneath it.
        if TransitionLayout.hitTest(p, in: timeline, geometry: geometry) != nil { return false }
        guard let t = opacityTarget(at: p),
              let hit = OpacityLine.hit(clip: t.clip, clipRect: t.rect, at: p, geometry: geometry) else { return false }
        let cmd = event.modifierFlags.contains(.command)
        // A plain 100 % line only answers Cmd-click: a drag near the top of the picture must still move the clip.
        let opacity = t.clip.animation.opacity
        if !cmd, !opacity.isAnimated, opacity.value == 1 { return false }
        if case .key = hit, !cmd, VolumeLine.edgeWins(at: p, clipRect: t.rect) { return false }     // trimming wins at the edges
        if case .line = hit, !cmd, case .clip(_, let zone) = geometry.hitTest(p, in: timeline), zone != .body { return false }
        onPointerDown?()
        let g = OpacityLineGesture(clip: t.clip, hit: hit, start: p, clipRect: t.rect, geometry: geometry, addKey: cmd)
        opacityDrag = OpacityDrag(gesture: g, track: t.track, last: t.clip)
        if selection != [t.clip.id] { onSelectionChange?([t.clip.id], []) }
        onOpacityEdit?(t.clip, .began)
        NSCursor.resizeUpDown.set()
        return true
    }

    func updateOpacityDrag(to p: CGPoint) -> Bool {
        guard var d = opacityDrag else { return false }
        let c = d.gesture.update(to: p)
        guard c != d.last else { return true }
        d.last = c
        opacityDrag = d
        var t = timeline
        if (try? t.replaceClip(c)) != nil { setTimeline(t) }
        onOpacityEdit?(c, .changed)
        return true
    }

    func endOpacityDrag(at p: CGPoint) -> Bool {
        guard opacityDrag != nil else { return false }
        _ = updateOpacityDrag(to: p)
        if let d = opacityDrag { onOpacityEdit?(d.last, .ended) }
        opacityDrag = nil
        NSCursor.arrow.set()
        return true
    }
}
