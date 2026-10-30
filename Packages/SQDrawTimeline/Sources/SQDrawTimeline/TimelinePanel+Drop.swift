import Foundation
import SQCore
import SQDrawKit
import SQTimelineUI
import SQUIKit

/// Media dragged in from the Project panel: the ghost clips, the ghost "new track" strips, the snap line and the insert
/// arrow, translated from TimelineView's dragging and `drawDropPreview` with the same `DropPreview`. The host drives it
/// (its drag source knows the items): `dropHover` per pointer move, `dropCommit` on release, `dropExit` when it leaves.
extension TimelinePanel {
    /// The pointer (window pixels) over the panel during a drag of `items`; Command = insert. `canCreateTracks` for
    /// Project-panel media and sequences (they may land on the ghost strips under the last track).
    public mutating func dropHover(items: [DropItem], x: Float, y: Float, insert: Bool, canCreateTracks: Bool = true,
                                   streams: SourceStreams = .both) {
        if !dropPreview.isActive {
            dropPreview.begin(items: items.isEmpty ? [DropItem(name: "", duration: Time(seconds: 5))] : items,
                              canCreateTracks: canCreateTracks, streams: streams)
            geometry.reservesGhostSpace = canCreateTracks       // two ghost rows under the last track, only during the drag
        }
        dropPreview.update(point: point(x: x, y: y), insert: insert, timeline: timeline, geometry: geometry,
                           snapping: toolState.snapping, playhead: playhead)
    }

    /// Left the panel or Esc: the ghost goes, nothing changed.
    public mutating func dropExit() {
        guard dropPreview.isActive else { return }
        dropPreview.cancel()
        geometry.reservesGhostSpace = false
        clampScroll()
    }

    /// Released over the panel: the media lands where the ghost showed (one undo step, the Mac `onDropMedia` /
    /// `onDropMediaOnGhost`). Empty when there is no target.
    /// The clip under a host point (device pixels), for a Replace drop.
    public func clipID(x: Float, y: Float) -> Clip.ID? {
        guard frame.contains(x, y), case .clip(let id, _) = geometry.hitTest(point(x: x, y: y), in: timeline) else { return nil }
        return id
    }

    public mutating func dropCommit(media ids: [UUID], x: Float, y: Float, insert: Bool) -> [TimelineAction] {
        defer { dropExit() }
        dropHover(items: [], x: x, y: y, insert: insert)
        guard let target = dropPreview.commitTarget else { return [] }
        return [.dropMedia(ids, time: target.time, track: dropPreview.commitGhostKind == nil ? target.track : nil,
                           newTrack: dropPreview.commitGhostKind, insert: target.insert, streams: dropPreview.streams)]
    }

    func drawDropPreview(_ cv: inout Canvas, rows: [TrackRow], clip: CGRect) {
        guard dropPreview.isActive else { return }
        let ghostRows = dropPreview.canCreateTracks ? geometry.ghostRows(for: timeline) : []
        for gr in ghostRows {
            let hot = dropPreview.ghostKind == gr.kind
            let r = CGRect(x: TimelineGeometry.toolColumnWidth + 2, y: gr.y + 1,
                           width: max(clip.maxX - TimelineGeometry.toolColumnWidth - 4, 0), height: gr.height - 2)
            cv.fill(r, hot ? skin.accentTint : skin.fill2)
            cv.strokeDashed(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), radius: DrawTheme.Radius.small.cg, width: 1, on: 4, off: 3,
                            hot ? theme.accent : theme.label3)
            let title = gr.kind == .video ? "Drop here to add a video track" : "Drop here to add an audio track"
            cv.draw(SQL10n.string(title), at: CGPoint(x: TimelineGeometry.contentOriginX + 8, y: r.midY - 6),
                    fontSize: CGFloat(DrawTheme.TypeSize.caption), hot ? theme.accent : theme.label3)
        }
        for g in dropPreview.ghosts {
            let rowY: CGFloat, rowH: CGFloat
            if g.onGhostRow, let gr = ghostRows.first(where: { $0.kind == g.kind }) {
                rowY = gr.y; rowH = gr.height
            } else if let row = rows.first(where: { $0.track == g.track }) {
                rowY = row.y; rowH = row.height
            } else if let n = g.newTrackOrdinal {
                let audio = rows.filter { $0.kind == .audio }      // an audio track the drop creates: below the last audio row
                let last = audio.last ?? rows.last
                rowH = last?.height ?? 40
                rowY = (last?.maxY ?? TimelineGeometry.rulerHeight) + CGFloat(max(n - audio.count, 0)) * rowH
            } else { continue }
            let r = CGRect(x: geometry.x(for: g.range.start), y: rowY, width: max(geometry.width(of: g.range.duration), 2), height: rowH - 1)
            cv.fill(roundedRect: r, radius: DrawTheme.Radius.small.cg,
                    theme.clip(g.kind == .audio ? .audioDefault : .videoDefault).alpha(0.55))   // `clipGhostAlpha`
            cv.strokeDashed(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), radius: DrawTheme.Radius.small.cg, width: 1, on: 4, off: 3,
                            theme.accent)
        }
        if let t = dropPreview.snapTime {
            cv.fill(CGRect(x: geometry.x(for: t).rounded() - 0.5, y: clip.minY, width: 1, height: clip.height), skin.snapLine)
        }
        if dropPreview.insert, let first = dropPreview.ghosts.first, let row = rows.first(where: { $0.track == first.track }) {
            let x = geometry.x(for: dropPreview.start), cy = row.y + row.height / 2   // the ripple arrow at the insert point
            cv.fill(polygon: [CGPoint(x: x, y: cy - 7), CGPoint(x: x + 9, y: cy), CGPoint(x: x, y: cy + 7)], theme.accent)
        }
    }
}
