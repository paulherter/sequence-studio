import AppKit

/// Zoom scrollbar at the bottom of the timeline (Premiere): round handles at both ends of the visible range. Drag a
/// handle to zoom, the body to pan, double-click to fit. All maths lives in `TimelineZoom`.
@MainActor
final class TimelineZoomBar: NSView {
    struct State {
        var scrollX: Double, viewport: Double, scale: Double, contentSeconds: Double
        var limits: ClosedRange<Double>
    }
    static let height: CGFloat = 16

    var state: () -> State = { State(scrollX: 0, viewport: 1, scale: 1, contentSeconds: 1, limits: 0.02...100) }
    var onApply: ((_ scale: Double, _ scrollX: Double) -> Void)?
    var onFit: (() -> Void)?

    private enum Drag { case lower, upper, pan(grab: Double) }
    private var drag: Drag?
    private var dragStart: State?
    private var dragExtent = 1.0

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var geo: KeyframeZoomBarGeometry { KeyframeZoomBarGeometry(width: bounds.width) }

    private func fractions(_ s: State) -> (lo: Double, hi: Double, extent: Double) {
        let e = TimelineZoom.barExtent(contentSeconds: s.contentSeconds, scrollX: s.scrollX, viewport: s.viewport, scale: s.scale)
        let h = TimelineZoom.handles(scrollX: s.scrollX, viewport: s.viewport, scale: s.scale, extent: e)
        return (h.lo, h.hi, e)
    }

    override func draw(_ dirtyRect: NSRect) {
        let g = geo
        let f = fractions(state())
        let xl = g.x(forFraction: f.lo), xh = g.x(forFraction: f.hi)
        let midY = bounds.midY
        let track = NSRect(x: KeyframeZoomBarGeometry.sideInset, y: midY - 3, width: bounds.width - 2 * KeyframeZoomBarGeometry.sideInset, height: 6)
        Theme.Colors.fill.setFill()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
        Theme.Colors.label3.setFill()
        NSBezierPath(roundedRect: NSRect(x: xl, y: midY - 3, width: max(xh - xl, 1), height: 6), xRadius: 3, yRadius: 3).fill()
        let r = KeyframeZoomBarGeometry.handleRadius - 2
        for x in [xl, xh] {
            Theme.Colors.label2.setFill()
            NSBezierPath(ovalIn: NSRect(x: x - r, y: midY - r, width: 2 * r, height: 2 * r)).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onFit?(); drag = nil; return }
        let s = state()
        let g = geo, f = fractions(s)
        let x = convert(event.locationInWindow, from: nil).x
        let xl = g.x(forFraction: f.lo), xh = g.x(forFraction: f.hi)
        let reach = KeyframeZoomBarGeometry.handleRadius + 2
        dragStart = s
        dragExtent = f.extent
        if abs(x - xl) <= reach || abs(x - xh) <= reach {
            drag = abs(x - xl) <= abs(x - xh) ? .lower : .upper
        } else if x > xl, x < xh {
            drag = .pan(grab: g.fraction(atX: x) - f.lo)
        } else {
            // Click on the empty track: centre the view there.
            let width = f.hi - f.lo
            drag = .pan(grab: width / 2)
            apply(pan: g.fraction(atX: x) - width / 2, s)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag, let s = dragStart else { return }
        let fr = geo.fraction(atX: convert(event.locationInWindow, from: nil).x)
        switch drag {
        case .lower, .upper:
            let isLower: Bool = { if case .lower = drag { true } else { false } }()
            let r = TimelineZoom.dragHandle(lower: isLower, fraction: fr, scrollX: s.scrollX, viewport: s.viewport, scale: s.scale,
                                            extent: dragExtent, range: s.limits)
            onApply?(r.scale, r.scrollX)
        case .pan(let grab):
            apply(pan: fr - grab, s)
        }
    }

    /// Moves the visible start to `startFraction` of the extent.
    private func apply(pan startFraction: Double, _ s: State) {
        onApply?(s.scale, max(startFraction, 0) * dragExtent * s.scale)
    }

    override func mouseUp(with event: NSEvent) { drag = nil; dragStart = nil }
}
