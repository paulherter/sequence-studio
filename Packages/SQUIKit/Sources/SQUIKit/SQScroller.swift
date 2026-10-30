import AppKit

/// Pure geometry of the thin knob (Parts/States boards: no track, 5 pt knob, white 20 %).
public enum SQScrollerMetrics {
    public static let thickness: CGFloat = 5
    public static let edgeInset: CGFloat = 2
    public static let minLength: CGFloat = 20

    /// The drawn knob inside the system's knob rect: thin, rounded, hugging the trailing edge.
    public static func knob(in system: NSRect, vertical: Bool, bounds: NSRect) -> NSRect {
        if vertical {
            let h = max(system.height, min(minLength, bounds.height))
            return NSRect(x: bounds.maxX - edgeInset - thickness, y: system.minY, width: thickness, height: h)
        }
        let w = max(system.width, min(minLength, bounds.width))
        return NSRect(x: system.minX, y: bounds.maxY - edgeInset - thickness, width: w, height: thickness)
    }

    /// Knob color alpha: rest, hover/drag.
    public static func knobAlpha(active: Bool, pressed: Bool = false) -> CGFloat { pressed ? 0.60 : active ? 0.38 : 0.20 }

    /// States board `.scb`: while hovered or dragged the bar widens to a 12 pt `field` track with a 6 pt knob 3 pt from the edge.
    public static let expandedWidth: CGFloat = 12
    public static let expandedKnob: CGFloat = 6
    public static let expandedInset: CGFloat = 3
}

/// Own scroll bar: overlay style, thin rounded knob, no track. The scroll view fades it when idle (overlay behavior).
open class SQScroller: NSScroller {
    var isPressed = false { didSet { if oldValue != isPressed { needsDisplay = true } } }
    var isActive = false { didSet { if oldValue != isActive { needsDisplay = true } } }
    private var area: NSTrackingArea?

    open override class var isCompatibleWithOverlayScrollers: Bool { true }
    open override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat {
        SQScrollerMetrics.expandedWidth
    }

    open override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}   // no track

    open override func drawKnob() {
        let vertical = bounds.height >= bounds.width
        var r = SQScrollerMetrics.knob(in: rect(for: .knob), vertical: vertical, bounds: bounds)
        var thickness = SQScrollerMetrics.thickness
        if isActive || isPressed {
            thickness = SQScrollerMetrics.expandedKnob
            if vertical { r = NSRect(x: bounds.maxX - SQScrollerMetrics.expandedInset - thickness, y: r.minY, width: thickness, height: r.height) }
            else { r = NSRect(x: r.minX, y: bounds.maxY - SQScrollerMetrics.expandedInset - thickness, width: r.width, height: thickness) }
        }
        let path = NSBezierPath(roundedRect: r, xRadius: thickness / 2, yRadius: thickness / 2)
        NSColor.white.withAlphaComponent(SQScrollerMetrics.knobAlpha(active: isActive, pressed: isPressed)).setFill()
        path.fill()
    }

    open override func draw(_ dirtyRect: NSRect) {
        NSBezierPath(rect: bounds).setClip()   // AppKit clips a scroller to its knob; the expanded track is outside it
        if isActive || isPressed {
            let vertical = bounds.height >= bounds.width
            let t = SQScrollerMetrics.expandedWidth
            let track = vertical ? NSRect(x: bounds.maxX - t, y: bounds.minY, width: t, height: bounds.height)
                                 : NSRect(x: bounds.minX, y: bounds.maxY - t, width: bounds.width, height: t)
            Theme.Colors.field.setFill()
            NSBezierPath(roundedRect: track, xRadius: t / 2, yRadius: t / 2).fill()
        }
        drawKnob()
    }

    open override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }
    open override func mouseEntered(with event: NSEvent) { isActive = true }
    open override func mouseExited(with event: NSEvent) { isActive = false }
    open override func mouseDown(with event: NSEvent) {
        isActive = true
        isPressed = true
        super.mouseDown(with: event)   // tracks the drag until mouse up
        isPressed = false
        isActive = false
    }
}

/// One-line adoption: `SQScrollView.apply(to: scrollView)`.
@MainActor
public enum SQScrollView {
    public static func apply(to scrollView: NSScrollView) {
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        if !(scrollView.verticalScroller is SQScroller) { scrollView.verticalScroller = SQScroller(frame: .zero) }
        if !(scrollView.horizontalScroller is SQScroller) { scrollView.horizontalScroller = SQScroller(frame: .zero) }
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
    }
}
