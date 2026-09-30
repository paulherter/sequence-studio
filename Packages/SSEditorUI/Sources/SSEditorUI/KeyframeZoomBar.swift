import AppKit
import SSCore

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
        let h = viewport.handles(duration: duration)
        let xl = self.x(forFraction: h.lo), xh = self.x(forFraction: h.hi)
        let reach = Self.handleRadius + 2
        let dl = abs(x - xl), dh = abs(x - xh)
        if dl <= reach || dh <= reach { return dl <= dh ? .lower : .upper }
        return x > xl && x < xh ? .body : .track
    }
}

/// Zoom scrollbar at the bottom of the keyframe area: a track with a round handle at each end of the visible range
/// (Premiere). Drag a handle to zoom, the body to scroll, double-click to show the whole clip.
public final class KeyframeZoomBar: NSView {
    public let model: EffectControlsModel
    public static let height: CGFloat = 24

    private enum Drag { case lower, upper, pan(grabFraction: Double) }
    private var drag: Drag?

    public init(model: EffectControlsModel) {
        self.model = model
        super.init(frame: .zero)
        setAccessibilityRole(.scrollBar)
        setAccessibilityLabel("Keyframe zoom")
    }
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var geo: KeyframeZoomBarGeometry { KeyframeZoomBarGeometry(width: bounds.width) }
    private var durationSeconds: Double { model.durationSeconds }

    public override func draw(_ dirtyRect: NSRect) {
        guard model.clip != nil else { return }
        let g = geo
        let midY = bounds.midY
        let h = model.viewport.handles(duration: durationSeconds)
        let xl = g.x(forFraction: h.lo), xh = g.x(forFraction: h.hi)
        let track = NSRect(x: KeyframeZoomBarGeometry.sideInset, y: midY - 5,
                           width: bounds.width - 2 * KeyframeZoomBarGeometry.sideInset, height: 10)
        Theme.Colors.fill2.setFill()
        NSBezierPath(roundedRect: track, xRadius: 5, yRadius: 5).fill()
        let body = NSRect(x: xl, y: midY - 5, width: max(xh - xl, 0), height: 10)
        Theme.Colors.fillHover.setFill(); body.fill()
        for x in [xl, xh] {
            let r = KeyframeZoomBarGeometry.handleRadius - 1
            let dot = NSBezierPath(ovalIn: NSRect(x: x - r, y: midY - r, width: 2 * r, height: 2 * r))
            Theme.Colors.panel.setFill(); dot.fill()
            Theme.Colors.label.setStroke(); dot.lineWidth = 2; dot.stroke()
        }
    }

    // MARK: Mouse

    public override func mouseDown(with event: NSEvent) {
        guard model.clip != nil, durationSeconds > 0 else { return }
        let x = convert(event.locationInWindow, from: nil).x
        if event.clickCount == 2 { model.zoomToFit(); drag = nil; return }
        let v = model.viewport
        switch geo.part(atX: x, viewport: v, duration: durationSeconds) {
        case .lower: drag = .lower
        case .upper: drag = .upper
        case .body:
            drag = .pan(grabFraction: geo.fraction(atX: x) - v.handles(duration: durationSeconds).lo)
        case .track:
            // Click on the empty track: centre the window there, then keep dragging it.
            let f = geo.fraction(atX: x)
            model.setViewport(v.centered(onFraction: f, duration: durationSeconds, minSpan: model.minViewportSpan))
            drag = .pan(grabFraction: f - model.viewport.handles(duration: durationSeconds).lo)
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let drag, durationSeconds > 0 else { return }
        let f = geo.fraction(atX: convert(event.locationInWindow, from: nil).x)
        let v = model.viewport, d = durationSeconds, m = model.minViewportSpan
        switch drag {
        case .lower: model.setViewport(v.settingLowerHandle(f, duration: d, minSpan: m))
        case .upper: model.setViewport(v.settingUpperHandle(f, duration: d, minSpan: m))
        case .pan(let grab):
            let lo = f - grab
            model.setViewport(KeyframeViewport(start: lo * d, span: v.span).clamped(duration: d, minSpan: m))
        }
    }

    public override func mouseUp(with event: NSEvent) { drag = nil }
}

/// Thin vertical divider between the properties and the keyframe area. Drag to resize; the owner clamps and persists.
final class EffectControlsDivider: NSView {
    /// Called with the total horizontal movement since the press.
    var onDrag: ((CGFloat) -> Void)?
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?
    private var originX: CGFloat = 0

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

    override func draw(_ dirtyRect: NSRect) {
        Theme.Colors.divider.setFill()
        NSRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height).fill()
    }

    override func mouseDown(with event: NSEvent) { originX = event.locationInWindow.x; onBegin?() }
    override func mouseDragged(with event: NSEvent) { onDrag?(event.locationInWindow.x - originX) }
    override func mouseUp(with event: NSEvent) { onEnd?() }
}
