import AppKit
import SQCore

/// The one zoom/scroll bar used under the Timeline and in Effect Controls: a track with a round handle at each end of the
/// visible range. Drag a handle to zoom, the body to scroll, click the empty track to center there, double-click to fit.
/// The bar only knows fractions (0...1) of the scrollable extent; the owner maps them to its own zoom state.
@MainActor
public final class ZoomScrollBar: NSView {
    /// Board row height (22), shared with the Mix row on its left.
    public static let height: CGFloat = ZoomScrollBarGesture.height

    /// Visible range as fractions of the extent. Read on every draw and mouse-down.
    public var handles: () -> (lo: Double, hi: Double) = { (0, 1) }
    /// False draws nothing and ignores the mouse (no content).
    public var isActive: () -> Bool = { true }
    /// Opaque fill under the bar (the timeline's bar sits over the content area, which reaches the bottom edge).
    public var backgroundColor: NSColor?
    /// Called on mouse-down on a handle, the body or the track (owner may snapshot its state).
    public var onBegin: (() -> Void)?
    /// A handle was dragged to `fraction`.
    public var onHandle: ((_ lower: Bool, _ fraction: Double) -> Void)?
    /// The visible range should start at `startFraction` (size unchanged).
    public var onPan: ((_ startFraction: Double) -> Void)?
    public var onFit: (() -> Void)?

    typealias Drag = ZoomScrollBarGesture.Drag
    private var gesture = ZoomScrollBarGesture()
    var drag: Drag? { gesture.drag }

    public init(accessibilityLabel: String) {
        super.init(frame: .zero)
        setAccessibilityRole(.scrollBar)
        setAccessibilityLabel(accessibilityLabel)
    }
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var geo: KeyframeZoomBarGeometry { KeyframeZoomBarGeometry(width: bounds.width) }

    // MARK: Hover and cursors

    /// Cursor over a part of the bar: end handles resize, the body is grabbable (closed while it is dragged), the empty track
    /// is a plain click target.
    static func cursor(for part: KeyframeZoomBarGeometry.Part, dragging: Bool) -> NSCursor {
        switch part {
        case .lower, .upper: .resizeLeftRight
        case .body: dragging ? .closedHand : .openHand
        case .track: .arrow
        }
    }

    private var hovered: KeyframeZoomBarGeometry.Part? { didSet { if hovered != oldValue { needsDisplay = true } } }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        removeOwnTrackingAreas()
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    private func updateHover(_ event: NSEvent) {
        guard isActive() else { hovered = nil; return }
        let part = geo.part(atX: convert(event.locationInWindow, from: nil).x, handles: handles())
        hovered = part
        Self.cursor(for: part, dragging: false).set()
    }

    public override func mouseEntered(with event: NSEvent) { updateHover(event) }
    public override func mouseMoved(with event: NSEvent) { updateHover(event) }
    public override func mouseExited(with event: NSEvent) { hovered = nil; NSCursor.arrow.set() }

    public override func draw(_ dirtyRect: NSRect) {
        if let backgroundColor { backgroundColor.setFill(); bounds.fill() }
        guard isActive() else { return }
        let g = geo
        let midY = bounds.midY
        let h = handles()
        let xl = g.x(forFraction: h.lo), xh = g.x(forFraction: h.hi)
        // Board `.zs`: 4 pt track, accent body, 10 pt light knobs.
        let track = NSRect(x: KeyframeZoomBarGeometry.sideInset, y: midY - 2,
                           width: bounds.width - 2 * KeyframeZoomBarGeometry.sideInset, height: 4)
        Theme.Colors.fill.setFill()
        NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2).fill()
        let body = NSRect(x: xl, y: midY - 2, width: max(xh - xl, 0), height: 4)
        let active = hovered == .body || gesture.isPanning
        (active ? Theme.white(0.30) : Theme.white(0.20)).setFill()   // neutral and unobtrusive (the maintainer: no big blue bar)
        NSBezierPath(roundedRect: body, xRadius: body.height / 2, yRadius: body.height / 2).fill()
        for (x, part) in [(xl, KeyframeZoomBarGeometry.Part.lower), (xh, .upper)] {
            let dot = NSBezierPath(ovalIn: NSRect(x: x - 4, y: midY - 4, width: 8, height: 8))
            (hovered == part ? Theme.white(0.85) : Theme.white(0.55)).setFill(); dot.fill()
        }
    }

    // MARK: Interaction (testable without events)

    func begin(atX x: CGFloat, clickCount: Int = 1) {
        guard isActive() else { return }
        for o in gesture.begin(atX: x, clickCount: clickCount, width: bounds.width, handles: handles()) { emit(o) }
    }

    func drag(toX x: CGFloat) {
        if let o = gesture.drag(toX: x, width: bounds.width) { emit(o) }
    }

    func end() { gesture.end(); needsDisplay = true }

    private func emit(_ o: ZoomScrollBarGesture.Output) {
        switch o {
        case .begin: onBegin?()
        case .handle(let lower, let f): onHandle?(lower, f)
        case .pan(let start): onPan?(start)
        case .fit: onFit?()
        }
    }

    public override func mouseDown(with event: NSEvent) { begin(atX: convert(event.locationInWindow, from: nil).x, clickCount: event.clickCount) }
    public override func mouseDragged(with event: NSEvent) {
        drag(toX: convert(event.locationInWindow, from: nil).x)
        if case .pan = drag { NSCursor.closedHand.set() }
    }
    public override func mouseUp(with event: NSEvent) { end() }
}
