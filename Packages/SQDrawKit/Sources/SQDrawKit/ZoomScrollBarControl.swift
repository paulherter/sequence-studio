import Foundation
import SQUIKit

/// The zoom/scroll bar under the Timeline and in Effect Controls (`ZoomScrollBar`) on the canvas: the same
/// `ZoomScrollBarGesture` rules and `KeyframeZoomBarGeometry` mapping, the board `.zs` look (4 pt track, neutral body,
/// 8 pt light knobs). Coordinates are the owner's points; `bounds` is the bar's rect.
public struct ZoomScrollBarControl: Sendable, Equatable {
    public static let height = ZoomScrollBarGesture.height
    public private(set) var gesture = ZoomScrollBarGesture()
    public var hovered: KeyframeZoomBarGeometry.Part?

    public init() {}

    public var isDragging: Bool { gesture.drag != nil }

    /// A press at `p` inside `bounds`.
    public mutating func mouseDown(_ p: CGPoint, clickCount: Int, in bounds: CGRect, handles: (lo: Double, hi: Double)) -> [ZoomScrollBarGesture.Output] {
        gesture.begin(atX: p.x - bounds.minX, clickCount: clickCount, width: bounds.width, handles: handles)
    }

    public func mouseDragged(_ p: CGPoint, in bounds: CGRect) -> ZoomScrollBarGesture.Output? {
        gesture.drag(toX: p.x - bounds.minX, width: bounds.width)
    }

    public mutating func mouseUp() { gesture.end() }

    /// Hover over the bar (nil = outside).
    public mutating func hover(_ p: CGPoint?, in bounds: CGRect, handles: (lo: Double, hi: Double)) {
        guard let p, bounds.contains(p) else { hovered = nil; return }
        hovered = KeyframeZoomBarGeometry(width: bounds.width).part(atX: p.x - bounds.minX, handles: handles)
    }

    public func draw(_ c: inout Canvas, in bounds: CGRect, handles h: (lo: Double, hi: Double), theme t: DrawTheme,
                     background: DrawColor? = nil) {
        if let background { c.fill(bounds, background) }
        let g = KeyframeZoomBarGeometry(width: bounds.width)
        let midY = bounds.midY
        let xl = bounds.minX + g.x(forFraction: h.lo), xh = bounds.minX + g.x(forFraction: h.hi)
        let inset = KeyframeZoomBarGeometry.sideInset
        let track = CGRect(x: bounds.minX + inset, y: midY - 2, width: bounds.width - 2 * inset, height: 4)
        c.fill(roundedRect: track, radius: 2, t.fill)
        let body = CGRect(x: xl, y: midY - 2, width: max(xh - xl, 0), height: 4)
        let active = hovered == .body || gesture.isPanning
        c.fill(roundedRect: body, radius: 2, DrawColor.white.alpha(active ? 0.30 : 0.20))   // neutral (the maintainer: no big blue bar)
        for (x, part) in [(xl, KeyframeZoomBarGeometry.Part.lower), (xh, .upper)] {
            c.fill(ellipseIn: CGRect(x: x - 4, y: midY - 4, width: 8, height: 8), DrawColor.white.alpha(hovered == part ? 0.85 : 0.55))
        }
    }
}
