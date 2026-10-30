#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import SQCore

/// Which part of a transition box the pointer is on.
public enum TransitionZone: Sendable, Hashable { case leftEdge, rightEdge, body }

public struct TransitionHit: Sendable, Hashable {
    public var id: Transition.ID
    public var track: Track.ID
    public var zone: TransitionZone
}

/// Where a dragged transition would land (drag from the Effects panel).
public struct TransitionDropTarget: Sendable, Equatable {
    public var track: Track.ID
    public var point: TransitionPoint
    public var alignment: TransitionAlignment
    /// Highlight box in view coordinates.
    public var rect: CGRect
    /// FB-G element transitions (Move / Zoom / Pop) dropped on the middle of a clip: In and Out. `point` is then the head
    /// and `tailRect` highlights the tail.
    public var bothEnds = false
    public var tailRect: CGRect?
}

/// Geometry and drag arithmetic of transition boxes on the timeline. Pure: no AppKit, rational time at the edges.
public enum TransitionLayout {
    public static let minWidth: CGFloat = 6
    public static let maxEdgeWidth: CGFloat = 6
    /// A dragged transition lands on an edit within this distance (points).
    public static let dropReach: CGFloat = 36
    /// Pointer within this distance of the cut centers the transition.
    public static let dropCenterZone: CGFloat = 10

    // MARK: Boxes

    public static func rect(_ r: ResolvedTransition, row: TrackRow, geometry: TimelineGeometry) -> CGRect {
        let x0 = geometry.x(for: r.span.start), x1 = geometry.x(for: r.span.end)
        return CGRect(x: x0, y: row.y + 1, width: max(x1 - x0, minWidth), height: max(row.height - 2, 1))
    }

    public static func edgeWidth(forWidth w: CGFloat) -> CGFloat { max(2, min(maxEdgeWidth, w / 3)) }

    /// The transition box under `p` (view coordinates), if any. Boxes sit above the clips, so this is asked before the
    /// clip hit test.
    public static func hitTest(_ p: CGPoint, in timeline: Timeline, geometry: TimelineGeometry,
                               cutSlop: CGFloat = TimelineGeometry.maxTrimHandleWidth) -> TransitionHit? {
        guard p.x >= TimelineGeometry.contentOriginX else { return nil }
        for row in geometry.rows(for: timeline) where p.y >= row.y && p.y < row.maxY {
            guard let track = timeline.track(row.track) else { return nil }
            for r in track.resolvedTransitions(frameDuration: timeline.format.frameDuration) {
                let box = rect(r, row: row, geometry: geometry)
                guard p.x >= box.minX && p.x < box.maxX else { continue }
                // The clip edge at the cut stays trimmable: within the trim handle of it the clips answer, not the box.
                if abs(p.x - geometry.x(for: r.cut)) <= cutSlop { continue }
                let e = edgeWidth(forWidth: box.width)
                let zone: TransitionZone = p.x < box.minX + e ? .leftEdge : (p.x >= box.maxX - e ? .rightEdge : .body)
                return TransitionHit(id: r.id, track: track.id, zone: zone)
            }
            return nil
        }
        return nil
    }

    // MARK: Drag

    /// The values a drag produces; apply with `Timeline.setTransition`.
    public struct Change: Sendable, Equatable {
        public var duration: Time
        public var alignment: TransitionAlignment
        public var customBefore: Time
    }

    /// Result of dragging `zone` of `r` by `frames` (positive = right). Edges: when the transition is centered the two
    /// edges move symmetrically (the duration changes by twice the drag); with `oneSide` (Shift) or any other alignment
    /// only the dragged edge moves. The body moves the transition over the cut. The cut stays inside the transition.
    /// Single-sided transitions only change length at their free edge.
    public static func drag(_ r: ResolvedTransition, zone: TransitionZone, frames n: Int64, oneSide: Bool) -> Change {
        let fd = r.frameDuration
        let b0 = r.before.frameIndex(frameDuration: fd), a0 = r.after.frameIndex(frameDuration: fd), d0 = b0 + a0
        let centred = r.alignment == .center && !oneSide
        var b = b0, a = a0
        switch zone {
        case .body:
            if r.isSingleSided { break }
            b = min(max(b0 - n, 0), d0); a = d0 - b
        case .rightEdge:
            if r.outgoing != nil && r.incoming == nil { break }                 // tail fade: the right edge is the clip end
            if r.isSingleSided { a = max(1, a0 + n); b = 0; break }              // head fade grows to the right
            if centred { let d = max(1, d0 + 2 * n); b = d / 2; a = d - b } else { a = max(0, a0 + n); if b + a < 1 { a = 1 } }
        case .leftEdge:
            if r.outgoing == nil && r.incoming != nil { break }                  // head fade: the left edge is the clip start
            if r.isSingleSided { b = max(1, b0 - n); a = 0; break }              // tail fade grows to the left
            if centred { let d = max(1, d0 - 2 * n); b = d / 2; a = d - b } else { b = max(0, b0 - n); if b + a < 1 { b = 1 } }
        }
        return normalized(before: b, after: a, preferCentre: r.alignment == .center, single: r.isSingleSided, frameDuration: fd,
                          original: r.alignment)
    }

    static func normalized(before b: Int64, after a: Int64, preferCentre: Bool, single: Bool, frameDuration fd: Time,
                           original: TransitionAlignment) -> Change {
        let d = b + a
        let alignment: TransitionAlignment
        if single { alignment = original }
        else if d == 1 { alignment = preferCentre ? .center : (b == 0 ? .startAtCut : .endAtCut) }
        else if b == d / 2 && preferCentre { alignment = .center }
        else if b == 0 { alignment = .startAtCut }
        else if b == d { alignment = .endAtCut }
        else if b == d / 2 { alignment = .center }
        else { alignment = .custom }
        return Change(duration: fd * d, alignment: alignment, customBefore: fd * b)
    }

    // MARK: Drop from the Effects panel

    /// Where a transition of `kind` dropped at `p` would go: the track under the pointer (matching kind, unlocked), the nearest
    /// edit within `dropReach`, and the alignment from which side of the cut the pointer is on (left = ends at the cut,
    /// right = starts at it, middle = centered). Clip edges without a neighbor take a one-sided transition.
    public static func dropTarget(at p: CGPoint, kind: TransitionKind, in timeline: Timeline,
                                  geometry: TimelineGeometry) -> TransitionDropTarget? {
        guard p.x >= TimelineGeometry.contentOriginX,
              let row = geometry.rows(for: timeline).first(where: { p.y >= $0.y && p.y < $0.maxY }),
              row.kind == kind.trackKind, let track = timeline.track(row.track), !track.isLocked else { return nil }
        if kind.isElement { return elementDropTarget(at: p, kind: kind, track: track, row: row, timeline: timeline, geometry: geometry) }
        guard let point = timeline.transitionPoint(near: geometry.unsnappedTime(atX: p.x), on: track.id) else { return nil }
        let editX: CGFloat
        let alignment: TransitionAlignment
        switch point {
        case let .cut(_, incoming):
            guard let c = track.clips.first(where: { $0.id == incoming }) else { return nil }
            editX = geometry.x(for: c.start)
            let dx = p.x - editX
            alignment = abs(dx) <= dropCenterZone ? .center : (dx < 0 ? .endAtCut : .startAtCut)
        case let .head(id):
            guard let c = track.clips.first(where: { $0.id == id }) else { return nil }
            editX = geometry.x(for: c.start); alignment = .startAtCut
        case let .tail(id):
            guard let c = track.clips.first(where: { $0.id == id }) else { return nil }
            editX = geometry.x(for: c.timeline.end); alignment = .endAtCut
        }
        guard abs(p.x - editX) <= dropReach else { return nil }
        let fd = timeline.format.frameDuration
        let w = geometry.width(of: kind.presetDuration(frameDuration: fd) ?? Timeline.defaultTransitionDuration(frameDuration: fd))
        let x0: CGFloat
        switch alignment {
        case .center: x0 = editX - w / 2
        case .endAtCut: x0 = editX - w
        default: x0 = editX
        }
        return TransitionDropTarget(track: track.id, point: point, alignment: alignment,
                                    rect: CGRect(x: x0, y: row.y + 1, width: w, height: max(row.height - 2, 1)))
    }

    /// FB-G: an element transition goes on the clip under the pointer (or the clip edge within `dropReach`): its head zone
    /// = In, its tail zone = Out, the middle = both. Each edge zone is a third of the clip, at most twice the transition's
    /// length (and never less than `2 * dropReach`), so long clips still have a wide middle.
    static func elementDropTarget(at p: CGPoint, kind: TransitionKind, track: Track, row: TrackRow, timeline: Timeline,
                                  geometry: TimelineGeometry) -> TransitionDropTarget? {
        let fd = timeline.format.frameDuration
        let w = geometry.width(of: kind.presetDuration(frameDuration: fd) ?? Timeline.defaultTransitionDuration(frameDuration: fd))
        var best: (clip: Clip, edge: ClipEdge?, distance: CGFloat)?
        for c in track.clips {
            let x0 = geometry.x(for: c.start), x1 = geometry.x(for: c.timeline.end)
            if p.x >= x0 && p.x < x1 { best = (c, nil, 0); break }
            let d = p.x < x0 ? x0 - p.x : p.x - x1
            if d <= dropReach, best == nil || d < best!.distance { best = (c, p.x < x0 ? .head : .tail, d) }
        }
        guard let (c, outside, _) = best else { return nil }
        let x0 = geometry.x(for: c.start), x1 = geometry.x(for: c.timeline.end)
        let zone = min((x1 - x0) / 3, max(2 * dropReach, 2 * w))
        let edge: ClipEdge? = outside ?? (p.x < x0 + zone ? .head : (p.x >= x1 - zone ? .tail : nil))
        let bw = min(w, x1 - x0), h = max(row.height - 2, 1)
        let headRect = CGRect(x: x0, y: row.y + 1, width: bw, height: h)
        let tailRect = CGRect(x: x1 - bw, y: row.y + 1, width: bw, height: h)
        switch edge {
        case .head: return TransitionDropTarget(track: track.id, point: .head(c.id), alignment: .startAtCut, rect: headRect)
        case .tail: return TransitionDropTarget(track: track.id, point: .tail(c.id), alignment: .endAtCut, rect: tailRect)
        case nil: return TransitionDropTarget(track: track.id, point: .head(c.id), alignment: .startAtCut, rect: headRect,
                                              bothEnds: true, tailRect: tailRect)
        }
    }
}
