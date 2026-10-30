import AppKit
import SQCore

/// Top of the keyframe area (design v9 `.kruler`, `.kph`): the mini ruler in the "Property" column header row, with the
/// playhead line running through it into the lanes. Pressing or dragging anywhere moves the session playhead, stops playback and scrubs like the
/// timeline ruler; Shift snaps to keyframes.
public final class KeyframeRulerView: NSView {
    public let model: EffectControlsModel
    public static let rulerHeight: CGFloat = ControlsMetrics.header
    public static let height: CGFloat = rulerHeight
    private var dragging = false

    public init(model: EffectControlsModel) {
        self.model = model
        super.init(frame: .zero)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Keyframe ruler")
        wantsLayer = true
        addSubview(playheadLine)
        addSubview(playheadHead)
        hoverLine.isHidden = true
        addSubview(hoverLine)
    }

    // MARK: Hover (INTERACTION-AUDIT §7): a thin line in the tick band where a click puts the playhead.

    let hoverLine = PlayheadLineView(color: Theme.Colors.label3)   // never takes the press (hitTest nil)
    private var tracking: NSTrackingArea?

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }

    public override func mouseMoved(with event: NSEvent) { showHover(at: convert(event.locationInWindow, from: nil).x) }
    public override func mouseExited(with event: NSEvent) { hoverLine.isHidden = true }

    private func showHover(at x: CGFloat) {
        guard model.clip != nil, !dragging else { hoverLine.isHidden = true; return }
        hoverLine.isHidden = false
        hoverLine.frame = NSRect(x: x.rounded() - 0.5, y: 0, width: 1, height: Self.rulerHeight)
    }

    // MARK: Playhead layers and content refresh

    private let playheadLine = PlayheadLineView(color: Theme.Colors.playhead)
    private let playheadHead = PlayheadHeadView()
    private struct ContentKey: Equatable { var revision: Int; var viewport: KeyframeViewport; var size: CGSize; var frameDuration: Time }
    private var drawnKey: ContentKey?
    private(set) var invalidationCount = 0   // tests: content redraw requests

    /// Model change other than the playhead: redraws ticks and clip bar only when they would look different.
    func refreshContent() {
        let key = ContentKey(revision: model.clipRevision, viewport: model.viewport, size: bounds.size, frameDuration: model.frameDuration)
        if key != drawnKey { drawnKey = key; invalidationCount += 1; needsDisplay = true }
        movePlayhead()
    }

    /// Playhead tick: moves the two playhead layers, redraws nothing.
    func movePlayhead() {
        let show = model.clip != nil && model.playheadInClip
        playheadLine.isHidden = !show
        playheadHead.isHidden = !show
        guard show else { return }
        let x = geometry.x(for: model.localPlayhead)
        // The head hangs from the top of the ruler (the timeline ruler's shape), the line runs down from it.
        let c = x.rounded()
        playheadHead.frame.origin = NSPoint(x: c - PlayheadHeadView.size.width / 2, y: 0)
        playheadLine.frame = PlayheadLineView.frame(centerX: c, height: bounds.height)
    }

    public override func layout() { super.layout(); movePlayhead() }
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var geometry: KeyframeLaneGeometry { model.laneGeometry(width: bounds.width) }
    private var timecode: TimecodeFormat { TimecodeFormat(frameDuration: model.frameDuration) }

    private static let labelAttributes: [NSAttributedString.Key: Any] = [
        .font: Theme.Typography.caption, .foregroundColor: Theme.Colors.label3]

    static func shortLabel(_ timecode: String) -> String { KeyframeRulerLayout.shortLabel(timecode) }

    public override func draw(_ dirtyRect: NSRect) {
        Theme.Colors.lane.setFill(); bounds.fill()
        let rh = Self.rulerHeight
        if let clip = model.clip {
            let geo = geometry
            // v9 `.kruler span`: a caption label with an 8 pt tick at its left, at the bottom of the row; minor ticks 4 pt.
            let major = NSBezierPath(), minor = NSBezierPath()
            var labels: [(String, CGFloat)] = []
            let ticks = KeyframeRulerLayout.ticks(geometry: geo, frameDuration: model.frameDuration, nominalFPS: timecode.nominalFPS)
            for t in ticks {
                let x = geo.x(for: t.local).rounded() + 0.5
                if t.major {
                    major.move(to: NSPoint(x: x, y: rh - 8)); major.line(to: NSPoint(x: x, y: rh))
                    labels.append((Self.shortLabel(timecode.string(for: clip.start + t.local, frameDuration: model.frameDuration)), x))
                } else {
                    minor.move(to: NSPoint(x: x, y: rh - 4)); minor.line(to: NSPoint(x: x, y: rh))
                }
            }
            ControlsColors.rulerLine.setStroke(); major.stroke()
            ControlsColors.rulerMinor.setStroke(); minor.stroke()
            for (text, x) in labels { (text as NSString).draw(at: NSPoint(x: x + 4, y: 5), withAttributes: Self.labelAttributes) }
        }
        Theme.Colors.trackRowLine.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    // MARK: Mouse: press or drag anywhere moves the session playhead (stops playback, scrubs)

    private func target(_ event: NSEvent) -> Time? {
        guard model.clip != nil else { return nil }
        let geo = geometry
        let x = convert(event.locationInWindow, from: nil).x
        let local = geo.time(at: x, frameDuration: model.frameDuration)
        let snap = event.modifierFlags.contains(.shift)
        let threshold = Double(KeyframeSnap.thresholdPoints) / max(geo.pointsPerSecond, 1e-6)
        return model.scrubTarget(local: local, snap: snap, thresholdSeconds: threshold)
    }

    /// The ruler owns every press inside its bounds: no sub-layer (hover line, playhead head) can take it, and a press
    /// moves the playhead first, focus second (ending a value edit must not swallow or delay the grab).
    public override func hitTest(_ point: NSPoint) -> NSView? {
        let p = superview.map { convert(point, from: $0) } ?? point
        return bounds.contains(p) && !isHidden ? self : nil
    }
    public override var mouseDownCanMoveWindow: Bool { false }

    public override func mouseDown(with event: NSEvent) {
        if dragging { model.scrubUp(); dragging = false }     // a lost mouse-up must not leave the ruler stuck
        if let t = target(event) {
            dragging = true
            hoverLine.isHidden = true
            model.scrubDown(to: t)
        }
        window?.makeFirstResponder(superview)
    }
    public override func mouseDragged(with event: NSEvent) {
        guard dragging, let t = target(event) else { return }
        model.scrubDrag(to: t)
    }
    public override func mouseUp(with event: NSEvent) {
        if dragging { model.scrubUp() }
        dragging = false
    }

    // MARK: Zoom

    public override func magnify(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        model.zoom(by: KeyframeZoomInput.magnifyFactor(event.magnification), around: geometry.seconds(atX: x))
    }

    public override func scrollWheel(with event: NSEvent) {
        switch KeyframeZoomInput.scroll(event) {
        case .zoom(let f): model.zoom(by: f, around: geometry.seconds(atX: convert(event.locationInWindow, from: nil).x))
        case .pan(let pts): model.panViewport(bySeconds: -Double(pts) / max(geometry.pointsPerSecond, 1e-6))
        case .none: super.scrollWheel(with: event)
        }
    }
}
