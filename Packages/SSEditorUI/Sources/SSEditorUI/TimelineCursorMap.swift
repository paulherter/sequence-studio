import CoreGraphics
import Foundation
import SSCore

public enum TimelineCursorKind: Sendable, Hashable {
    case trimIn, trimOut, rippleIn, rippleOut, roll, slip, slide, razor, hand
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
    public static func regions(timeline: Timeline, geometry: TimelineGeometry, tool: TimelineTool, content: CGRect) -> [Region] {
        let rows = geometry.rows(for: timeline)
        var out: [Region] = []
        guard !rows.isEmpty, !content.isEmpty else { return out }
        func add(_ r: CGRect, _ kind: TimelineCursorKind) {
            let c = r.intersection(content)
            if !c.isNull, c.width >= 0.5, c.height >= 0.5 { out.append(Region(rect: c, kind: kind)) }
        }
        switch tool {
        case .razor, .hand:
            let top = rows.first!.y, bottom = rows.last!.maxY
            add(CGRect(x: content.minX, y: top, width: content.width, height: bottom - top), tool == .razor ? .razor : .hand)
        case .trackSelectForward:
            break
        case .selection, .rippleEdit, .rollEdit, .slip, .slide:
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
                        add(slab(x0, x0 + h), .trimIn)
                        add(slab(x1 - h, x1), .trimOut)
                    case .rippleEdit:
                        // The reducer picks the nearest edge even over the body.
                        add(slab(x0, (x0 + x1) / 2), .rippleIn)
                        add(slab((x0 + x1) / 2, x1), .rippleOut)
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
