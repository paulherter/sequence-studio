import AppKit
import SQCore

/// G1 Keystones on the timeline: the drop ghost (where and how long a dragged keystone lands on the clip under the
/// pointer) and the bar of the keystone applied last, whose edges stretch it (keys follow live, one undo step on release).
extension TimelineView {
    // MARK: Drop

    /// The video clip under `p` and its row, when a keystone may land there.
    private func keystoneTarget(at p: CGPoint) -> (clip: Clip, row: TrackRow)? {
        guard let row = layoutRows().first(where: { p.y >= $0.y && p.y < $0.maxY }), row.kind == .video,
              let track = timeline.track(row.track), !track.isLocked else { return nil }
        let t = geometry.unsnappedTime(atX: p.x)
        guard let c = track.clips.first(where: { $0.timeline.start <= t && t < $0.timeline.end }) else { return nil }
        return (c, row)
    }

    /// Updates the ghost for a keystone drag; nil when the drag carries no keystone.
    func updateKeystoneDrop(_ info: NSDraggingInfo) -> NSDragOperation? {
        guard let k = KeystoneDrag.read(from: info.draggingPasteboard) else { return nil }
        let p = convert(info.draggingLocation, from: nil)
        var ghost: KeystoneBar?
        if let t = keystoneTarget(at: p) {
            let local = geometry.unsnappedTime(atX: p.x) - t.clip.timeline.start
            ghost = KeystoneBar(clip: t.clip.id, span: k.placement(dropAt: local, clipDuration: t.clip.timeline.duration), name: k.name)
        }
        if ghost != keystoneGhost { keystoneGhost = ghost; needsDisplay = true }
        return ghost == nil ? [] : .copy
    }

    /// Commits a keystone drop; nil when the drag carries no keystone.
    func performKeystoneDrop(_ info: NSDraggingInfo) -> Bool? {
        guard let k = KeystoneDrag.read(from: info.draggingPasteboard) else { return nil }
        _ = updateKeystoneDrop(info)
        guard let g = keystoneGhost else { return false }
        keystoneGhost = nil
        onDropKeystone?(k, g.clip, g.span)
        return true
    }

    // MARK: Edge drag

    private func barRect(_ bar: KeystoneBar) -> (rect: CGRect, clip: Clip, track: Track.ID)? {
        for row in layoutRows() where row.kind == .video && row.height >= KeystoneBar.minimumRowHeight {
            if let c = timeline.track(row.track)?.clips.first(where: { $0.id == bar.clip }) {
                guard bar.span.end <= c.timeline.duration else { return nil }      // the clip was trimmed under it
                return (KeystoneBar.rect(span: bar.span, clipStart: c.timeline.start, row: row, geometry: geometry), c, row.track)
            }
        }
        return nil
    }

    func beginKeystoneDrag(at p: CGPoint) -> Bool {
        guard toolState.timelineTool == .selection, let bar = keystoneBar, let r = barRect(bar),
              timeline.track(r.track)?.isLocked == false,
              let edge = KeystoneBar.edge(at: p, barRect: r.rect) else { return false }
        onPointerDown?()
        keystoneDrag = KeystoneEdgeDrag(bar: bar, edge: edge, original: r.clip, current: bar.span)
        NSCursor.resizeLeftRight.set()
        return true
    }

    func updateKeystoneDrag(to p: CGPoint) -> Bool {
        guard var d = keystoneDrag else { return false }
        let local = geometry.unsnappedTime(atX: p.x) - d.original.timeline.start
        let span = KeystoneBar.dragged(d.bar.span, edge: d.edge, toLocal: local.snapped(to: timeline.frameDuration),
                                       clipDuration: d.original.timeline.duration, minimum: timeline.frameDuration)
        guard span != d.current else { return true }
        d.current = span
        keystoneDrag = d
        var c = d.original
        c.restretchKeystone(d.bar.span, to: span)
        var t = timeline
        if (try? t.replaceClip(c)) != nil { setTimeline(t) }
        keystoneBar = KeystoneBar(clip: d.bar.clip, span: span, name: d.bar.name)
        return true
    }

    func endKeystoneDrag(at p: CGPoint) -> Bool {
        guard keystoneDrag != nil else { return false }
        _ = updateKeystoneDrag(to: p)
        if let d = keystoneDrag, d.current != d.bar.span { onRestretchKeystone?(d.bar.clip, d.bar.span, d.current) }
        keystoneDrag = nil
        NSCursor.arrow.set()
        return true
    }

    /// Resize cursor over a bar edge. True when it set one.
    func updateKeystoneCursor(at p: CGPoint) -> Bool {
        guard toolState.timelineTool == .selection, let bar = keystoneBar, let r = barRect(bar),
              KeystoneBar.edge(at: p, barRect: r.rect) != nil else { return false }
        NSCursor.resizeLeftRight.set()
        return true
    }

    // MARK: Drawing

    func drawKeystoneOverlay(clip: CGRect) {
        if let bar = keystoneBar, let r = barRect(bar) { drawBar(r.rect, name: bar.name, ghost: false) }
        if let g = keystoneGhost,
           let row = layoutRows().first(where: { r in timeline.track(r.track)?.clips.contains { $0.id == g.clip } ?? false }),
           let c = timeline.track(row.track)?.clips.first(where: { $0.id == g.clip }) {
            let x0 = geometry.x(for: c.timeline.start), x1 = geometry.x(for: c.timeline.end)
            Theme.Colors.accent.setStroke()
            let outline = NSBezierPath(rect: CGRect(x: x0, y: row.y, width: x1 - x0, height: row.height - 1).insetBy(dx: 1, dy: 1))
            outline.lineWidth = 1
            outline.stroke()
            var r = KeystoneBar.rect(span: g.span, clipStart: c.timeline.start, row: row, geometry: geometry)
            if row.height < KeystoneBar.minimumRowHeight { r = CGRect(x: r.minX, y: row.y + 1, width: r.width, height: row.height - 3) }
            drawBar(r, name: g.name, ghost: true)
        }
    }

    private func drawBar(_ r: CGRect, name: String, ghost: Bool) {
        let path = NSBezierPath(roundedRect: r, xRadius: Theme.Radius.small, yRadius: Theme.Radius.small)
        (ghost ? Theme.Colors.accentTint : Theme.Colors.accentTint).setFill()
        path.fill()
        Theme.Colors.accent.setStroke()
        path.lineWidth = 1
        path.stroke()
        if !ghost {
            // Edge grips.
            Theme.Colors.onClip.setFill()
            for x in [r.minX + 2, r.maxX - 4] where r.width > 10 {
                NSBezierPath(roundedRect: CGRect(x: x, y: r.minY + 2, width: 2, height: r.height - 4), xRadius: Theme.Radius.small, yRadius: Theme.Radius.small).fill()
            }
        }
        guard r.width > 30 else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.Typography.captionStrong,
                                                    .foregroundColor: Theme.Colors.onClip]
        let s = NSAttributedString(string: name, attributes: attrs)
        let size = s.size()
        let tr = CGRect(x: r.minX + 7, y: r.midY - size.height / 2, width: min(size.width, r.width - 14), height: size.height)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: tr).addClip()
        s.draw(at: tr.origin)
        NSGraphicsContext.restoreGraphicsState()
    }
}
