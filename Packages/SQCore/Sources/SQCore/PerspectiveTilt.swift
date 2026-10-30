import Foundation

/// Perspective tilt of a layer (Tilt X / Tilt Y): the layer plane turns about the horizontal (X) and vertical (Y) axis
/// through its anchor, then a pinhole camera `focal` px in front of that plane projects it. One projective geometry for
/// render (the compositor's vertex stage mirrors `project`), the monitor overlay and hit-testing.
///
/// Spaces: the input point is the offset from the anchor in sequence px, y down, after scale and in-plane rotation (the
/// tilt axes stay screen-aligned, the way a card turns in front of the camera). Positive Tilt X moves the top edge away
/// from the viewer, positive Tilt Y the right edge. The output is the offset from the anchor on screen.
///
/// Identity at 0 / 0: `project` returns the input exactly, and the render path is the untouched affine one.
public enum PerspectiveTilt {
    /// Largest turn either way; at 90 the plane would be edge-on (a line).
    public static let maxDegrees = 89.0

    public static func clamped(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        return min(max(degrees, -maxDegrees), maxDegrees)
    }

    public static func isIdentity(tiltX: Double, tiltY: Double) -> Bool { tiltX == 0 && tiltY == 0 }

    /// Camera distance in px. It exceeds the farthest point of the layer from its anchor (`layerRadius`, after scale), so
    /// no point of the plane can reach or cross the camera plane at any tilt (its depth is at most that radius), and it
    /// is never below 1.5 canvas sides, which keeps small layers at a natural strength of perspective.
    public static func focal(layerRadius: Double, canvas: Vec2) -> Double {
        let r = layerRadius.isFinite ? max(layerRadius, 0) : 0
        let side = max(canvas.x, canvas.y, 1)
        return max(1.5 * side, 1.5 * r)
    }

    /// The farthest corner of a `size` layer (px) from `anchor` (layer-local, from the layer center) after `scale`.
    public static func layerRadius(size: Vec2, anchor: Vec2, scale: Vec2) -> Double {
        var m = 0.0
        for sx in [-0.5, 0.5] {
            for sy in [-0.5, 0.5] {
                let d = Vec2((size.x * sx - anchor.x) * max(scale.x, 0), (size.y * sy - anchor.y) * max(scale.y, 0))
                m = max(m, d.length)
            }
        }
        return m
    }

    private static func rotated(_ x: Double, _ y: Double, _ z: Double, _ tiltX: Double, _ tiltY: Double) -> (Double, Double, Double) {
        let a = clamped(tiltX) * .pi / 180, b = clamped(tiltY) * .pi / 180
        let ca = cos(a), sa = sin(a), cb = cos(b), sb = sin(b)
        let y1 = y * ca + z * sa, z1 = -y * sa + z * ca
        return (x * cb - z1 * sb, y1, x * sb + z1 * cb)
    }

    /// `(focal + depth) / focal` of the plane point `p` after the turn: the vertex stage's `w`. Positive for every point of
    /// a layer within the radius `focal` was derived from.
    public static func depthDivisor(_ p: Vec2, tiltX: Double, tiltY: Double, focal: Double) -> Double {
        let r = rotated(p.x, p.y, 0, tiltX, tiltY)
        return (focal + r.2) / focal
    }

    /// Plane point `p` to its place on screen.
    public static func project(_ p: Vec2, tiltX: Double, tiltY: Double, focal: Double) -> Vec2 {
        if isIdentity(tiltX: tiltX, tiltY: tiltY) { return p }
        let r = rotated(p.x, p.y, 0, tiltX, tiltY)
        let w = (focal + r.2) / focal
        guard w > 1e-6 else { return Vec2(r.0 * 1e6, r.1 * 1e6) }
        return Vec2(r.0 / w, r.1 / w)
    }

    /// Screen offset `q` back to the plane point that lands there (the ray through `q` meets the turned plane).
    public static func unproject(_ q: Vec2, tiltX: Double, tiltY: Double, focal: Double) -> Vec2 {
        if isIdentity(tiltX: tiltX, tiltY: tiltY) { return q }
        let a = clamped(tiltX) * .pi / 180, b = clamped(tiltY) * .pi / 180
        let ca = cos(a), sa = sin(a), cb = cos(b), sb = sin(b)
        // Plane normal after the turn: the turned (0, 0, 1).
        let n = rotated(0, 0, 1, tiltX, tiltY)
        // Camera at depth -focal; a ray through screen point q: P(k) = (q.x k, q.y k, focal (k - 1)); n . P = 0.
        let den = n.0 * q.x + n.1 * q.y + n.2 * focal
        guard abs(den) > 1e-12 else { return q }
        let k = n.2 * focal / den
        let (x2, y1, z2) = (q.x * k, q.y * k, focal * (k - 1))
        // Undo the turn about Y, then about X.
        let x = x2 * cb + z2 * sb
        let z1 = -x2 * sb + z2 * cb
        let y = y1 * ca - z1 * sa
        return Vec2(x, y)
    }
}
