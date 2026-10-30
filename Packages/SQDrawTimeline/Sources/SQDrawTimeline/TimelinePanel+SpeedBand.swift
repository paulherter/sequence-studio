import Foundation
import SQCore
import SQDrawKit
import SQEditorSession
import SQTimelineUI

/// One speed band drag (`SpeedDrag` of the Mac view).
struct SpeedBandDrag {
    var clip: Clip.ID
    var gesture: SpeedBand.Gesture
    var last: SpeedKeys
    var tip: String?
    /// The sequence at mouse-down: Esc puts it back (`cancelSpeedDrag`).
    var original: Timeline
}

/// The Time Remapping speed band, translated from TimelineView+SpeedBand.swift: the same `SpeedBand` geometry and
/// gesture; `onSpeedEdit` becomes `.speedEdit` (the session's `applySpeedEdit` makes one undo step of a drag).
extension TimelinePanel {
    /// The video clip, its rectangle and lane under `p`, when the band is shown there (`speedTarget`).
    func speedTarget(at p: CGPoint) -> (clip: Clip, rect: CGRect, lane: CGRect)? {
        guard toolState.timelineTool == .selection, !speedBandClips.isEmpty, p.x >= TimelineGeometry.contentOriginX,
              let row = rows.first(where: { p.y >= $0.y && p.y < $0.maxY }),
              row.kind == .video, SpeedBand.isAvailable(rowHeight: row.height),
              let track = timeline.track(row.track), !track.isLocked,
              let clip = track.clips.first(where: { speedBandClips.contains($0.id) && geometry.x(for: $0.timeline.start) - 6 <= p.x
                                                    && p.x < geometry.x(for: $0.timeline.end) + 6 })
        else { return nil }
        let x0 = geometry.x(for: clip.timeline.start), x1 = geometry.x(for: clip.timeline.end)
        let rect = CGRect(x: x0, y: row.y, width: x1 - x0, height: row.height)
        return (clip, rect, ClipBodyMetrics.waveformRect(in: rect))
    }

    /// Key or transition under `p`, for the context menu ("Delete Speed Keyframe", "Remove Speed Transition").
    public func speedKeyHit(at p: CGPoint) -> (clip: Clip.ID, key: SpeedBandKeyHit)? {
        let g = geometry
        guard let t = speedTarget(at: p), let keys = t.clip.speedKeys,
              let h = SpeedBand.hit(keys: keys, clipStart: t.clip.start, lane: t.lane, at: p, x: { g.x(for: $0) }) else { return nil }
        switch h {
        case .key(let b): return (t.clip.id, SpeedBandKeyHit(hit: .key(b)))
        case .ramp(let i), .rampHandle(let i): return (t.clip.id, SpeedBandKeyHit(hit: .ramp(i)))
        case .segment: return nil
        }
    }

    /// The clip whose band line is under `p`: the menu offers "Add Speed Point" there.
    public func speedSegmentClip(at p: CGPoint) -> Clip.ID? {
        let g = geometry
        guard let t = speedTarget(at: p),
              case .segment? = SpeedBand.hit(keys: SpeedKeys.of(t.clip), clipStart: t.clip.start, lane: t.lane, at: p, x: { g.x(for: $0) })
        else { return nil }
        return t.clip.id
    }

    /// `beginSpeedDrag`; nil = the press is not on the band.
    mutating func speedDown(_ p: CGPoint, modifiers mods: InputModifiers) -> [TimelineAction]? {
        // A transition box sits on the clip edge and wins over the band underneath it.
        if TransitionLayout.hitTest(p, in: timeline, geometry: geometry) != nil { return nil }
        guard let t = speedTarget(at: p) else { return nil }
        let keys = SpeedKeys.of(t.clip)
        let g = geometry
        guard let hit = SpeedBand.hit(keys: keys, clipStart: t.clip.start, lane: t.lane, at: p, x: { g.x(for: $0) }) else { return nil }
        let cmd = mods.contains(.command)
        if !cmd, VolumeLine.edgeWins(at: p, clipRect: t.rect) { return nil }          // trimming wins at the edges
        let key: Bool
        if case .segment = hit { key = cmd } else { key = false }
        // A segment drag without Cmd edits its speed; Cmd-click adds a key. Keys and transitions need no modifier.
        let gesture = SpeedBand.Gesture(keys: keys, clipStart: t.clip.start, hit: hit, start: p, lane: t.lane,
                                        frameDuration: timeline.frameDuration, addKey: key, option: mods.contains(.option),
                                        shift: mods.contains(.shift), timeAt: { g.time(atX: $0) })
        var out: [TimelineAction] = []
        if selection != [t.clip.id] {
            selection = [t.clip.id]
            interaction.setSelection([t.clip.id])
            out.append(.select(clips: [t.clip.id], captions: []))
        }
        out.append(.speedEdit(clip: t.clip.id, keys: keys, phase: .began, keepingKeys: gesture.keepsKeys))
        self.gesture = .speed(SpeedBandDrag(clip: t.clip.id, gesture: gesture, last: keys, tip: nil, original: committed))
        if key { out += speedDragged(to: p) }
        return out
    }

    mutating func speedDragged(to p: CGPoint) -> [TimelineAction] {
        guard case .speed(var d)? = gesture else { return [] }
        let k = d.gesture.update(to: p)
        d.tip = d.gesture.tooltip(at: p)
        guard k != d.last else { gesture = .speed(d); return [] }
        d.last = k
        gesture = .speed(d)
        _ = try? timeline.magneticEditSpeedKeys(d.clip, keepingKeys: d.gesture.keepsKeys) { _ in k }   // the preview
        return [.speedEdit(clip: d.clip, keys: k, phase: .changed, keepingKeys: d.gesture.keepsKeys)]
    }

    mutating func speedUp(at p: CGPoint) -> [TimelineAction] {
        var out = speedDragged(to: p)
        if case .speed(let d)? = gesture {
            out.append(.speedEdit(clip: d.clip, keys: d.last, phase: .ended, keepingKeys: d.gesture.keepsKeys))
        }
        return out
    }

    /// Esc during a speed band drag: the session goes back to the sequence at mouse-down and drops the drag's undo step
    /// (the Mac view has no Esc here; the draw-list panel cancels every drag the same way). The preview reverts in
    /// `cancelGesture`.
    mutating func cancelSpeedDrag() -> [TimelineAction] {
        guard case .speed(let d)? = gesture else { return [] }
        return [.cancelSpeedEdit(clip: d.clip, restoring: d.original)]
    }

    // MARK: Drawing

    /// `drawSpeedBand`: the key strip, shaded transitions, the rubber band, speed labels, key triangles, ramp handles.
    func drawSpeedBand(_ cv: inout Canvas, _ c: Clip, rect: CGRect, visible: CGRect, selected: Bool) {
        let lane = ClipBodyMetrics.waveformRect(in: rect)
        let keys = SpeedKeys.of(c)
        let g = geometry
        let xs: (Time) -> CGFloat = { g.x(for: $0) }
        cv.saveGState()
        cv.clip(to: visible.intersection(rect))
        let strip = SpeedBand.strip(in: lane)
        cv.fill(strip, theme.fillHover)
        let ramps = SpeedBand.rampMarks(keys: keys, clipStart: c.start, lane: lane, x: xs)
        for r in ramps { cv.fill(CGRect(x: r.x0, y: strip.minY, width: max(r.x1 - r.x0, 1), height: strip.height), theme.label3) }
        let pts = SpeedBand.linePoints(keys: keys, clipStart: c.start, lane: lane, x: xs)
        cv.strokePolyline(pts.map { CGPoint(x: $0.x, y: $0.y + 1) }, width: 1, skin.badgeEdge)
        cv.strokePolyline(pts, width: 1, skin.badgeFill.alpha(selected ? 0.95 : 0.8))
        let area = SpeedBand.lineArea(in: lane), starts = keys.boundaries
        let size = DrawTheme.TypeSize.caption.cg
        for (i, s) in keys.segments.enumerated() {
            let x0 = xs(c.start + starts[i]), x1 = xs(c.start + starts[i + 1])
            guard x1 - x0 > 44 else { continue }
            let mid = s.speedValue(at: Time(s.duration.value, s.duration.timescale * 2))
            let text = SpeedBand.label(speed: mid)
            let y = SpeedBand.y(forSpeed: mid, in: area)
            cv.draw(text, at: CGPoint(x: (x0 + x1) / 2 - cv.size(of: text, fontSize: size).width / 2, y: y + 3), fontSize: size, theme.onClip)
        }
        for k in SpeedBand.keyMarks(keys: keys, clipStart: c.start, x: xs) {
            let tri: [CGPoint]
            if k.isHalf {
                let dir: CGFloat = k.isLeftHalf ? 1 : -1                       // a left half points into the transition
                tri = [CGPoint(x: k.x, y: strip.minY), CGPoint(x: k.x, y: strip.maxY), CGPoint(x: k.x + 4 * dir, y: strip.midY)]
            } else {
                tri = [CGPoint(x: k.x - 4, y: strip.minY), CGPoint(x: k.x + 4, y: strip.minY), CGPoint(x: k.x, y: strip.maxY)]
            }
            cv.fill(polygon: tri, skin.badgeFill)
            cv.stroke(polygon: tri, width: 1, skin.badgeEdge)
        }
        for r in ramps {
            let dot = CGRect(x: r.handle.x - 3.5, y: r.handle.y - 3.5, width: 7, height: 7)
            cv.fill(ellipseIn: dot, theme.accent)
            cv.stroke(ellipseIn: dot, width: 1, skin.badgeFill)
        }
        cv.restoreGState()
    }

    /// `drawSpeedTip`: "Speed 250%" next to the press while a segment is dragged.
    func drawSpeedTip(_ cv: inout Canvas) {
        guard case .speed(let d)? = gesture, let tip = d.tip else { return }
        let size = DrawTheme.TypeSize.body.cg
        let s = cv.size(of: tip, fontSize: size)
        let origin = CGPoint(x: d.gesture.start.x + 12, y: d.gesture.start.y - s.height - 10)
        let box = CGRect(origin: origin, size: s).insetBy(dx: -6, dy: -3)
        cv.fill(roundedRect: box, radius: DrawTheme.Radius.small.cg, skin.hudFill)
        cv.draw(tip, at: origin, fontSize: size, theme.onClip)
    }
}
