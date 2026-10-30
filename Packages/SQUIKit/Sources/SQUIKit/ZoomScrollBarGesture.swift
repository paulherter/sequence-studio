import Foundation
import SQCore

/// Pure mapping of the zoom bar: handle fractions <-> x (the round handles stay fully inside the track).
public struct KeyframeZoomBarGeometry: Sendable, Equatable {
    public static let handleRadius: CGFloat = 7
    public static let sideInset: CGFloat = 4
    public var width: CGFloat

    public init(width: CGFloat) { self.width = width }

    var x0: CGFloat { Self.sideInset + Self.handleRadius }
    var x1: CGFloat { max(width - Self.sideInset - Self.handleRadius, x0 + 1) }

    public func x(forFraction f: Double) -> CGFloat { x0 + CGFloat(min(max(f, 0), 1)) * (x1 - x0) }
    public func fraction(atX x: CGFloat) -> Double { min(max(Double((x - x0) / (x1 - x0)), 0), 1) }

    public enum Part: Equatable, Sendable { case lower, upper, body, track }

    /// What is under `x`: a handle (they win over the body), the body between them, or the empty track.
    public func part(atX x: CGFloat, viewport: KeyframeViewport, duration: Double) -> Part {
        part(atX: x, handles: viewport.handles(duration: duration))
    }

    /// Same, for handle fractions (0...1) given directly.
    public func part(atX x: CGFloat, handles h: (lo: Double, hi: Double)) -> Part {
        let xl = self.x(forFraction: h.lo), xh = self.x(forFraction: h.hi)
        let reach = Self.handleRadius + 2
        let dl = abs(x - xl), dh = abs(x - xh)
        if dl <= reach || dh <= reach { return dl <= dh ? .lower : .upper }
        return x > xl && x < xh ? .body : .track
    }
}
/// The zoom/scroll bar's press and drag rules (`ZoomScrollBar`), portable so the AppKit view and the canvas control
/// (SQDrawKit `ZoomScrollBarControl`) share them: a handle press zooms, the body pans, a click on the empty track centers
/// the visible range there, a double-click fits.
public struct ZoomScrollBarGesture: Sendable, Equatable {
    /// Board row height (22), shared with the Mix row on its left.
    public static let height: CGFloat = 18

    public enum Drag: Equatable, Sendable { case lower, upper, pan(grab: Double) }
    /// What the owner does: snapshot its state (`begin`), move a handle, pan to a start fraction, or fit.
    public enum Output: Equatable, Sendable { case begin, handle(lower: Bool, fraction: Double), pan(startFraction: Double), fit }

    public private(set) var drag: Drag?
    public init() {}

    public var isPanning: Bool { if case .pan = drag { true } else { false } }

    /// A press at `x` on a bar `width` wide showing `h`.
    public mutating func begin(atX x: CGFloat, clickCount: Int = 1, width: CGFloat, handles h: (lo: Double, hi: Double)) -> [Output] {
        if clickCount == 2 { drag = nil; return [.fit] }
        let g = KeyframeZoomBarGeometry(width: width)
        switch g.part(atX: x, handles: h) {
        case .lower: drag = .lower
        case .upper: drag = .upper
        case .body: drag = .pan(grab: g.fraction(atX: x) - h.lo)
        case .track:
            let half = (h.hi - h.lo) / 2
            drag = .pan(grab: half)
            return [.begin, .pan(startFraction: g.fraction(atX: x) - half)]
        }
        return [.begin]
    }

    public func drag(toX x: CGFloat, width: CGFloat) -> Output? {
        guard let drag else { return nil }
        let f = KeyframeZoomBarGeometry(width: width).fraction(atX: x)
        switch drag {
        case .lower: return .handle(lower: true, fraction: f)
        case .upper: return .handle(lower: false, fraction: f)
        case .pan(let grab): return .pan(startFraction: f - grab)
        }
    }

    public mutating func end() { drag = nil }
}
