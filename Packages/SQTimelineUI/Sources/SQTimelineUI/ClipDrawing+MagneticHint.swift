import AppKit
import SQCore

extension ClipDrawing {
    /// Fast Cut: the main-track clips the selected attached clips are attached to (their host highlight). Empty outside
    /// Fast Cut.
    static func attachHosts(of selection: Set<Clip.ID>, in t: Timeline) -> Set<Clip.ID> { FastCutMarks.attachHosts(of: selection, in: t) }

    /// Fast Cut spacers: the holes of the main track before its last clip (time ranges), empty outside Fast Cut.
    static func spacers(in t: Timeline) -> [TimeRange] { FastCutMarks.spacers(in: t) }

    /// The holes of one (main) track as drawn, e.g. the live preview of a drag.
    static func spacers(on track: Track) -> [TimeRange] { FastCutMarks.spacers(on: track) }

    /// A spacer on the main track: thin diagonal hatch in the lane line color, framed by a 1 pt outline.
    @MainActor static func drawSpacer(rect: CGRect, dirty: CGRect = .infinite) {
        guard rect.width >= 2, rect.height >= 4 else { return }
        let body = rect.insetBy(dx: 0.5, dy: 1.5)
        // Only the dirty part is hatched (a long spacer at high zoom is thousands of strokes); the hatch stays anchored
        // to the spacer's start so partial redraws line up.
        let vis = body.intersection(dirty)
        guard !vis.isNull, vis.width > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: vis).addClip()
        let p = NSBezierPath()
        let step: CGFloat = 6, h = body.height, origin = body.minX - h
        var x = origin + step * max(0, ((vis.minX - h - origin) / step).rounded(.down))
        while x <= vis.maxX {
            p.move(to: CGPoint(x: x, y: body.maxY)); p.line(to: CGPoint(x: x + h, y: body.minY))
            x += step
        }
        p.lineWidth = 1
        Theme.Colors.trackRowLine.setStroke()
        p.stroke()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        if dirty != .infinite { NSBezierPath(rect: dirty).addClip() }
        let frame = NSBezierPath(rect: CGRect(x: max(body.minX, dirty.minX - 2), y: body.minY,
                                              width: min(body.maxX, dirty.maxX + 2) - max(body.minX, dirty.minX - 2), height: h))
        frame.lineWidth = 1
        Theme.Colors.trackRowLine.setStroke()
        frame.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Fast Cut: the main-track clip a selected attached clip belongs to gets a faint accent tint and a thin bracket along
    /// its lower edge (a line with short ticks up at both ends), Theme tokens only.
    @MainActor static func drawMagneticHint(rect: CGRect) {
        guard rect.width >= 8, rect.height >= 12 else { return }
        let body = rect.insetBy(dx: 1, dy: 1)
        Theme.Colors.accentTint.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: body, xRadius: Theme.Radius.small, yRadius: Theme.Radius.small).fill()
        let inset: CGFloat = 3, tick: CGFloat = 4
        let y = rect.minY + rect.height - 3, x0 = rect.minX + inset, x1 = rect.maxX - inset
        let p = NSBezierPath()
        p.move(to: CGPoint(x: x0, y: y - tick)); p.line(to: CGPoint(x: x0, y: y))
        p.line(to: CGPoint(x: x1, y: y)); p.line(to: CGPoint(x: x1, y: y - tick))
        p.lineWidth = 1.5
        p.lineJoinStyle = .round
        Theme.Colors.accent.withAlphaComponent(0.85).setStroke()
        p.stroke()
    }

    /// Where the attach thread of an attached clip runs (Fast Cut): a vertical line at the attach point `x` from the
    /// attached clip's near edge to the host's row on the main track (`hostMinY`...`hostMaxY`), ending in a small
    /// triangle on the host edge that points into the host. nil when the clip touches the host row.
    static func attachThreadGeometry(clipRect: CGRect, x: CGFloat, hostMinY: CGFloat, hostMaxY: CGFloat)
        -> (from: CGPoint, to: CGPoint, triangle: [CGPoint])? { FastCutMarks.attachThreadGeometry(clipRect: clipRect, x: x, hostMinY: hostMinY, hostMaxY: hostMaxY) }

    /// Draws the attach thread (thin accent line plus triangle, same token style as the hint above).
    @MainActor static func drawAttachThread(clipRect: CGRect, x: CGFloat, hostMinY: CGFloat, hostMaxY: CGFloat) {
        // A clip on the row next to the host has no thread, only the marker on the shared edge (the drag handle).
        guard let g = attachThreadGeometry(clipRect: clipRect, x: x, hostMinY: hostMinY, hostMaxY: hostMaxY)
                ?? attachMarker(clipRect: clipRect, x: x, hostMinY: hostMinY, hostMaxY: hostMaxY) else { return }
        let color = Theme.Colors.accent.withAlphaComponent(0.85)
        color.setStroke(); color.setFill()
        let line = NSBezierPath()
        line.move(to: g.from); line.line(to: g.to)
        line.lineWidth = 1
        line.stroke()
        let tri = NSBezierPath()
        tri.move(to: g.triangle[0]); tri.line(to: g.triangle[1]); tri.line(to: g.triangle[2]); tri.close()
        tri.fill()
    }

    /// The marker alone (no thread) for a clip whose row touches the host row: a triangle on the shared edge pointing
    /// into the host. nil when the clip is not next to the host.
    static func attachMarker(clipRect: CGRect, x: CGFloat, hostMinY: CGFloat, hostMaxY: CGFloat)
        -> (from: CGPoint, to: CGPoint, triangle: [CGPoint])? { FastCutMarks.attachMarker(clipRect: clipRect, x: x, hostMinY: hostMinY, hostMaxY: hostMaxY) }
}
