import AppKit
import SQCore
import SQTimelineUI

/// The Mac timeline's side of `KeyLanes`: `TimelineGeometry` overloads and the AppKit drawing in `TimelineView`.
extension KeyLanes {
    /// Glyph centers (view space) for the keys, skipping those outside `visible` horizontally.
    public static func glyphCenters(clip: Clip, section: EffectSection, clipRect: CGRect, visible: CGRect,
                                    geometry: TimelineGeometry) -> [CGPoint] {
        glyphCenters(times: keyTimes(clip: clip, section: section), clipRect: clipRect, visible: visible, geometry: geometry)
    }

    public static func hitTest(clip: Clip, section: EffectSection, clipRect: CGRect, at p: CGPoint,
                               geometry: TimelineGeometry) -> Time? {
        hitTest(clip: clip, section: section, clipRect: clipRect, at: p, frameDuration: geometry.frameDuration) { geometry.x(for: $0) }
    }

    public static func glyphCenters(times: [Time], clipRect: CGRect, visible: CGRect, geometry: TimelineGeometry) -> [CGPoint] {
        glyphCenters(times: times, clipRect: clipRect, visible: visible) { geometry.x(for: $0) }
    }
}

extension TimelineView {
    /// Effect section whose keys the selected clips show as a lane (nil = no lane). Set by the host from Effect Controls.
    public func setKeyLaneSection(_ s: EffectSection?) {
        if Self.keyLaneDrawer == nil {
            Self.keyLaneDrawer = { $0.drawKeyLane(clip: $1, rect: $2, visible: $3, rowHeight: $4) }
        }
        if TimelineView.keyLaneHitTester == nil {
            TimelineView.keyLaneHitTester = { clip, section, rect, p, geometry in
                guard KeyLanes.isApplicable(clip: clip, section: section, selected: true, rowHeight: rect.height) else { return nil }
                return KeyLanes.hitTest(clip: clip, section: section, clipRect: rect, at: p, geometry: geometry)
            }
        }
        guard s != keyLaneSection else { return }
        keyLaneSection = s
        needsDisplay = true
    }

    func drawKeyLane(clip c: Clip, rect: CGRect, visible: CGRect, rowHeight: CGFloat) {
        guard let k = KeyLanes.layout(clip: c, section: keyLaneSection, clipRect: rect, visible: visible,
                                      selected: selection.contains(c.id), rowHeight: rowHeight,
                                      picked: selectedKeyLaneTimes, frameDuration: geometry.frameDuration,
                                      x: { geometry.x(for: $0) }) else { return }
        let drawn = k.lane.intersection(CGRect(x: visible.minX, y: k.lane.minY, width: visible.width, height: k.lane.height))
        guard !drawn.isNull else { return }
        Theme.Colors.lane.withAlphaComponent(0.55).setFill()
        drawn.fill()
        let h = KeyLanes.glyphSize / 2
        for g in k.glyphs {
            let p = g.center
            let d = NSBezierPath()
            d.move(to: CGPoint(x: p.x, y: p.y - h)); d.line(to: CGPoint(x: p.x + h, y: p.y))
            d.line(to: CGPoint(x: p.x, y: p.y + h)); d.line(to: CGPoint(x: p.x - h, y: p.y)); d.close()
            (g.selected ? Theme.Colors.keyframeSelected : Theme.Colors.keyframe).setFill(); d.fill()
        }
    }
}
