import AppKit
import SQCore

/// The scrub strip under the Source picture (board: 18 high): thin track, In/Out range drawn like the timeline band
/// (accent tint, 2 pt accent edges), playhead = white line with the timeline's 11 x 9 head.
/// Click scrubs, dragging the playhead scrubs; drag an edge moves that mark, drag inside the range moves the whole range,
/// drag on empty track marks a new range. The model keeps the preview, the host gets `onMarkEdit` once on mouse-up.
@MainActor
public final class MonitorScrubBar: NSView {
    public static let height: CGFloat = Theme.Metrics.scrubBar
    private let model: MonitorPanelModel
    private enum Drag {
        case scrub
        case grip(MonitorScrubMath.Hit)
        case moveRange(startX: CGFloat, markIn: Time, markOut: Time)
        case pending(startX: CGFloat)
        case newRange(anchor: Time)
    }
    private var drag: Drag?
    private var tracking: NSTrackingArea?

    public init(model: MonitorPanelModel) {
        self.model = model
        super.init(frame: .zero)
        setAccessibilityLabel("Scrub bar")
        setAccessibilityRole(.slider)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }
    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    public override func mouseMoved(with event: NSEvent) {
        switch target(atX: convert(event.locationInWindow, from: nil).x) {
        case .grip: NSCursor.resizeLeftRight.set()
        case .moveRange: NSCursor.openHand.set()
        default: NSCursor.arrow.set()
        }
    }
    public override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    private var math: MonitorScrubMath {
        MonitorScrubMath(duration: model.duration, frameDuration: model.frameDuration, width: bounds.width)
    }

    /// What a press at `x` picks up. Order: an edge, the playhead, the inside of the range, else empty track.
    private func target(atX x: CGFloat) -> Drag {
        let m = math
        if model.marksEditable {
            let grip = m.hit(x: x, markIn: model.markIn, markOut: model.markOut)
            if grip != .playhead { return .grip(grip) }
        }
        if abs(m.x(for: model.currentTime) - x) <= MonitorScrubMath.hitSlop { return .scrub }
        if model.marksEditable, model.hasRange {
            let i = model.markIn ?? .zero, o = model.markOut ?? model.duration
            if x > m.x(for: i), x < m.x(for: o) { return .moveRange(startX: x, markIn: i, markOut: o) }
        }
        return .pending(startX: x)
    }

    public override func draw(_ dirtyRect: NSRect) {
        let m = math
        // v9 `.mscr`: 2 pt bar at y 7, In to Out as a 6 pt tinted band at y 5, playhead 2 x 14 at y 1.
        let track = NSRect(x: m.inset, y: 7, width: max(bounds.width - 2 * m.inset, 0), height: 2)
        Theme.Colors.fillPressed.setFill()
        NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2).fill()
        if model.hasRange {
            let a = m.x(for: model.markIn ?? .zero), b = m.x(for: model.markOut ?? model.duration)
            if b > a {
                let band = NSRect(x: a, y: 5, width: b - a, height: 6)
                Theme.Colors.accentTint.setFill()
                NSBezierPath(roundedRect: band, xRadius: band.height / 2, yRadius: band.height / 2).fill()
            }
        }
        // Edge handles: a mark that is set gets a 3 x 12 pt accent grip, so In and Out can be told apart and grabbed.
        Theme.Colors.inOutEdge.setFill()
        for (mark, isIn) in [(model.markIn, true), (model.markOut, false)] {
            guard let mark else { continue }
            let hx = m.x(for: mark)
            let w = Self.gripWidth
            let grip = NSRect(x: isIn ? hx : hx - w, y: 2, width: w, height: 12)
            NSBezierPath(roundedRect: grip, xRadius: grip.width / 2, yRadius: grip.width / 2).fill()
        }
        // Markers (Source monitor): a small mark above the track.
        Theme.Colors.yellow.setFill()
        for t in model.markerTimes {
            let mx = m.x(for: t)
            let tri = NSBezierPath()
            tri.move(to: NSPoint(x: mx - 3, y: 0)); tri.line(to: NSPoint(x: mx + 3, y: 0)); tri.line(to: NSPoint(x: mx, y: 5)); tri.close()
            tri.fill()
        }
        let x = m.x(for: model.currentTime)
        Theme.Colors.playhead.setFill()
        let head = NSRect(x: x - 1, y: 1, width: 2, height: 14)
        NSBezierPath(roundedRect: head, xRadius: head.width / 2, yRadius: head.width / 2).fill()
    }

    private func time(_ event: NSEvent) -> Time { math.time(atX: convert(event.locationInWindow, from: nil).x) }

    private func scrub(to event: NSEvent) {
        let t = time(event)
        if let s = model.onScrub { s(t) } else { model.onSeek?(t) }
    }

    static let gripWidth: CGFloat = 3

    /// Right-click on the strip or on the range: Remove In / Out / In and Out, Go to In / Out.
    public override func rightMouseDown(with event: NSEvent) {
        guard model.duration > .zero else { return }
        SQContextMenu.popUp(items: model.markMenu(), at: convert(event.locationInWindow, from: nil), in: self)
    }

    public override func mouseDown(with event: NSEvent) {
        guard model.duration > .zero else { return }
        let d = target(atX: convert(event.locationInWindow, from: nil).x)
        drag = d
        switch d {
        case .grip(let h): model.previewMark(h, frame: time(event)); needsDisplay = true
        case .scrub: model.onScrubBegan?(); scrub(to: event)
        default: break
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let d = drag else { return }
        let x = convert(event.locationInWindow, from: nil).x
        let m = math
        switch d {
        case .scrub: scrub(to: event)
        case .grip(let h): model.previewMark(h, frame: m.time(atX: x)); needsDisplay = true
        case .moveRange(let startX, let i, let o):
            let r = m.movedRange(markIn: i, markOut: o, by: m.time(atX: x) - m.time(atX: startX))
            model.previewRange(markIn: r.markIn, markOut: r.markOut)
            needsDisplay = true
        case .pending(let startX):
            guard abs(x - startX) > 3 else { return }
            if model.sourceFileView {                     // marks are locked: dragging the empty track scrubs
                drag = .scrub; model.onScrubBegan?(); scrub(to: event); return
            }
            drag = .newRange(anchor: m.time(atX: startX))
            mouseDragged(with: event)
        case .newRange(let anchor):
            let r = MonitorScrubMath.range(anchor, m.time(atX: x), frameDuration: model.frameDuration)
            model.previewRange(markIn: r.markIn, markOut: r.markOut)
            needsDisplay = true
        }
    }

    public override func mouseUp(with event: NSEvent) {
        defer { drag = nil }
        switch drag {
        case .grip(let h): model.commitMark(h)
        case .moveRange: model.commitRange(.body)
        case .newRange: model.commitRange(.newRange)
        case .scrub: model.onScrubEnded?()
        case .pending:                                    // a click on empty track: seek there
            model.onScrubBegan?(); scrub(to: event); model.onScrubEnded?()
        case nil: break
        }
    }
}
