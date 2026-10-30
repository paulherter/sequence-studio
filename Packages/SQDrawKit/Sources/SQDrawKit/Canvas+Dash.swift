import Foundation

/// Dashed outlines (NSBezierPath `setLineDash`) and fills clipped to a rounded rectangle (`addPath(roundedRect) + clip`),
/// built from the existing quad kinds so every renderer draws them unchanged.
extension Canvas {
    /// The outline of a rounded rectangle as a closed point path (corner arcs in `steps` pieces each), clockwise from the
    /// top edge, in points.
    public static func roundedRectPath(_ r: CGRect, radius: CGFloat, steps: Int = 6) -> [CGPoint] {
        let rad = max(0, min(radius, r.width / 2, r.height / 2))
        guard rad > 0 else { return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                                     CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)] }
        let corners: [(CGPoint, CGFloat)] = [(CGPoint(x: r.maxX - rad, y: r.minY + rad), -.pi / 2),
                                             (CGPoint(x: r.maxX - rad, y: r.maxY - rad), 0),
                                             (CGPoint(x: r.minX + rad, y: r.maxY - rad), .pi / 2),
                                             (CGPoint(x: r.minX + rad, y: r.minY + rad), .pi)]
        var out: [CGPoint] = []
        for (c, a0) in corners {
            for i in 0...steps {
                let a = a0 + CGFloat(i) / CGFloat(steps) * .pi / 2
                out.append(CGPoint(x: c.x + rad * cos(a), y: c.y + rad * sin(a)))
            }
        }
        return out
    }

    /// A dashed line along `points` (`closed` joins the last point to the first): `on` points drawn, `off` skipped,
    /// starting at `phase` into the pattern; butt-ended segments of `width`.
    public mutating func strokeDashed(_ points: [CGPoint], closed: Bool = false, width: CGFloat, on: CGFloat, off: CGFloat,
                                      phase: CGFloat = 0, _ c: DrawColor) {
        guard points.count > 1, on > 0, off >= 0 else { return }
        let path = closed ? points + [points[0]] : points
        let period = on + off
        var at = phase.truncatingRemainder(dividingBy: period)       // position in the pattern
        for i in 1..<path.count {
            let a = path[i - 1], b = path[i]
            let len = hypot(b.x - a.x, b.y - a.y)
            guard len > 0 else { continue }
            var s: CGFloat = 0
            while s < len {
                let drawing = at < on
                let step = min((drawing ? on - at : period - at), len - s)
                if drawing {
                    let p0 = CGPoint(x: a.x + (b.x - a.x) * s / len, y: a.y + (b.y - a.y) * s / len)
                    let p1 = CGPoint(x: a.x + (b.x - a.x) * (s + step) / len, y: a.y + (b.y - a.y) * (s + step) / len)
                    strokeButt(from: p0, to: p1, width: width, c)
                }
                s += step
                at = (at + step).truncatingRemainder(dividingBy: period)
            }
        }
    }

    /// A dashed rounded-rectangle outline, centered on the edge like `stroke(roundedRect:)`.
    public mutating func strokeDashed(roundedRect r: CGRect, radius: CGFloat, width: CGFloat, on: CGFloat, off: CGFloat, _ c: DrawColor) {
        strokeDashed(Self.roundedRectPath(r, radius: radius), closed: true, width: width, on: on, off: off, c)
    }

    /// `r` filled only where it lies inside the rounded rectangle `clip` (a strip along a clip body keeps the round
    /// corners): full rows as one quad, the rows in the corner bands as one span quad per device row.
    public mutating func fill(_ r: CGRect, insideRoundedRect clip: CGRect, radius: CGFloat, _ c: DrawColor) {
        let box = r.intersection(clip)
        guard !box.isNull, box.width > 0, box.height > 0 else { return }
        let rad = max(0, min(radius, clip.width / 2, clip.height / 2))
        let topBand = clip.minY + rad, bottomBand = clip.maxY - rad
        let midTop = max(box.minY, topBand), midBottom = min(box.maxY, bottomBand)
        if midBottom > midTop { fill(CGRect(x: box.minX, y: midTop, width: box.width, height: midBottom - midTop), c) }
        guard rad > 0 else { return }
        let rowH = 1 / CGFloat(scale)
        func span(_ y0: CGFloat, _ y1: CGFloat) {
            var y = y0
            while y < y1 {
                let h = min(rowH, y1 - y), cy = y + h / 2
                let dy = cy < topBand ? topBand - cy : cy - bottomBand
                let inset = rad - sqrt(max(0, rad * rad - dy * dy))
                let x0 = max(box.minX, clip.minX + inset), x1 = min(box.maxX, clip.maxX - inset)
                if x1 > x0 { fill(CGRect(x: x0, y: y, width: x1 - x0, height: h), c) }
                y += h
            }
        }
        if box.minY < topBand { span(box.minY, min(box.maxY, topBand)) }
        if box.maxY > bottomBand { span(max(box.minY, bottomBand), box.maxY) }
    }

    /// A butt-ended line of `width` (an axis-aligned one is one rect; others a thin quad polygon).
    mutating func strokeButt(from a: CGPoint, to b: CGPoint, width: CGFloat, _ c: DrawColor) {
        if a.y == b.y { fill(CGRect(x: min(a.x, b.x), y: a.y - width / 2, width: abs(b.x - a.x), height: width), c); return }
        if a.x == b.x { fill(CGRect(x: a.x - width / 2, y: min(a.y, b.y), width: width, height: abs(b.y - a.y)), c); return }
        strokeLine(from: a, to: b, width: width, c)
    }
}
