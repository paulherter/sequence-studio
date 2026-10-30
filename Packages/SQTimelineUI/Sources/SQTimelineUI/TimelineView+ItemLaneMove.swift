import AppKit
import SQCore

// Lane drag-out: a drag of a lane name (header) moves its layer. Within the Graphic it reorders (vertical drag between
// the lanes); onto the lanes or the clip of another Graphic it moves the layer there; onto a free stretch of another video
// track it becomes a new Graphic. Option copies. The layer keeps the times it shows in (SQCore `moveGraphicsLayers`).
// While dragging, a ghost of the lane name follows the pointer and the target shows an insertion line or a dashed clip.

/// Where a dragged layer would land.
enum ItemLaneDropTarget: Equatable {
    /// Inside its own Graphic: `gap` counts lanes from the top (0 = above the top lane).
    case reorder(gap: Int)
    /// Another Graphic: `gap` as above, nil = on top.
    case graphic(Clip.ID, gap: Int?)
    case newGraphic(Track.ID)
}

/// A press on a lane name that may become a move.
struct ItemLaneMove {
    var clip: Clip
    /// Bottom first, as in the document.
    var ids: [UUID]
    var name: String
    var startY: CGFloat
    var pointer: CGPoint
    var moved = false
    var copy = false
    var target: ItemLaneDropTarget?
    /// Where the target shows (an insertion line, or the dashed outline of the new Graphic).
    var indicator: CGRect?
}

extension TimelineView {
    func beginItemLaneMove(clip: Clip, item: UUID, at p: CGPoint) {
        guard toolState.timelineTool == .selection, let doc = clip.graphics, let layer = doc.layer(item), !layer.isLocked,
              timeline.tracks.first(where: { t in t.clips.contains { $0.id == clip.id } })?.isLocked == false else { return }
        let ids = itemLanes.selectedClip == clip.id && itemLanes.selectedItems.contains(item)
            ? doc.layers.map(\.id).filter { itemLanes.selectedItems.contains($0) } : [item]
        itemLanes.move = ItemLaneMove(clip: clip, ids: ids, name: layer.name, startY: p.y, pointer: p)
    }

    func updateItemLaneMove(to p: CGPoint, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard var m = itemLanes.move else { return false }
        if !m.moved {
            guard abs(p.y - m.startY) >= ItemLanes.dragSlop else { return true }
            m.moved = true
            onPointerDown?()
        }
        m.pointer = p
        m.copy = modifiers.contains(.option)
        let hit = itemLaneDropTarget(at: p, move: m)
        m.target = hit?.target
        m.indicator = hit?.indicator
        itemLanes.move = m
        setNeedsDisplay(bounds)
        return true
    }

    func endItemLaneMove(at p: CGPoint, modifiers: NSEvent.ModifierFlags) {
        guard itemLanes.move != nil else { return }
        if itemLanes.move?.moved == true { _ = updateItemLaneMove(to: p, modifiers: modifiers) }
        if let m = itemLanes.move, m.moved, let target = m.target { commitItemLaneMove(m, target) }
        cancelItemLaneMove()
    }

    func cancelItemLaneMove() {
        guard itemLanes.move != nil else { return }
        itemLanes.move = nil
        itemLanes.swallowing = false
        setNeedsDisplay(bounds)
    }

    private func commitItemLaneMove(_ m: ItemLaneMove, _ target: ItemLaneDropTarget) {
        switch target {
        case .reorder(let gap):
            guard !m.copy, let doc = m.clip.graphics else { return }
            let moving = Set(m.ids)
            let above = doc.layers.reversed().prefix(gap).filter { !moving.contains($0.id) }.count
            let rest = doc.layers.count - moving.count
            onItemLaneReorder?(m.clip.id, m.ids, rest - above)
        case .graphic(let id, let gap):
            let count = timeline.tracks.lazy.flatMap(\.clips).first { $0.id == id }?.graphics?.layers.count ?? 0
            onItemLaneMoveOut?(m.clip.id, m.ids, .graphic(id, index: gap.map { count - $0 }), m.copy)
        case .newGraphic(let track):
            onItemLaneMoveOut?(m.clip.id, m.ids, .newGraphic(track: track), m.copy)
        }
    }

    /// The drop under the pointer, nil when the layers cannot land there (nothing is highlighted then).
    func itemLaneDropTarget(at p: CGPoint, move m: ItemLaneMove) -> (target: ItemLaneDropTarget, indicator: CGRect)? {
        guard p.x >= TimelineGeometry.toolColumnWidth, p.y >= TimelineGeometry.rulerHeight, let doc = m.clip.graphics else { return nil }
        let spans = doc.extractedCopies(m.ids, clipStart: m.clip.timeline.start, clipDuration: m.clip.timeline.duration).map(\.span)
        guard let from = spans.map(\.start).min(), let to = spans.map(\.end).max() else { return nil }
        let union = TimeRange(start: from, end: max(to, from + timeline.frameDuration))
        for row in layoutRows() where p.y >= row.y && p.y < row.bottom {
            guard row.kind == .video, let track = drawTrack(row.track), !track.isLocked else { return nil }
            if p.y >= row.maxY {
                guard let c = openItemLaneClip(on: track), let d = c.graphics else { return nil }
                let gap = min(max(Int(((p.y - row.maxY) / ItemLanes.laneHeight).rounded()), 0), d.layers.count)
                let line = CGRect(x: TimelineGeometry.toolColumnWidth, y: row.maxY + CGFloat(gap) * ItemLanes.laneHeight - 1,
                                  width: max(geometry.x(for: c.timeline.end) - TimelineGeometry.toolColumnWidth, 0), height: 2)
                if c.id == m.clip.id { return m.copy ? nil : (.reorder(gap: gap), line) }
                guard spans.allSatisfy({ $0.overlaps(c.timeline) }) else { return nil }
                return (.graphic(c.id, gap: gap), line)
            }
            if let c = track.clips.first(where: { geometry.x(for: $0.timeline.start) <= p.x && p.x < geometry.x(for: $0.timeline.end) }) {
                guard c.isGraphics, c.id != m.clip.id, spans.allSatisfy({ $0.overlaps(c.timeline) }) else { return nil }
                return (.graphic(c.id, gap: nil), CGRect(x: geometry.x(for: c.timeline.start), y: row.y,
                                                         width: geometry.width(of: c.timeline.duration), height: row.height - 1))
            }
            guard !track.clips.contains(where: { $0.timeline.overlaps(union) }) else { return nil }
            return (.newGraphic(track.id), CGRect(x: geometry.x(for: union.start), y: row.y,
                                                  width: max(geometry.width(of: union.duration), 2), height: row.height - 1))
        }
        return nil
    }

    /// The drop ghost: the target (insertion line or dashed clip) and the lane name under the pointer.
    func drawItemLaneMoveGhost() {
        guard let m = itemLanes.move, m.moved, let cg = NSGraphicsContext.current?.cgContext else { return }
        if let r = m.indicator {
            if r.height <= 2 { cg.setFillColor(Theme.Colors.accent.cgColor); cg.fill(r) }   // an insertion line
            else {
                Theme.Colors.clipVideo.withAlphaComponent(Theme.OnPicture.clipGhostAlpha).setFill()
                NSBezierPath(roundedRect: r, xRadius: Theme.Radius.small, yRadius: Theme.Radius.small).fill()
                Theme.Colors.accent.setStroke()
                let outline = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: Theme.Radius.small, yRadius: Theme.Radius.small)
                outline.lineWidth = 1
                outline.setLineDash([4, 3], count: 2, phase: 0)
                outline.stroke()
            }
        }
        let chip = CGRect(x: m.pointer.x - TimelineGeometry.headerWidth / 2, y: m.pointer.y - ItemLanes.laneHeight / 2,
                          width: TimelineGeometry.headerWidth, height: ItemLanes.laneHeight)
        let alpha = m.target == nil ? Theme.OnPicture.clipGhostAlpha / 2 : Theme.OnPicture.clipGhostAlpha
        Theme.Colors.accent.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: chip, xRadius: Theme.Radius.small, yRadius: Theme.Radius.small).fill()
        let label = m.ids.count > 1 ? "\(m.name) +\(m.ids.count - 1)" : m.name
        (label as NSString).draw(at: CGPoint(x: chip.minX + Theme.Spacing.sm, y: chip.minY + 3),
                                 withAttributes: [.font: Theme.Typography.body, .foregroundColor: Theme.Colors.label])
    }
}
