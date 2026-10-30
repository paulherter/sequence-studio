#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import SQCore

public enum TimelineCursorKind: Sendable, Hashable {
    case trimIn, trimOut, rippleIn, rippleOut, rateIn, rateOut, roll, slip, slide, razor, hand, zoom
    /// Track Select Forward (A): an arrow with a bar, over the whole track area.
    case trackSelect
    /// Selection tool with Option held over a clip body: Option-drag copies.
    case copy
}

/// Which cursor shows where, per tool. Pure: the view turns these regions into cursor rects.
/// Regions mirror `TimelineInteraction.mouseDown` (same zones, same tool rules), never overlap, and are clipped to the
/// visible content area, so they stay right at every zoom and scroll position.
public enum TimelineCursorMap {
    public struct Region: Sendable, Equatable {
        public var rect: CGRect
        public var kind: TimelineCursorKind
    }

    /// `content` is the visible track area in view coordinates (right of the headers, below the ruler).
    public static func regions(timeline: Timeline, geometry: TimelineGeometry, tool: TimelineTool, content: CGRect,
                               command: Bool = false, option: Bool = false) -> [Region] {
        let rows = geometry.rows(for: timeline)
        var out: [Region] = []
        guard !rows.isEmpty, !content.isEmpty else { return out }
        func add(_ r: CGRect, _ kind: TimelineCursorKind) {
            let c = r.intersection(content)
            if !c.isNull, c.width >= 0.5, c.height >= 0.5 { out.append(Region(rect: c, kind: kind)) }
        }
        switch tool {
        case .razor, .hand, .zoom, .trackSelectForward:
            let top = rows.first!.y, bottom = rows.last!.maxY
            add(CGRect(x: content.minX, y: top, width: content.width, height: bottom - top),
                tool == .razor ? .razor : tool == .zoom ? .zoom : tool == .trackSelectForward ? .trackSelect : .hand)
        case .mask, .type, .position:
            break
        case .selection, .rippleEdit, .rateStretch, .rollEdit, .slip, .slide:
            for row in rows {
                guard let track = timeline.track(row.track) else { continue }
                for clip in track.clips {
                    let x0 = geometry.x(for: clip.timeline.start), x1 = geometry.x(for: clip.timeline.end)
                    if x1 < content.minX { continue }
                    if x0 > content.maxX { break }
                    let w = x1 - x0
                    guard w > 0 else { continue }
                    func slab(_ a: CGFloat, _ b: CGFloat) -> CGRect { CGRect(x: a, y: row.y, width: b - a, height: row.height) }
                    let h = TimelineGeometry.trimHandleWidth(forClipWidth: w)
                    switch tool {
                    case .selection:
                        // Cmd on an edge = ripple trim, Option over the body = copy drag (the cursor follows the keys while hovering).
                        add(slab(x0, x0 + h), command ? .rippleIn : .trimIn)
                        add(slab(x1 - h, x1), command ? .rippleOut : .trimOut)
                        if option, !command, x1 - x0 > 2 * h { add(slab(x0 + h, x1 - h), .copy) }
                    case .rippleEdit:
                        // The reducer picks the nearest edge even over the body.
                        add(slab(x0, (x0 + x1) / 2), .rippleIn)
                        add(slab((x0 + x1) / 2, x1), .rippleOut)
                    case .rateStretch:
                        add(slab(x0, (x0 + x1) / 2), .rateIn)
                        add(slab((x0 + x1) / 2, x1), .rateOut)
                    case .rollEdit:
                        add(slab(x0, x1), .roll)
                    case .slip:
                        add(slab(x0, x1), .slip)
                    case .slide:
                        add(slab(x0, x1), .slide)
                    default: break
                    }
                }
            }
        }
        return out
    }
}
