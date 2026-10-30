import Foundation
import SQCore

/// One mask of the selected clip as the Program monitor overlay shows it (W6.7): its path at the playhead. `active` = the
/// mask being edited (selected in Effect Controls, or the clip's only path mask): it shows tangent handles, a click on its
/// outline adds a vertex and a drag inside it moves the whole mask.
public struct MaskOverlay: Sendable, Equatable {
    public var id: ClipMask.ID
    public var path: MaskPath
    public var active: Bool
    public init(id: ClipMask.ID, path: MaskPath, active: Bool = false) { self.id = id; self.path = path; self.active = active }
}

/// Maps mask points (fractions of the clip's frame) to view points and back through the layer's quad on the canvas
/// (top-left, top-right, bottom-right, bottom-left; the transform is affine, so three corners define it).
public struct MaskOverlayGeometry: Sendable {
    public var origin: CGPoint
    public var xAxis: CGVector
    public var yAxis: CGVector
    /// Grab radius of a vertex, view pt.
    public static let vertexRadius: CGFloat = 6

    public init(quad q: [CGPoint]) {
        precondition(q.count == 4, "quad needs four corners")
        origin = q[0]
        xAxis = CGVector(dx: q[1].x - q[0].x, dy: q[1].y - q[0].y)
        yAxis = CGVector(dx: q[3].x - q[0].x, dy: q[3].y - q[0].y)
    }

    public func viewPoint(_ n: Vec2) -> CGPoint {
        CGPoint(x: origin.x + CGFloat(n.x) * xAxis.dx + CGFloat(n.y) * yAxis.dx,
                y: origin.y + CGFloat(n.x) * xAxis.dy + CGFloat(n.y) * yAxis.dy)
    }

    /// Frame fraction under view point `p`; nil when the layer has no area (scale 0).
    public func framePoint(_ p: CGPoint) -> Vec2? {
        let det = Double(xAxis.dx * yAxis.dy - xAxis.dy * yAxis.dx)
        guard abs(det) > 1e-9 else { return nil }
        let dx = Double(p.x - origin.x), dy = Double(p.y - origin.y)
        let u = (dx * Double(yAxis.dy) - dy * Double(yAxis.dx)) / det
        let v = (Double(xAxis.dx) * dy - Double(xAxis.dy) * dx) / det
        return Vec2(u, v)
    }

    /// Outline in view points (the flattened path).
    public func outline(_ path: MaskPath) -> [CGPoint] { path.polygon().map(viewPoint) }

    /// The topmost mask vertex within `vertexRadius` of `p`: (mask index, vertex index).
    public func hitVertex(_ p: CGPoint, masks: [MaskOverlay]) -> (mask: Int, vertex: Int)? {
        var best: (Int, Int, CGFloat)?
        for (mi, m) in masks.enumerated() {
            for (vi, v) in m.path.vertices.enumerated() {
                let c = viewPoint(v.point)
                let d: CGFloat = hypot(c.x - p.x, c.y - p.y)
                if d <= Self.vertexRadius, d < (best?.2 ?? .infinity) { best = (mi, vi, d) }
            }
        }
        return best.map { ($0.0, $0.1) }
    }

    /// Frame size in view points (for px distances along the path).
    public var frameExtent: Vec2 { Vec2(Double(hypot(xAxis.dx, xAxis.dy)), Double(hypot(yAxis.dx, yAxis.dy))) }

    /// A tangent handle (end of a non-zero tangent) of an active mask within `vertexRadius`.
    public func hitTangent(_ p: CGPoint, masks: [MaskOverlay]) -> (mask: Int, vertex: Int, out: Bool)? {
        var best: (Int, Int, Bool, CGFloat)?
        for (mi, m) in masks.enumerated() where m.active {
            for (vi, v) in m.path.vertices.enumerated() {
                for (isOut, t) in [(false, v.inTangent), (true, v.outTangent)] where t != .zero {
                    let c = viewPoint(v.point + t)
                    let d: CGFloat = hypot(c.x - p.x, c.y - p.y)
                    if d <= Self.vertexRadius, d < (best?.3 ?? .infinity) { best = (mi, vi, isOut, d) }
                }
            }
        }
        return best.map { ($0.0, $0.1, $0.2) }
    }

    /// A point on the outline of an active mask within `vertexRadius` (a click there adds a vertex).
    public func hitSegment(_ p: CGPoint, masks: [MaskOverlay]) -> (mask: Int, segment: Int, t: Double)? {
        guard let n = framePoint(p) else { return nil }
        var best: (Int, Int, Double, Double)?
        for (mi, m) in masks.enumerated() where m.active {
            guard let h = m.path.nearestSegment(to: n, frame: frameExtent), h.distance <= Double(Self.vertexRadius) else { continue }
            if h.distance < (best?.3 ?? .infinity) { best = (mi, h.segment, h.t, h.distance) }
        }
        return best.map { ($0.0, $0.1, $0.2) }
    }

    /// The topmost mask (last drawn) whose outline contains `p`, active or not.
    public func hitAnyInside(_ p: CGPoint, masks: [MaskOverlay]) -> Int? {
        guard let n = framePoint(p) else { return nil }
        return masks.indices.last { MaskCoverage.signedDistance(n, polygon: masks[$0].path.polygon()) < 0 }
    }

    /// The topmost active mask whose outline contains `p`.
    public func hitInside(_ p: CGPoint, masks: [MaskOverlay]) -> Int? {
        guard let n = framePoint(p) else { return nil }
        return masks.indices.first { masks[$0].active && MaskCoverage.signedDistance(n, polygon: masks[$0].path.polygon()) < 0 }
    }
}
