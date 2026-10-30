import Foundation
import SQCore

/// Shape clips on the portable raster (Windows): the drawing of the Mac `ShapeRenderer` (SQRender, Core Graphics) on the
/// text raster's coverage masks, so both platforms share one polygon rasterizer. Same picture size (one px per sequence
/// px, at most `maxSide`), same centered box, colors display-encoded BT.709 linearized with the inverse BT.709 OETF,
/// premultiplied linear light, top row first.
public enum PortableShapeRenderer {
    /// A drawn shape: the picture and the size in sequence px it covers (larger than the picture when a huge shape was
    /// drawn scaled down).
    public struct Shape: Sendable {
        public let picture: PortableTextRenderer.Picture
        public let width: Double, height: Double
    }

    public static let maxSide = 4096

    /// nil when nothing is visible (no fill and no stroke, zero size, a path with fewer than two points).
    public static func render(_ s: ShapeStyle) -> Shape? {
        guard !s.isEmpty else { return nil }
        let size = s.rasterSize
        guard size.width > 0, size.height > 0 else { return nil }
        let k = min(1, Double(maxSide) / max(size.width, size.height))
        let w = min(max(Int((size.width * k).rounded(.up)), 1), maxSide)
        let h = min(max(Int((size.height * k).rounded(.up)), 1), maxSide)
        let boxW = Double(w) / k, boxH = Double(h) / k
        let ox = (boxW - size.width) / 2, oy = (boxH - size.height) / 2
        var canvas = LinearCanvas(width: w, height: h)
        // The Mac draws y up (Core Graphics); points here are given the same way and flipped into pixels (y down).
        func px(_ x: Double, _ y: Double) -> SIMD2<Double> { SIMD2(x * k, (boxH - y) * k) }

        func fill(_ poly: [SIMD2<Double>], _ color: EffectColor) {
            var m = PolygonMask(width: w, height: h)
            m.add(poly)
            let mask = m.mask()
            guard let end = s.gradientEnd else { canvas.fill(mask, color: premultiplied(color)); return }
            // Core Graphics' linear gradient across the path's bounds (y up), extended past both ends.
            let xs = poly.map(\.x), ys = poly.map(\.y)
            let minX = xs.min()! / k, maxX = xs.max()! / k
            let minY = boxH - ys.max()! / k, maxY = boxH - ys.min()! / k
            let a = s.gradientAngle * .pi / 180
            let dx = cos(a), dy = -sin(a)
            let half = (abs((maxX - minX) * dx) + abs((maxY - minY) * dy)) / 2
            let mx = (minX + maxX) / 2, my = (minY + maxY) / 2
            let c0 = straight(color), c1 = straight(end)
            canvas.fill(mask) { x, y in
                let X = (Double(x) + 0.5) / k, Y = boxH - (Double(y) + 0.5) / k
                let t = half > 0 ? min(1, max(0, ((X - mx) * dx + (Y - my) * dy) / (2 * half) + 0.5)) : 0
                let c = c0 + (c1 - c0) * Float(t)
                return SIMD4(c.x * c.w, c.y * c.w, c.z * c.w, c.w)
            }
        }
        func stroke(_ line: [SIMD2<Double>], closed: Bool, _ color: EffectColor) {
            guard s.strokeWidth > 0, line.count > 1 else { return }
            let r = s.strokeWidth / 2 * k
            var m = PolygonMask(width: w, height: h)
            if closed { m.stroke([line], halfWidth: r) } else {
                // Round caps and joins along an open path: a disc per point, a rectangle per segment.
                for i in line.indices {
                    m.addPositive(PolygonMask.disc(line[i], r))
                    guard i + 1 < line.count else { continue }
                    let a = line[i], b = line[i + 1], d = b - a, len = (d * d).sum().squareRoot()
                    guard len > 1e-9 else { continue }
                    let n = SIMD2(-d.y, d.x) / len * r
                    m.addPositive([a + n, b + n, b - n, a - n])
                }
            }
            canvas.fill(m.mask(), color: premultiplied(color))
        }

        if let pts = s.path {
            guard pts.count >= 2 else { return nil }
            let half = s.stroke == nil ? 0 : s.strokeWidth / 2
            let line = pts.map { px(ox + half + $0.x * s.width, boxH - (oy + half + $0.y * s.height)) }
            if let f = s.fill, s.pathClosed { fill(line, f) }
            if let st = s.stroke { stroke(line, closed: s.pathClosed, st) }
        } else if s.kind == .line {
            guard let st = s.stroke else { return nil }
            // A plain rectangle in the stroke color (no gradient).
            var m = PolygonMask(width: w, height: h)
            m.add([px(ox, oy), px(ox + s.width, oy), px(ox + s.width, oy + s.strokeWidth), px(ox, oy + s.strokeWidth)])
            canvas.fill(m.mask(), color: premultiplied(st))
        } else {
            let half = s.stroke == nil ? 0 : s.strokeWidth / 2
            let rx = ox + half, ry = oy + half
            let outline: [SIMD2<Double>] = switch s.kind {
            case .ellipse: ellipse(x: rx, y: ry, width: s.width, height: s.height, k: k).map { px($0.x, $0.y) }
            case .arrow: s.arrowPoints.map { px(rx + $0.x, ry + $0.y) }
            default:
                PolygonMask.roundedRect(x: rx, y: ry, width: s.width, height: s.height, radius: s.cornerRadius).map { px($0.x, $0.y) }
            }
            if let f = s.fill { fill(outline, f) }
            if let st = s.stroke { stroke(outline, closed: true, st) }
        }
        return Shape(picture: PortableTextRenderer.Picture(width: w, height: h, pixels: canvas.pixels), width: boxW, height: boxH)
    }

    /// An ellipse in the rect as a polygon fine enough at `k` pixels per unit.
    static func ellipse(x: Double, y: Double, width: Double, height: Double, k: Double) -> [SIMD2<Double>] {
        let rx = width / 2, ry = height / 2
        let n = max(16, min(1024, Int((Double.pi * (rx + ry) * k / 2).rounded(.up))))
        return (0..<n).map { i in
            let t = Double(i) / Double(n) * 2 * .pi
            return SIMD2(x + rx + cos(t) * rx, y + ry + sin(t) * ry)
        }
    }

    /// The Mac `ShapeRenderer.linear`: BT.709 inverse OETF.
    static func linear(_ e: Double) -> Double {
        e < 0.081242858 ? e / 4.5 : pow((e + 0.09929682680944) / 1.09929682680944, 1 / 0.45)
    }

    /// Straight linear RGBA (Core Graphics interpolates gradient colors unpremultiplied).
    static func straight(_ c: EffectColor) -> SIMD4<Float> {
        let k = c.clamped
        return SIMD4(Float(linear(k.red)), Float(linear(k.green)), Float(linear(k.blue)), Float(k.alpha))
    }

    static func premultiplied(_ c: EffectColor) -> SIMD4<Float> {
        let s = straight(c)
        return SIMD4(s.x * s.w, s.y * s.w, s.z * s.w, s.w)
    }
}
