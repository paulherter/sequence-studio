import Foundation
import SQCore

/// Maps a Color Step window (picture space, uv 0...1, y down; width and height as fractions of the picture; rotation
/// clockwise about the center, measured in aspect-corrected space exactly like the render shader) onto the Program
/// monitor and back, and turns drags of its handles into a new window. Pure; `StepWindowOverlayView` draws and routes.
public struct StepWindowEditGeometry: Sendable, Equatable {
    public enum Edge: Sendable, Hashable, CaseIterable { case right, left, top, bottom }
    public enum Hit: Sendable, Equatable {
        case rotate, edge(Edge), center, body
    }

    /// Smallest and largest size a drag sets (fractions; the sliders' 1...200 %).
    public static let sizeRange: ClosedRange<Float> = 0.01...2
    /// Distance of the rotate handle beyond the top edge, in view points.
    public static let rotateOffset: CGFloat = 24
    /// Where the linear shape's rotate handle sits above its line (fraction of the picture height).
    public static let linearReach: Double = 0.15

    public var layer: ZoomEditGeometry
    public init(layer: ZoomEditGeometry) { self.layer = layer }

    /// Picture width / height, the render shader's `aspect`.
    public var aspect: Double {
        let s = layer.layer.fittedSize
        return s.height > 0 ? Double(s.width / s.height) : 16.0 / 9
    }

    // MARK: Spaces

    private func rotation(_ w: StepWindow) -> (c: Double, s: Double) {
        let r = Double(w.rotation) * .pi / 180
        return (cos(r), sin(r))
    }

    /// Window space (x along the window's width in aspect-corrected units, y along its height) to picture uv.
    public func uv(fromWindow q: Vec2, _ w: StepWindow) -> Vec2 {
        let (c, s) = rotation(w)
        let px = q.x * c - q.y * s, py = q.x * s + q.y * c
        return Vec2(Double(w.centerX) + px / max(aspect, 1e-6), Double(w.centerY) + py)
    }

    /// Picture uv to window space (inverse of `uv(fromWindow:)`).
    public func window(fromUV p: Vec2, _ w: StepWindow) -> Vec2 {
        let (c, s) = rotation(w)
        let px = (p.x - Double(w.centerX)) * aspect, py = p.y - Double(w.centerY)
        return Vec2(px * c + py * s, -px * s + py * c)
    }

    private func view(_ q: Vec2, _ w: StepWindow) -> CGPoint { layer.viewPoint(uv(fromWindow: q, w)) }

    // MARK: Handles

    /// Half extents in window space.
    private func half(_ w: StepWindow) -> Vec2 { Vec2(Double(w.width) / 2 * aspect, Double(w.height) / 2) }

    public func centerPoint(_ w: StepWindow) -> CGPoint { view(Vec2(0, 0), w) }

    /// Edge handles exist for the ellipse and the rectangle; the linear shape is a line and has none.
    public func edgePoint(_ e: Edge, _ w: StepWindow) -> CGPoint? {
        guard w.shape != .linear else { return nil }
        let h = half(w)
        switch e {
        case .right: return view(Vec2(h.x, 0), w)
        case .left: return view(Vec2(-h.x, 0), w)
        case .top: return view(Vec2(0, -h.y), w)
        case .bottom: return view(Vec2(0, h.y), w)
        }
    }

    /// The rotate handle: beyond the top edge (the linear shape: above its line).
    public func rotatePoint(_ w: StepWindow) -> CGPoint {
        let anchor = w.shape == .linear ? view(Vec2(0, -Self.linearReach), w) : (edgePoint(.top, w) ?? centerPoint(w))
        let c = centerPoint(w)
        let dx = anchor.x - c.x, dy = anchor.y - c.y
        let len = max(hypot(dx, dy), 1e-6)
        return CGPoint(x: anchor.x + dx / len * Self.rotateOffset, y: anchor.y + dy / len * Self.rotateOffset)
    }

    /// The shape's outline in view points (ellipse and rectangle: closed; linear: the line across the picture).
    public func outline(_ w: StepWindow, segments: Int = 64) -> [CGPoint] {
        let h = half(w)
        switch w.shape {
        case .rectangle:
            return [Vec2(-h.x, -h.y), Vec2(h.x, -h.y), Vec2(h.x, h.y), Vec2(-h.x, h.y)].map { view($0, w) }
        case .ellipse:
            return (0..<segments).map { i in
                let a = Double(i) / Double(segments) * 2 * .pi
                return view(Vec2(cos(a) * h.x, sin(a) * h.y), w)
            }
        case .linear:
            let reach = max(aspect, 1) * 2
            return [view(Vec2(-reach, 0), w), view(Vec2(reach, 0), w)]
        }
    }

    // MARK: Hit testing

    /// Rotate handle, edge handles, center, then the body (inside an ellipse or rectangle) for moving.
    public func hitTest(_ p: CGPoint, _ w: StepWindow, handleRadius: CGFloat = 8) -> Hit? {
        func near(_ q: CGPoint?) -> Bool { q.map { hypot($0.x - p.x, $0.y - p.y) <= handleRadius } ?? false }
        if near(rotatePoint(w)) { return .rotate }
        for e in Edge.allCases where near(edgePoint(e, w)) { return .edge(e) }
        if near(centerPoint(w)) { return .center }
        guard w.shape != .linear else { return nil }
        let q = window(fromUV: layer.normalised(p), w), h = half(w)
        let inside = w.shape == .rectangle
            ? abs(q.x) <= h.x && abs(q.y) <= h.y
            : (q.x / max(h.x, 1e-9)) * (q.x / max(h.x, 1e-9)) + (q.y / max(h.y, 1e-9)) * (q.y / max(h.y, 1e-9)) <= 1
        return inside ? .body : nil
    }

    // MARK: Dragging

    /// The window after dragging `hit` from `press` to `p`; `base` is the window at the press. Position stays on the
    /// picture, sizes inside `sizeRange`, rotation inside -180...180; shape, softness and invert are never touched.
    public func dragged(_ hit: Hit, from press: CGPoint, to p: CGPoint, base: StepWindow) -> StepWindow {
        var w = base
        let n0 = layer.normalised(press), n1 = layer.normalised(p)
        switch hit {
        case .center, .body:
            w.centerX = Float(min(max(Double(base.centerX) + n1.x - n0.x, 0), 1))
            w.centerY = Float(min(max(Double(base.centerY) + n1.y - n0.y, 0), 1))
        case .edge(let e):
            let q = window(fromUV: n1, base)
            switch e {
            case .left, .right: w.width = Self.clampSize(Float(abs(q.x) * 2 / max(aspect, 1e-6)))
            case .top, .bottom: w.height = Self.clampSize(Float(abs(q.y) * 2))
            }
        case .rotate:
            let px = (n1.x - Double(base.centerX)) * aspect, py = n1.y - Double(base.centerY)
            guard hypot(px, py) > 1e-6 else { return base }
            w.rotation = Float(atan2(px, -py) * 180 / .pi)
        }
        return w
    }

    private static func clampSize(_ v: Float) -> Float { min(max(v, sizeRange.lowerBound), sizeRange.upperBound) }
}
