import Foundation
import SQCore
import SQDrawKit
import SQEditorSession
import SQTimelineUI

/// Fast Cut marks and the attach drag, translated from ClipDrawing+MagneticHint.swift and TimelineView+AttachDrag.swift:
/// the same `FastCutMarks` / `AttachPointDrag` geometry; `onSetAttachPoint` becomes `.setAttachPoint` (one undo step).
extension TimelinePanel {
    /// The main track's row while the sequence is magnetic.
    func fastCutMainRow(_ rows: [TrackRow]) -> TrackRow? {
        guard timeline.isFastCut, let id = timeline.mainTrackID else { return nil }
        return rows.first { $0.track == id }
    }

    /// `drawSpacer`: thin diagonal hatch in the lane line color, framed by a 1 pt outline.
    func drawSpacers(_ cv: inout Canvas, track: Track, row: TrackRow, clip: CGRect) {
        for r in FastCutMarks.spacers(on: track) {
            let x0 = geometry.x(for: r.start), x1 = geometry.x(for: r.end)
            guard x1 >= clip.minX, x0 <= clip.maxX, x1 - x0 >= 2, row.height >= 4 else { continue }
            let body = CGRect(x: x0, y: row.y, width: x1 - x0, height: row.height).insetBy(dx: 0.5, dy: 1.5)
            let vis = body.intersection(clip)
            guard !vis.isNull, vis.width > 0 else { continue }
            cv.saveGState()
            cv.clip(to: vis)
            let step: CGFloat = 6, h = body.height, origin = body.minX - h
            var x = origin + step * max(0, ((vis.minX - h - origin) / step).rounded(.down))
            while x <= vis.maxX {
                cv.strokeLine(from: CGPoint(x: x, y: body.maxY), to: CGPoint(x: x + h, y: body.minY), width: 1, theme.trackRowLine)
                x += step
            }
            cv.restoreGState()
            cv.stroke(roundedRect: CGRect(x: max(body.minX, clip.minX - 2), y: body.minY,
                                          width: min(body.maxX, clip.maxX + 2) - max(body.minX, clip.minX - 2), height: h),
                      radius: 0, width: 1, theme.trackRowLine)
        }
    }

    /// `drawMagneticHint`: the host of a selected attached clip gets a faint accent tint and a bracket along its lower edge.
    func drawMagneticHint(_ cv: inout Canvas, rect: CGRect) {
        guard rect.width >= 8, rect.height >= 12 else { return }
        cv.fill(roundedRect: rect.insetBy(dx: 1, dy: 1), radius: DrawTheme.Radius.small.cg, theme.accent.alpha(0.12))
        let inset: CGFloat = 3, tick: CGFloat = 4
        let y = rect.maxY - 3, x0 = rect.minX + inset, x1 = rect.maxX - inset
        cv.strokePolyline([CGPoint(x: x0, y: y - tick), CGPoint(x: x0, y: y), CGPoint(x: x1, y: y), CGPoint(x: x1, y: y - tick)],
                          width: 1.5, theme.accent.alpha(0.85))
    }

    /// `drawAttachThread`: the line from the attached clip to its host plus the triangle on the host edge.
    func drawAttachThread(_ cv: inout Canvas, clipRect: CGRect, x: CGFloat, main: TrackRow) {
        guard let g = FastCutMarks.attachThreadGeometry(clipRect: clipRect, x: x, hostMinY: main.y, hostMaxY: main.maxY)
                ?? FastCutMarks.attachMarker(clipRect: clipRect, x: x, hostMinY: main.y, hostMaxY: main.maxY) else { return }
        let color = theme.accent.alpha(0.85)
        if g.from != g.to { cv.strokeLine(from: g.from, to: g.to, width: 1, color) }
        cv.fill(polygon: g.triangle, color)
    }

    // MARK: Attach drag and Cmd+Opt click

    /// `beginAttachDrag`: Selection tool, no modifier, on a thread (a trim edge under it keeps its trim meaning).
    mutating func attachDown(_ p: CGPoint, modifiers mods: InputModifiers) -> Bool {
        guard toolState.timelineTool == .selection, timeline.isFastCut,
              mods.intersection([.command, .option, .shift]).isEmpty,
              let id = AttachPointDrag.hit(at: p, in: timeline, geometry: geometry) else { return false }
        if case .clip(_, let zone) = geometry.hitTest(p, in: timeline), zone != .body { return false }
        let c = timeline.tracks.lazy.flatMap(\.clips).first { $0.id == id }
        gesture = .attach(clip: id, original: timeline, time: c.map { $0.start + ($0.attachment?.point ?? .zero) } ?? .zero)
        return true
    }

    /// `updateAttachDrag`: previews the new attach point on a copy of the timeline.
    mutating func attachDragged(to p: CGPoint) {
        guard case .attach(let id, let original, let time)? = gesture,
              let t = AttachPointDrag.target(x: p.x, clip: id, in: original, geometry: geometry, playhead: playhead, snapping: snapping),
              t != time else { return }
        var preview = original
        if (try? preview.setAttachPoint(id, at: t)) != nil {
            gesture = .attach(clip: id, original: original, time: t)
            timeline = preview
        }
    }

    /// `endAttachDrag`: reports once when the point moved; the session's edit brings the new timeline back.
    mutating func attachUp(at p: CGPoint) -> [TimelineAction] {
        attachDragged(to: p)
        guard case .attach(let id, let original, let time)? = gesture else { return [] }
        timeline = original
        let c = original.tracks.lazy.flatMap(\.clips).first { $0.id == id }
        guard let c, c.start + (c.attachment?.point ?? .zero) != time else { return [] }
        return [.setAttachPoint(clip: id, time: time)]
    }

    /// `attachPointClick`: Cmd+Opt+click on an attached clip's body sets its attach point to the clicked time.
    func attachPointClick(at p: CGPoint, modifiers mods: InputModifiers) -> Clip.ID? {
        guard timeline.isFastCut, toolState.timelineTool == .selection,
              mods.intersection([.command, .option, .shift]) == [.command, .option],
              case .clip(let id, .body) = geometry.hitTest(p, in: timeline), timeline.isAttachable(id) else { return nil }
        return id
    }
}
