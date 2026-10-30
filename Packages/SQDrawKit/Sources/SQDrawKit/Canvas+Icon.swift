import Foundation
import SQUIKit

/// An icon outline on the 24 grid as polylines: the `SQIconPathSink` of the shared toolkit. Curves are flattened (the Mac
/// keeps them as a CGPath); Lucide strokes are round-capped and round-joined, which is exactly what chained round-capped
/// segments draw.
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

    /// The flattened outline of `icon` (cached; empty when the file is missing).
    public static func outline(_ icon: SQIcon) -> [[CGPoint]] {
        cache.withLock { c in
            if let hit = c[icon] { return hit }
            let lines = icon.svgSource.map { svg in
                SQIconSVG.shapes(svg) { IconOutline() }.flatMap { $0.0.finish() }
            } ?? []
            c[icon] = lines
            return lines
        }
    }
    private static let cache = LockedBox<[SQIcon: [[CGPoint]]]>([:])
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func withLock<R>(_ f: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return f(&value) }
}

extension Canvas {
    /// `SQIcon.image(size:color:)` drawn at `box` (square `size`, top-left at `box.origin`): the optical stroke of the Mac
    /// renderer, 1.6 on the 24 grid and thicker below 16 pt.
    /// shortcut: filled shapes use the hard-edged span fill under the stroke, and translucent colors darken where segments overlap;
    /// upgrade to a path fill quad when a filled icon or a translucent icon color shows it.
    public mutating func draw(icon: SQIcon, at origin: CGPoint, size: CGFloat, _ c: DrawColor, stroke: CGFloat? = nil) {
        let width = (stroke ?? max(1.6, 22.8 / max(size, 1))) * size / 24
        let k = size / 24
        for line in IconOutline.outline(icon) {
            // The Mac fills the closed shapes of play, pause, stop, heart, star, folder and bookmark (`SQIcon.isFilled`).
            if icon.isFilled, line.count > 3, line.first == line.last {
                fill(polygon: line.map { CGPoint(x: origin.x + $0.x * k, y: origin.y + $0.y * k) }, c)
            }
            strokePolyline(line.map { CGPoint(x: origin.x + $0.x * k, y: origin.y + $0.y * k) }, width: width, c)
        }
    }
}
