import Foundation

/// Geometry of a Create tool drag (Rectangle, Ellipse, Line) in any flat space with y down.
public enum CreateDrag {
    /// The box a drag from `a` to `b` spans. `square`: both sides take the longer one (square / circle). `fromCenter`: `a`
    /// is the box's center instead of a corner.
    public static func box(from a: Vec2, to b: Vec2, square: Bool, fromCenter: Bool) -> GraphicsRect {
        var d = b - a
        if square {
            let side = max(abs(d.x), abs(d.y))
            d = Vec2(d.x < 0 ? -side : side, d.y < 0 ? -side : side)
        }
        let p = fromCenter ? a - d : a, q = a + d
        return GraphicsRect(minX: min(p.x, q.x), minY: min(p.y, q.y), maxX: max(p.x, q.x), maxY: max(p.y, q.y))
    }

    /// The two ends of a line dragged from `a` to `b`. `constrain`: the direction snaps to 45 degree steps, the length
    /// stays. `fromCenter`: the line grows the same way on both sides of `a`.
    public static func line(from a: Vec2, to b: Vec2, constrain: Bool, fromCenter: Bool) -> (a: Vec2, b: Vec2) {
        var d = b - a
        if constrain, d.length > 0 {
            let step = Double.pi / 4
            let angle = (atan2(d.y, d.x) / step).rounded() * step
            let unit = Vec2(cos(angle), sin(angle))
            // Exact axes and diagonals: no float noise in the snapped direction.
            let clean = Vec2(abs(unit.x) < 1e-9 ? 0 : unit.x, abs(unit.y) < 1e-9 ? 0 : unit.y)
            d = clean * d.length
        }
        return (fromCenter ? a - d : a, a + d)
    }
}

/// A hand-drawn stroke made calm: smoothed, then reduced to the points that carry its shape.
public enum PathSmoothing {
    /// `points` smoothed (one 1-2-1 pass, ends kept) and reduced (Ramer-Douglas-Peucker): no smoothed point lies farther
    /// than `tolerance` from the result. The first and last point are kept as recorded.
    public static func smooth(_ points: [Vec2], tolerance: Double) -> [Vec2] {
        guard points.count > 2 else { return points }
        var soft = points
        for i in 1..<(points.count - 1) {
            soft[i] = Vec2((points[i - 1].x + 2 * points[i].x + points[i + 1].x) / 4,
                           (points[i - 1].y + 2 * points[i].y + points[i + 1].y) / 4)
        }
        var keep = [Bool](repeating: false, count: soft.count)
        keep[0] = true; keep[soft.count - 1] = true
        var stack = [(0, soft.count - 1)]
        while let (lo, hi) = stack.popLast() {
            guard hi > lo + 1 else { continue }
            var worst = 0.0, at = lo
            for i in (lo + 1)..<hi {
                let d = distance(soft[i], toSegment: soft[lo], soft[hi])
                if d > worst { worst = d; at = i }
            }
            guard worst > max(tolerance, 0) else { continue }
            keep[at] = true
            stack.append((lo, at)); stack.append((at, hi))
        }
        return soft.indices.filter { keep[$0] }.map { soft[$0] }
    }

    static func distance(_ p: Vec2, toSegment a: Vec2, _ b: Vec2) -> Double {
        let d = b - a, l2 = d.x * d.x + d.y * d.y
        guard l2 > 0 else { return (p - a).length }
        let t = min(max(((p.x - a.x) * d.x + (p.y - a.y) * d.y) / l2, 0), 1)
        return (p - (a + d * t)).length
    }
}

extension GraphicsLayer {
    /// A rectangle or ellipse filling `box` (canvas px, offsets from the canvas center, y down), with the look a new shape
    /// of that kind starts with.
    public static func shape(_ kind: ShapeKind, box: GraphicsRect, canvasWidth: Int, canvasHeight: Int) -> GraphicsLayer {
        var l = shape(kind, canvasWidth: canvasWidth, canvasHeight: canvasHeight)
        l.setShapeSize(width: max(box.width, 1), height: max(box.height, 1))
        l.animation.position = AnimatedProperty(Vec2(box.midX, box.midY))
        return l
    }

    /// A line from `a` to `b` (canvas px, offsets from the canvas center): Width is its length, the layer's rotation its
    /// direction.
    public static func line(from a: Vec2, to b: Vec2, canvasWidth: Int, canvasHeight: Int) -> GraphicsLayer {
        var l = shape(.line, canvasWidth: canvasWidth, canvasHeight: canvasHeight)
        let d = b - a
        if let i = l.effects.firstIndex(where: { $0.kind == ClipEffect.shapeEffectKind }) {
            l.effects[i].parameters[ClipEffect.shapeWidthKey] = AnimatedProperty(max(d.length, 1))
        }
        l.animation.position = AnimatedProperty(Vec2((a.x + b.x) / 2, (a.y + b.y) / 2))
        l.animation.rotation = AnimatedProperty(atan2(d.y, d.x) * 180 / .pi)
        return l
    }
}

extension Timeline {
    /// The Graphic clip a Create tool adds its new item to at `time`: the single selected Graphic when the playhead is
    /// inside it, else the Graphic under the playhead on the topmost targeted video track. Locked tracks take nothing.
    /// Nil: a new Graphic clip is made.
    public func graphicCreateTarget(selection: Set<Clip.ID>, at time: Time) -> Clip.ID? {
        func graphic(on track: Track, where pick: (Clip) -> Bool) -> Clip.ID? {
            guard track.kind == .video, !track.isLocked else { return nil }
            return track.clips.first { $0.isGraphics && $0.timeline.contains(time) && pick($0) }?.id
        }
        if selection.count == 1, let id = selection.first {
            for track in tracks { if let hit = graphic(on: track, where: { $0.id == id }) { return hit } }
        }
        for track in tracks.reversed() where track.isTargeted {
            if let hit = graphic(on: track, where: { _ in true }) { return hit }
        }
        return nil
    }
}
