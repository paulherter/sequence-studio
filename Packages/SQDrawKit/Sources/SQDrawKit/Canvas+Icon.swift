import Foundation
import SQUIKit

/// An icon outline on its own grid as polylines: the `SQIconPathSink` of the shared toolkit. Curves are flattened (the Mac
/// keeps them as a CGPath). Phosphor glyphs are filled outlines (nonzero winding, see `Canvas.fill(contours:)`); own drawings
/// are round-capped, round-joined strokes, which is exactly what chained round-capped segments draw.
public final class IconOutline: SQIconPathSink {
    public private(set) var polylines: [[CGPoint]] = []
    private var current: [CGPoint] = []
    private var start = CGPoint.zero
    /// Segments per curve (an icon curve spans a few grid units, 8 keeps it smooth at 32 px).
    static let curveSteps = 8

    public init() {}

    public func sinkMove(_ p: CGPoint) { flush(); current = [p]; start = p }
    public func sinkLine(_ p: CGPoint) { if current.isEmpty { current = [start] }; current.append(p) }
    public func sinkCurve(to p: CGPoint, control1 c1: CGPoint, control2 c2: CGPoint) {
        if current.isEmpty { current = [start] }
        let p0 = current[current.count - 1]
        for i in 1...Self.curveSteps {
            let t = CGFloat(i) / CGFloat(Self.curveSteps), u = 1 - t
            let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
            current.append(CGPoint(x: a * p0.x + b * c1.x + c * c2.x + d * p.x, y: a * p0.y + b * c1.y + c * c2.y + d * p.y))
        }
    }
    public func sinkQuad(to p: CGPoint, control q: CGPoint) {
        if current.isEmpty { current = [start] }
        let p0 = current[current.count - 1]
        for i in 1...Self.curveSteps {
            let t = CGFloat(i) / CGFloat(Self.curveSteps), u = 1 - t
            current.append(CGPoint(x: u * u * p0.x + 2 * u * t * q.x + t * t * p.x, y: u * u * p0.y + 2 * u * t * q.y + t * t * p.y))
        }
    }
    public func sinkClose() {
        if !current.isEmpty, current.last != start { current.append(start) }
        flush()
    }
    func finish() -> [[CGPoint]] { flush(); return polylines }
    private func flush() {
        if current.count > 1 { polylines.append(current) }
        current = []
    }

    /// The flattened glyph of an icon: contours to fill and polylines to stroke, on a `grid` square.
    public struct Glyph: Sendable {
        public var grid: CGFloat = 24
        public var lineWidth: CGFloat = 1.5
        public var fills: [[CGPoint]] = []
        public var strokes: [[CGPoint]] = []
    }

    /// The flattened glyph of `icon` (cached; empty when the file is missing).
    public static func glyph(_ icon: SQIcon) -> Glyph {
        cache.withLock { c in
            if let hit = c[icon] { return hit }
            var g = Glyph()
            if let svg = icon.svgSource {
                let doc = SQIconSVG.document(svg)
                g.grid = doc.grid
                g.lineWidth = doc.lineWidth
                for (outline, shape) in SQIconSVG.shapes(svg, make: { IconOutline() }) {
                    let lines = outline.finish()
                    if shape.fill { g.fills += lines }
                    if shape.stroke { g.strokes += lines }
                }
            }
            c[icon] = g
            return g
        }
    }

    /// Every polyline of `icon` (fills and strokes), for tests.
    public static func outline(_ icon: SQIcon) -> [[CGPoint]] {
        let g = glyph(icon)
        return g.fills + g.strokes
    }
    private static let cache = LockedBox<[SQIcon: Glyph]>([:])
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func withLock<R>(_ f: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return f(&value) }
}

extension Canvas {
    /// `SQIcon.image(size:color:)` drawn at `origin` (square `size`, top-left): Phosphor glyphs as antialiased nonzero fills,
    /// own drawings as strokes of the file's 1.5 on 24. Like the Mac renderer no line is thinner than `SQIconWeight.minLine`
    /// points (a Regular glyph is widened by stroking its outline with the missing width). `stroke` (grid units) overrides
    /// the line width of stroked drawings.
    public mutating func draw(icon: SQIcon, at origin: CGPoint, size: CGFloat, _ c: DrawColor, stroke: CGFloat? = nil) {
        let g = IconOutline.glyph(icon)
        let k = size / g.grid
        func map(_ line: [CGPoint]) -> [CGPoint] { line.map { CGPoint(x: origin.x + $0.x * k, y: origin.y + $0.y * k) } }
        let thin = SQIconWeight.minLine / k  // grid units
        if !g.fills.isEmpty {
            let contours = g.fills.map(map)
            fill(contours: contours, c)
            let extra = icon.isFilled ? 0 : max(0, thin - g.grid / 16)
            if extra > 0 { for line in contours { strokePolyline(line, width: extra * k, c) } }
        }
        let width = stroke ?? max(g.lineWidth, icon.isFilled ? 0 : thin)
        for line in g.strokes { strokePolyline(map(line), width: width * k, c) }
    }

    /// Closed contours filled with nonzero winding, antialiased: 4 sub-scanlines per pixel row, exact horizontal coverage,
    /// equal-coverage pixels merged into one quad per run.
    public mutating func fill(contours: [[CGPoint]], _ c: DrawColor) {
        let polys = contours.filter { $0.count > 2 }.map { $0.map { px($0) } }
        guard !polys.isEmpty else { return }
        var minX = Float.greatestFiniteMagnitude, maxX = -Float.greatestFiniteMagnitude
        var minY = Float.greatestFiniteMagnitude, maxY = -Float.greatestFiniteMagnitude
        for p in polys { for q in p { minX = min(minX, q.0); maxX = max(maxX, q.0); minY = min(minY, q.1); maxY = max(maxY, q.1) } }
        let x0 = Int(minX.rounded(.down)), width = max(1, Int(maxX.rounded(.up)) - x0 + 1)
        let sub = 4
        var cov = [Float](repeating: 0, count: width)
        var hits: [(x: Float, dir: Int)] = []
        var y = minY.rounded(.down)
        while y < maxY {
            for i in 0..<width { cov[i] = 0 }
            for s in 0..<sub {
                let sy = y + (Float(s) + 0.5) / Float(sub)
                hits.removeAll(keepingCapacity: true)
                for p in polys {
                    var j = p.count - 1
                    for i in 0..<p.count {
                        let (ax, ay) = p[j], (bx, by) = p[i]
                        if (ay <= sy && by > sy) || (by <= sy && ay > sy) {
                            hits.append((ax + (sy - ay) / (by - ay) * (bx - ax), by > ay ? 1 : -1))
                        }
                        j = i
                    }
                }
                hits.sort { $0.x < $1.x }
                var wind = 0
                var spanStart: Float = 0
                for h in hits {
                    let before = wind
                    wind += h.dir
                    if before == 0 && wind != 0 { spanStart = h.x - Float(x0) }
                    if before != 0 && wind == 0 {
                        let b = h.x - Float(x0)
                        var i = max(0, Int(spanStart.rounded(.down)))
                        while i < width, Float(i) < b {
                            let l = max(spanStart, Float(i)), r = min(b, Float(i + 1))
                            if r > l { cov[i] += (r - l) / Float(sub) }
                            i += 1
                        }
                    }
                }
            }
            var i = 0
            while i < width {
                let v = min(cov[i], 1)
                if v < 0.004 { i += 1; continue }
                var j = i + 1
                while j < width, abs(min(cov[j], 1) - v) < 0.004 { j += 1 }
                list.fill(DrawRect(x: Float(x0 + i), y: y, w: Float(j - i), h: 1), c.alpha(c.a * v))
                i = j
            }
            y += 1
        }
    }
}
