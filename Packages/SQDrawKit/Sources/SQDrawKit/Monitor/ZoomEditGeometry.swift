import Foundation
import SQCore

/// Maps Dynamic Zoom windows (normalized picture space, 0...1, y down) onto the Program monitor and back, through the clip's
/// Motion transform (the same layer quad the transform overlay draws). Pure; hit testing and drag maths for
/// `ZoomEditOverlayView`.
public struct ZoomEditGeometry: Sendable, Equatable {
    public enum Which: Sendable, Hashable { case start, end }
    public enum Hit: Sendable, Equatable {
        case corner(Which, ZoomCorner)
        case body(Which)
    }
    public var layer: TransformOverlayGeometry
    public init(layer: TransformOverlayGeometry) { self.layer = layer }

    /// The picture's size at scale 1 (sequence px).
    private var size: CGSize { layer.fittedSize }

    public func viewPoint(_ n: Vec2) -> CGPoint {
        layer.viewPoint(fromLocal: Vec2((n.x - 0.5) * Double(size.width), (n.y - 0.5) * Double(size.height)))
    }

    /// Inverse of `viewPoint` (through position, rotation, scale and anchor of the layer transform).
    public func normalised(_ p: CGPoint) -> Vec2 {
        let t = layer.transform, o = layer.offset(fromView: p)
        let d = o - t.position, a = -t.rotation * .pi / 180
        let r = Vec2(d.x * cos(a) - d.y * sin(a), d.x * sin(a) + d.y * cos(a))
        let l = Vec2(r.x / max(t.scale.x, 1e-6), r.y / max(t.scale.y, 1e-6)) + t.anchor
        return Vec2(l.x / max(Double(size.width), 1e-6) + 0.5, l.y / max(Double(size.height), 1e-6) + 0.5)
    }

    public func corner(_ c: ZoomCorner, of r: ZoomRect) -> CGPoint {
        switch c {
        case .topLeft: viewPoint(Vec2(r.x, r.y))
        case .topRight: viewPoint(Vec2(r.x + r.width, r.y))
        case .bottomRight: viewPoint(Vec2(r.x + r.width, r.y + r.height))
        case .bottomLeft: viewPoint(Vec2(r.x, r.y + r.height))
        }
    }
    public func quad(of r: ZoomRect) -> [CGPoint] { ZoomCorner.allCases.map { corner($0, of: r) } }
    public func centre(of r: ZoomRect) -> CGPoint { viewPoint(Vec2(r.x + r.width / 2, r.y + r.height / 2)) }

    /// Corner handles first (end window before start where they overlap), then bodies (end, then start).
    public func hitTest(_ p: CGPoint, start: ZoomRect, end: ZoomRect, handleRadius: CGFloat = 8) -> Hit? {
        for w in [Which.end, .start] {
            let r = w == .end ? end : start
            for c in ZoomCorner.allCases {
                let q = corner(c, of: r)
                if hypot(q.x - p.x, q.y - p.y) <= handleRadius { return .corner(w, c) }
            }
        }
        let n = normalised(p)
        for w in [Which.end, .start] {
            let r = (w == .end ? end : start).clamped
            if n.x >= r.x, n.x <= r.x + r.width, n.y >= r.y, n.y <= r.y + r.height { return .body(w) }
        }
        return nil
    }

    /// The windows after dragging `hit` from `startView` (press) to `p`; `base` are the windows at the press.
    public func dragged(_ hit: Hit, from startView: CGPoint, to p: CGPoint, base: (start: ZoomRect, end: ZoomRect))
        -> (start: ZoomRect, end: ZoomRect) {
        var out = base
        let n0 = normalised(startView), n1 = normalised(p)
        switch hit {
        case .body(let w):
            let moved = (w == .start ? base.start : base.end).moved(by: Vec2(n1.x - n0.x, n1.y - n0.y))
            if w == .start { out.start = moved } else { out.end = moved }
        case .corner(let w, let c):
            let resized = (w == .start ? base.start : base.end).resized(corner: c, to: n1)
            if w == .start { out.start = resized } else { out.end = resized }
        }
        return out
    }
}
