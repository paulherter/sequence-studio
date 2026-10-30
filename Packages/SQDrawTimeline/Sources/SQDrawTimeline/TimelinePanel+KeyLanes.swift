import Foundation
import SQCore
import SQDrawKit
import SQTimelineUI

/// The key lane of one selected clip as the Effect Controls side computes it (`KeyLanes` in SQInspectorUI): the strip
/// at the bottom of the clip body and one glyph per key time of the section selected there.
public struct TimelineKeyLane: Sendable, Equatable {
    public var lane: CGRect
    public var glyphs: [Glyph]
    public var glyphSize: CGFloat
    public struct Glyph: Sendable, Equatable {
        public var center: CGPoint
        public var selected: Bool
        public init(center: CGPoint, selected: Bool) { self.center = center; self.selected = selected }
    }
    public init(lane: CGRect, glyphs: [Glyph], glyphSize: CGFloat) { self.lane = lane; self.glyphs = glyphs; self.glyphSize = glyphSize }
}

/// The Mac view's `keyLaneDrawer` / `keyLaneHitTester` hooks: the lane belongs to Effect Controls (its selected section,
/// its key summary, its picked keys), so the Inspector side installs it and the timeline only draws and reports presses.
public protocol TimelineKeyLaneSource: AnyObject {
    /// The lane of `clip` drawn at `clipRect` (nil = none: no section, not selected, a low row, no keys).
    func keyLane(clip: Clip, clipRect: CGRect, visible: CGRect, selected: Bool, geometry: TimelineGeometry) -> TimelineKeyLane?
    /// Timeline time of the key glyph under `p` on the lane of a selected `clip` (nil = none).
    func keyLaneHit(clip: Clip, clipRect: CGRect, at p: CGPoint, geometry: TimelineGeometry) -> Time?
}

extension TimelinePanel {
    /// `drawKeyLane`: the strip under the visible part and the diamonds, picked keys in the accent.
    func drawKeyLane(_ cv: inout Canvas, _ c: Clip, rect: CGRect, visible: CGRect, selected: Bool) {
        guard let source = keyLanes, rect.maxX >= visible.minX, rect.minX <= visible.maxX,
              let k = source.keyLane(clip: c, clipRect: rect, visible: visible, selected: selected, geometry: geometry),
              !k.glyphs.isEmpty else { return }
        let drawn = k.lane.intersection(CGRect(x: visible.minX, y: k.lane.minY, width: visible.width, height: k.lane.height))
        guard !drawn.isNull else { return }
        cv.fill(drawn, theme.lane.alpha(0.55))
        let h = k.glyphSize / 2
        for g in k.glyphs {
            let p = g.center
            cv.fill(polygon: [CGPoint(x: p.x, y: p.y - h), CGPoint(x: p.x + h, y: p.y), CGPoint(x: p.x, y: p.y + h), CGPoint(x: p.x - h, y: p.y)],
                    g.selected ? theme.accent : theme.keyframe)
        }
    }

    /// `beginKeyLaneClick`: a press on a glyph of a selected clip's lane picks that key in Effect Controls.
    mutating func keyLaneDown(_ p: CGPoint, shift: Bool) -> [TimelineAction]? {
        guard let source = keyLanes, toolState.timelineTool == .selection,
              let row = rows.first(where: { p.y >= $0.y && p.y < $0.maxY }),
              let track = timeline.track(row.track), !track.isLocked,
              let clip = track.clips.first(where: { selection.contains($0.id)
                  && geometry.x(for: $0.timeline.start) - 6 <= p.x && p.x < geometry.x(for: $0.timeline.end) + 6 })
        else { return nil }
        let x0 = geometry.x(for: clip.timeline.start), x1 = geometry.x(for: clip.timeline.end)
        guard let t = source.keyLaneHit(clip: clip, clipRect: CGRect(x: x0, y: row.y, width: x1 - x0, height: row.height),
                                        at: p, geometry: geometry) else { return nil }
        var out: [TimelineAction] = []
        if !selectedLineKeys.isEmpty { selectedLineKeys = []; out.append(.lineKeyClick(nil, extend: false)) }
        out.append(.keyLaneClick(clip: clip.id, time: t, extend: shift))
        return out
    }
}
