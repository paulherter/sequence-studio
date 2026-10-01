import CoreGraphics
import Foundation
import SSCore
import SSRender

/// Where the sequence canvas sits inside the Program monitor view, for a `ViewerZoom` (pure; mirrors
/// `Presenter.destinationRect`, which works in drawable pixels). Also the pan/zoom reducers of the monitor *view*
/// (Hand tool, trackpad scroll and pinch): they change the zoom value only, never the picture's transform.
public struct MonitorViewMapping: Sendable, Equatable {
    public static let minScale: Double = 0.05
    public static let maxScale: Double = 16

    /// View size in points (the overlay / viewer slot).
    public var viewSize: CGSize
    public var backingScale: CGFloat
    /// Sequence size in px (= the composite texture size).
    public var sequenceSize: CGSize
    public var zoom: ViewerZoom

    public init(viewSize: CGSize, backingScale: CGFloat, sequenceSize: CGSize, zoom: ViewerZoom) {
        self.viewSize = viewSize; self.backingScale = max(backingScale, 0.5)
        self.sequenceSize = sequenceSize; self.zoom = zoom
    }

    public var drawableSize: CGSize { CGSize(width: viewSize.width * backingScale, height: viewSize.height * backingScale) }

    /// Drawable px per sequence px when the picture is aspect-fitted.
    public var fitScale: CGFloat {
        guard sequenceSize.width > 0, sequenceSize.height > 0 else { return 1 }
        return min(drawableSize.width / sequenceSize.width, drawableSize.height / sequenceSize.height)
    }

    /// Effective drawable px per sequence px.
    public var scale: CGFloat {
        switch zoom {
        case .fit: fitScale
        case .percent(let p): CGFloat(max(p, 1)) / 100
        case .view(let s, _, _): CGFloat(s)
        }
    }

    /// Sequence offset (from the canvas centre) shown at the view centre.
    public var center: CGPoint {
        if case .view(_, let x, let y) = zoom { return CGPoint(x: x, y: y) }
        return .zero
    }

    public var isFit: Bool { if case .fit = zoom { true } else { false } }

    /// The canvas in view points, origin top-left.
    public var canvasRect: CGRect {
        let r = Presenter.destinationRect(textureSize: sequenceSize, drawableSize: drawableSize, zoom: zoom)
        return CGRect(x: r.minX / backingScale, y: r.minY / backingScale,
                      width: r.width / backingScale, height: r.height / backingScale)
    }

    /// View point to sequence px relative to the canvas centre.
    public func sequenceOffset(fromView p: CGPoint) -> Vec2 {
        let r = canvasRect
        let k = Double(scale / backingScale)
        guard k > 0 else { return .zero }
        return Vec2(Double(p.x - r.midX) / k, Double(p.y - r.midY) / k)
    }

    /// The picture follows the pointer: dragging right by `d.width` points moves the picture right.
    public func panned(byViewDelta d: CGSize) -> ViewerZoom {
        let s = Double(scale)
        guard s > 0, s.isFinite, viewSize.width > 0, viewSize.height > 0 else { return zoom }
        let c = center
        return clamped(scale: s, centerX: Double(c.x) - Double(d.width * backingScale) / s,
                       centerY: Double(c.y) - Double(d.height * backingScale) / s)
    }

    /// Zooms by `factor`, keeping the sequence point under `p` (view points) where it is. Returns `.fit` when the result
    /// is (nearly) the fitted picture again.
    public func zoomed(by factor: CGFloat, about p: CGPoint) -> ViewerZoom {
        guard factor > 0, factor.isFinite else { return zoom }
        let s0 = Double(scale)
        guard s0 > 0, s0.isFinite, viewSize.width > 0, viewSize.height > 0 else { return zoom }
        let s1 = min(max(s0 * Double(factor), Self.minScale), Self.maxScale)
        let c = center
        // Drawable-pixel offset of the anchor from the view centre.
        let dx = Double((p.x - viewSize.width / 2) * backingScale), dy = Double((p.y - viewSize.height / 2) * backingScale)
        let nx = Double(c.x) + dx / s0 - dx / s1, ny = Double(c.y) + dy / s0 - dy / s1
        let z = clamped(scale: s1, centerX: nx, centerY: ny)
        if case .view(let s, let x, let y) = z, abs(s / Double(fitScale) - 1) < 0.02, abs(x) < 1, abs(y) < 1 { return .fit }
        return z
    }

    /// Keeps at least the canvas centre inside the view.
    private func clamped(scale s: Double, centerX: Double, centerY: Double) -> ViewerZoom {
        let mx = Double(sequenceSize.width) / 2, my = Double(sequenceSize.height) / 2
        return .view(scale: s, centerX: min(max(centerX, -mx), mx), centerY: min(max(centerY, -my), my))
    }
}

public extension ViewerZoom {
    var isFit: Bool { if case .fit = self { true } else { false } }
}

/// Type tool: where a click in the Program monitor puts the new text's centre.
public enum TypeToolPlacement {
    /// Position (sequence px from the canvas centre) for a click at `p`; nil when the click is outside the canvas.
    /// The text's centre is clamped so it always lands on the canvas.
    public static func position(forClick p: CGPoint, mapping m: MonitorViewMapping) -> Vec2? {
        let r = m.canvasRect
        // A click far outside the view still clamps; a click in the letterbox of a zoomed-out view is no text box.
        let inView = CGRect(origin: .zero, size: m.viewSize).contains(p)
        if inView && !r.contains(p) { return nil }
        let o = m.sequenceOffset(fromView: p)
        let hw = Double(m.sequenceSize.width) / 2, hh = Double(m.sequenceSize.height) / 2
        return Vec2(min(max(o.x, -hw), hw), min(max(o.y, -hh), hh))
    }
}
