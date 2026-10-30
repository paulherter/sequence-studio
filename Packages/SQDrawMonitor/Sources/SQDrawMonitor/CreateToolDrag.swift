import Foundation
import SQCore
import SQEditorSession

/// One Create tool drag on the Program monitor, in view points (y down): what it would make right now.
/// Shift constrains (square, circle, 45 degree steps), Option (Alt) grows from the press point. Moved from SQMonitorUI
/// so the Mac surface and the canvas monitor share it.
public struct CreateToolDrag: Equatable, Sendable {
    public enum Outline: Equatable, Sendable {
        case box(GraphicsRect, ellipse: Bool)
        case line(Vec2, Vec2)
        case stroke([Vec2])
    }

    /// Smoothing tolerance of a drawn stroke, view points.
    public static let strokeTolerance = 1.5
    /// Recorded stroke points lie at least this far apart, view points.
    public static let strokeStep = 2.0
    /// Smallest drag (view points) that makes an item; a click makes nothing (ProgramSurfaceView.minBoxDrag).
    public static let minDrag: CGFloat = 6

    public let mode: CreateToolMode
    public let start: Vec2
    public private(set) var current: Vec2
    public private(set) var constrain = false
    public private(set) var fromCenter = false
    public private(set) var stroke: [Vec2]

    public init(mode: CreateToolMode, start: CGPoint) {
        self.mode = mode
        self.start = Vec2(Double(start.x), Double(start.y))
        current = self.start
        stroke = [self.start]
    }

    public mutating func move(to p: CGPoint, constrain: Bool, fromCenter: Bool) {
        move(to: Vec2(Double(p.x), Double(p.y)), constrain: constrain, fromCenter: fromCenter)
    }

    public mutating func move(to p: Vec2, constrain: Bool, fromCenter: Bool) {
        current = p
        self.constrain = constrain
        self.fromCenter = fromCenter
        if mode == .draw, let last = stroke.last, (p - last).length >= Self.strokeStep { stroke.append(p) }
    }

    /// False while the pointer has not left the press point by `minimum` view points: a click makes nothing.
    public func isDrag(minimum: CGFloat) -> Bool {
        if mode == .draw { return stroke.count >= 2 && stroke.contains { ($0 - start).length >= Double(minimum) } }
        return abs(current.x - start.x) >= Double(minimum) || abs(current.y - start.y) >= Double(minimum)
    }

    public var outline: Outline {
        switch mode {
        case .line:
            let l = CreateDrag.line(from: start, to: current, constrain: constrain, fromCenter: fromCenter)
            return .line(l.a, l.b)
        case .draw: return .stroke(stroke)
        case .ellipse, .rectangle, .text:
            return .box(CreateDrag.box(from: start, to: current, square: constrain, fromCenter: fromCenter), ellipse: mode == .ellipse)
        }
    }

    /// The size next to the pointer in sequence pixels: "96 × 96" for a box, the length for a line, nothing for a stroke.
    public func sizeLabel(viewPointsPerPixel k: Double) -> String? {
        guard k > 0 else { return nil }
        switch outline {
        case .box(let r, _): return "\(Int((r.width / k).rounded())) × \(Int((r.height / k).rounded()))"
        case .line(let a, let b): return "\(Int(((b - a).length / k).rounded()))"
        case .stroke: return nil
        }
    }

    /// The outline's bounding box in view points (where the size label goes under).
    public var bounds: CGRect {
        switch outline {
        case .box(let r, _): return CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height)
        case .line(let a, let b): return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        case .stroke(let pts):
            let xs = pts.map(\.x), ys = pts.map(\.y)
            guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return .zero }
            return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        }
    }
}
