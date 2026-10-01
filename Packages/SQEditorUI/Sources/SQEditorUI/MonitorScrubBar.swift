import AppKit
import SQCore

/// Maths of the strip under a monitor's picture: x position <-> time over the whole duration.
public struct MonitorScrubMath: Sendable, Equatable {
    public var duration: Time
    public var frameDuration: Time
    public var width: CGFloat
    /// Space on both sides so the playhead handle at either end stays inside the view.
    public var inset: CGFloat = 8

    public init(duration: Time, frameDuration: Time, width: CGFloat, inset: CGFloat = 8) {
        self.duration = duration; self.frameDuration = frameDuration; self.width = width; self.inset = inset
    }

    private var span: CGFloat { max(width - 2 * inset, 1) }

    /// Frame-snapped time under `x`, clamped to the first and last frame.
    public func time(atX x: CGFloat) -> Time {
        guard duration > .zero else { return .zero }
        let f = Double(min(max((x - inset) / span, 0), 1))
        let scale: Int64 = 100_000
        let raw = Time(Int64((f * Double(scale)).rounded()) * duration.value, scale * duration.timescale)
        return min(raw.snapped(to: frameDuration), max(.zero, duration - frameDuration))
    }

    /// What a mouse-down at `x` grabs: the In or Out grip (when marks are given and within `slop` points), else the playhead
    /// (scrubbing). The nearest grip wins; a tie goes to the grip so a mark just set at the playhead can still be dragged.
    public enum Hit: Sendable, Equatable { case markIn, markOut, playhead }
    public static let hitSlop: CGFloat = 6

    public func hit(x: CGFloat, markIn: Time?, markOut: Time?, slop: CGFloat = MonitorScrubMath.hitSlop) -> Hit {
        var best: (Hit, CGFloat)?
        for (hit, mark) in [(Hit.markIn, markIn), (Hit.markOut, markOut)] {
            guard let m = mark else { continue }
            let d = abs(self.x(for: m) - x)
            if d <= slop, best == nil || d < best!.1 { best = (hit, d) }
        }
        return best?.0 ?? .playhead
    }

    public func x(for t: Time) -> CGFloat {
        guard duration > .zero else { return inset }
        let f = Double(t.value) / Double(t.timescale) / (Double(duration.value) / Double(duration.timescale))
        return inset + span * CGFloat(min(max(f, 0), 1))
    }
}

/// The scrub strip under the picture of both monitors: whole-clip (or sequence) length, In/Out range, playhead.
/// Click or drag to scrub; drag the In or Out grip to move that mark (the model keeps the drag preview, the host gets
/// `onMarkEdit` once on mouse-up, so a gesture is one undo step). State comes from `MonitorPanelModel`.
@MainActor
public final class MonitorScrubBar: NSView {
    private let model: MonitorPanelModel
    private var scrubbing = false
    private var dragging: MonitorScrubMath.Hit?
    private var tracking: NSTrackingArea?

    public init(model: MonitorPanelModel) {
        self.model = model
        super.init(frame: .zero)
        setAccessibilityLabel("Scrub bar")
        setAccessibilityRole(.slider)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }
    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 14) }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    public override func mouseMoved(with event: NSEvent) {
        let h = grip(at: event)
        (h == .playhead ? NSCursor.arrow : NSCursor.resizeLeftRight).set()
    }
    public override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    private var math: MonitorScrubMath {
        MonitorScrubMath(duration: model.duration, frameDuration: model.frameDuration, width: bounds.width)
    }

    private func grip(at event: NSEvent) -> MonitorScrubMath.Hit {
        guard model.duration > .zero else { return .playhead }
        return math.hit(x: convert(event.locationInWindow, from: nil).x, markIn: model.markIn, markOut: model.markOut)
    }

    public override func draw(_ dirtyRect: NSRect) {
        let m = math
        let track = NSRect(x: m.inset, y: bounds.midY - 1.5, width: bounds.width - 2 * m.inset, height: 3)
        Theme.Colors.fill.setFill()
        NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()
        if model.markIn != nil || model.markOut != nil {
            let a = m.x(for: model.markIn ?? .zero), b = m.x(for: model.markOut ?? model.duration)
            if b > a {
                Theme.Colors.accent.withAlphaComponent(0.7).setFill()
                NSBezierPath(roundedRect: NSRect(x: a, y: bounds.midY - 3, width: b - a, height: 6), xRadius: 1.5, yRadius: 1.5).fill()
            }
            // Grips: a short bar at each set mark (these are what the mouse picks up).
            Theme.Colors.accent.setFill()
            if let i = model.markIn { NSRect(x: m.x(for: i) - 1, y: bounds.midY - 5, width: 2, height: 10).fill() }
            if let o = model.markOut { NSRect(x: m.x(for: o) - 1, y: bounds.midY - 5, width: 2, height: 10).fill() }
        }
        let x = m.x(for: model.currentTime)
        Theme.Colors.label.setFill()
        NSRect(x: x - 0.75, y: 2, width: 1.5, height: bounds.height - 4).fill()
        NSBezierPath(ovalIn: NSRect(x: x - 4, y: 0, width: 8, height: 8)).fill()
    }

    private func scrub(to event: NSEvent) {
        let t = math.time(atX: convert(event.locationInWindow, from: nil).x)
        if let s = model.onScrub { s(t) } else { model.onSeek?(t) }
    }

    /// Moves the dragged grip in the model (preview). In past Out drops Out; Out before In drops In (as Mark In / Mark Out).
    private func dragGrip(_ end: MonitorScrubMath.Hit, to event: NSEvent) {
        let t = math.time(atX: convert(event.locationInWindow, from: nil).x)
        model.previewMark(end, frame: t)
        needsDisplay = true
    }

    public override func mouseDown(with event: NSEvent) {
        guard model.duration > .zero else { return }
        let h = grip(at: event)
        if h != .playhead, model.onMarkEdit != nil {
            dragging = h
            dragGrip(h, to: event)
            return
        }
        scrubbing = true
        model.onScrubBegan?()
        scrub(to: event)
    }
    public override func mouseDragged(with event: NSEvent) {
        if let d = dragging { dragGrip(d, to: event) } else if scrubbing { scrub(to: event) }
    }
    public override func mouseUp(with event: NSEvent) {
        if let d = dragging {
            dragging = nil
            model.commitMark(d)
            return
        }
        guard scrubbing else { return }
        scrubbing = false
        model.onScrubEnded?()
    }
}
