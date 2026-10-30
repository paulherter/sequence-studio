import Foundation
import SQCore

/// One edge of the clip's Crop effect as an on-canvas handle.
public enum CropEdge: Sendable, CaseIterable {
    case left, top, right, bottom

    /// Parameter key of the Crop effect (values are percent of the clip's own frame).
    public var effectKey: String {
        switch self {
        case .left: ClipEffect.cropLeftKey
        case .top: ClipEffect.cropTopKey
        case .right: ClipEffect.cropRightKey
        case .bottom: ClipEffect.cropBottomKey
        }
    }

    public var title: String {
        switch self { case .left: "Left"; case .top: "Top"; case .right: "Right"; case .bottom: "Bottom" }
    }
    public var isVertical: Bool { self == .left || self == .right }

    public func value(in i: CropInsets) -> Double {
        switch self { case .left: i.left; case .top: i.top; case .right: i.right; case .bottom: i.bottom }
    }
    public func setting(_ v: Double, in i: CropInsets) -> CropInsets {
        var r = i
        switch self { case .left: r.left = v; case .top: r.top = v; case .right: r.right = v; case .bottom: r.bottom = v }
        return r
    }
}

/// Crop handles on the layer: one handle at the middle of each cropped edge, dragged along the clip's own axes
/// (insets are fractions of the clip's frame, applied before the transform, so they follow rotation and scale).
public struct CropHandleGeometry: Sendable {
    public var frame: MaskOverlayGeometry
    /// Grab radius of an edge handle, view pt.
    public static let grabRadius: CGFloat = 9
    /// The part of the frame that always stays (a crop never reaches zero size).
    public static let minRemaining = 0.01

    public init(quad: [CGPoint]) { frame = MaskOverlayGeometry(quad: quad) }

    /// Corners of the kept rectangle in view points (top-left, top-right, bottom-right, bottom-left).
    public func corners(_ i: CropInsets) -> [CGPoint] {
        [frame.viewPoint(Vec2(i.left, i.top)), frame.viewPoint(Vec2(1 - i.right, i.top)),
         frame.viewPoint(Vec2(1 - i.right, 1 - i.bottom)), frame.viewPoint(Vec2(i.left, 1 - i.bottom))]
    }

    public func handlePoint(_ e: CropEdge, _ i: CropInsets) -> CGPoint {
        let midX = i.left + (1 - i.left - i.right) / 2, midY = i.top + (1 - i.top - i.bottom) / 2
        switch e {
        case .left: return frame.viewPoint(Vec2(i.left, midY))
        case .right: return frame.viewPoint(Vec2(1 - i.right, midY))
        case .top: return frame.viewPoint(Vec2(midX, i.top))
        case .bottom: return frame.viewPoint(Vec2(midX, 1 - i.bottom))
        }
    }

    /// The nearest edge handle within the grab radius.
    public func hit(_ p: CGPoint, _ i: CropInsets) -> CropEdge? {
        var best: (CropEdge, CGFloat)?
        for e in CropEdge.allCases {
            let c = handlePoint(e, i)
            let d: CGFloat = hypot(c.x - p.x, c.y - p.y)
            if d <= Self.grabRadius, d < (best?.1 ?? .infinity) { best = (e, d) }
        }
        return best?.0
    }

    /// New inset (fraction) of `edge` with the pointer at `p`: 0 ... what leaves `minRemaining` against the opposite edge.
    public func inset(_ edge: CropEdge, at p: CGPoint, current i: CropInsets) -> Double {
        guard let n = frame.framePoint(p) else { return edge.value(in: i) }
        let raw: Double, opposite: Double
        switch edge {
        case .left: raw = n.x; opposite = i.right
        case .right: raw = 1 - n.x; opposite = i.left
        case .top: raw = n.y; opposite = i.bottom
        case .bottom: raw = 1 - n.y; opposite = i.top
        }
        return min(max(raw, 0), max(0, 1 - opposite - Self.minRemaining))
    }
}
