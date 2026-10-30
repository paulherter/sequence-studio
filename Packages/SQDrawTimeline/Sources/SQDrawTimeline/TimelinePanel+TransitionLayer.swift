import Foundation
import SQCore
import SQDrawKit
import SQTimelineUI

/// Transition layer clips (DECISIONS 2026-10-05), translated from `TimelineView+TransitionLayer`: the center marker
/// (the cut) and its drag, the end drags (symmetric around the cut; Alt = this end only) and the lead-in / lead-out ramp
/// drawn over the clip. The body falls through to the ordinary clip gestures (select, move).
extension TimelinePanel {
    struct LayerDrag {
        var id: Clip.ID
        var zone: TransitionLayerZone
        var startX: CGFloat
        /// The dragged part's time at the press (the cut, or the end).
        var cut: Time
        var began = false
        var lastFrames: Int64 = 0
    }

    private var layerSnapping: Bool { toolState.snapping != interaction.snapInverted }

    /// A single press on a layer's center marker or end (the Selection tool) begins its drag and selects the clip.
    mutating func transitionLayerDown(_ p: CGPoint, clicks: Int) -> [TimelineAction]? {
        guard clicks == 1, let hit = TransitionLayerLayout.hitTest(p, in: timeline, geometry: geometry),
              let r = timeline.resolvedTransitionLayer(hit.id) else { return nil }
        var out: [TimelineAction] = []
        if selectedTransition != nil { selectedTransition = nil; out.append(.selectTransition(nil, keepClips: true)) }
        if selection != [hit.id] { out.append(.select(clips: [hit.id], captions: [])) }
        let edge: Time = hit.zone == .head ? r.span.start : hit.zone == .tail ? r.span.end : r.cut
        gesture = .transitionLayer(LayerDrag(id: hit.id, zone: hit.zone, startX: p.x, cut: edge))
        return out
    }

    /// One step: the cut moves to the pointer's frame, or the end to it (the bridge measures the step against the
    /// session's current end, so a model clamp never accumulates).
    mutating func transitionLayerDragged(_ d: LayerDrag, at p: CGPoint) -> [TimelineAction] {
        var d = d
        if !d.began && abs(p.x - d.startX) < TimelineInteraction.dragThreshold { return [] }
        let fd = timeline.format.frameDuration
        let frames = (geometry.time(atX: p.x) - geometry.time(atX: d.startX)).frameIndex(frameDuration: fd)
        var target = d.cut + fd * frames
        if layerSnapping, let track = timeline.tracks.first(where: { $0.clips.contains { $0.id == d.id } }) {
            target = TransitionLayerLayout.snapped(target, to: TransitionLayerLayout.snapTimes(below: track.id, in: timeline, playhead: playhead),
                                                   geometry: geometry)
        }
        let key = target.frameIndex(frameDuration: fd)
        if d.began && key == d.lastFrames { return [] }
        let continues = d.began
        d.began = true
        d.lastFrames = key
        gesture = .transitionLayer(d)
        switch d.zone {
        case .cut:
            return [.transitionLayerCut(d.id, to: target, continues: continues)]
        case .head, .tail:
            // Alt held now (the host's live keys, `liveModifiers`) resizes one side only.
            return [.transitionLayerResize(d.id, d.zone == .head ? .head : .tail, to: target,
                                           symmetric: !dragModifiers.contains(.option), continues: continues)]
        }
    }

    // MARK: Drawing

    func drawTransitionLayers(_ cv: inout Canvas, rows: [TrackRow], clip: CGRect) {
        let fd = timeline.format.frameDuration
        for row in rows where row.kind == .video {
            guard row.maxY > clip.minY, row.y < clip.maxY, let track = timeline.track(row.track) else { continue }
            for c in track.clips where c.isTransitionLayer {
                guard let r = c.resolvedTransitionLayer(frameDuration: fd) else { continue }
                let x0 = geometry.x(for: r.span.start), x1 = geometry.x(for: r.span.end)
                guard x1 >= clip.minX, x0 <= clip.maxX else { continue }
                let selected = selection.contains(c.id)
                let box = CGRect(x: x0, y: row.y + 1, width: x1 - x0, height: max(row.height - 2, 1))
                let cx = geometry.x(for: r.cut)
                // Lead-in rises to the cut, lead-out falls from it: the shape of the mix.
                cv.strokePolyline([CGPoint(x: box.minX, y: box.maxY - 2), CGPoint(x: cx, y: box.minY + 2), CGPoint(x: box.maxX, y: box.maxY - 2)],
                                  width: 1, selected ? theme.onClip : theme.label2)
                if selected {
                    cv.fill(CGRect(x: box.minX + 1, y: box.minY + 3, width: 2, height: box.height - 6), theme.onClip)
                    cv.fill(CGRect(x: box.maxX - 3, y: box.minY + 3, width: 2, height: box.height - 6), theme.onClip)
                }
                drawCutMarker(&cv, x: cx, y: box.minY, height: box.height, selected: selected)
            }
        }
    }

    /// The center marker: a line through the row with a small downward triangle on top.
    func drawCutMarker(_ cv: inout Canvas, x: CGFloat, y: CGFloat, height: CGFloat, selected: Bool) {
        let color = selected ? theme.accent : theme.label
        cv.fill(CGRect(x: x - 1, y: y, width: 2, height: height), color)
        cv.fill(polygon: [CGPoint(x: x - 5, y: y), CGPoint(x: x + 5, y: y), CGPoint(x: x, y: y + 6)], color)
    }
}
