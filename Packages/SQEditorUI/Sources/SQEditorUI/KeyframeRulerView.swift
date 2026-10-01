import AppKit
import SQCore

/// Pure tick layout of the Effect Controls ruler (same x mapping as the keyframe lanes, zoom included).
public enum KeyframeRulerLayout {
    public struct Tick: Equatable, Sendable {
        /// Clip-local time.
        public var local: Time
        public var major: Bool
    }

    /// Ticks over the whole clip range 0...duration for the given lane width.
    public static func ticks(width: CGFloat, duration: Time, frameDuration: Time, nominalFPS: Int) -> [Tick] {
        ticks(geometry: KeyframeLaneGeometry(width: width, duration: duration), frameDuration: frameDuration, nominalFPS: nominalFPS)
    }

    /// Ticks inside the visible window only (a long clip zoomed to a few frames must not produce a tick per frame of the clip).
    public static func ticks(geometry geo: KeyframeLaneGeometry, frameDuration: Time, nominalFPS: Int) -> [Tick] {
        let frames = geo.duration.frameIndex(frameDuration: frameDuration)
        guard frames > 0 else { return [] }
        let fdSecs = Double(frameDuration.value) / Double(frameDuration.timescale)
        let ppf = geo.pointsPerSecond * fdSecs
        guard ppf > 0 else { return [] }
        let scale = RulerScale.scale(pointsPerFrame: ppf, nominalFPS: nominalFPS)
        let minor = Int64(max(scale.minorFrames, 1)), major = Int64(max(scale.majorFrames, 1))
        // Visible frames, with one tick of slack on each side (the lane inset is 10 pt).
        let first = max(Int64(((geo.viewStart - 12 / max(geo.pointsPerSecond, 1e-9)) / fdSecs).rounded(.down)), 0)
        let last = min(Int64(((geo.viewStart + geo.viewSpan + 12 / max(geo.pointsPerSecond, 1e-9)) / fdSecs).rounded(.up)), frames)
        guard first <= last else { return [] }
        var out: [Tick] = []
        var f = (first / minor) * minor
        while f <= last {
            out.append(Tick(local: frameDuration * f, major: f % major == 0))
            f += minor
        }
        return out
    }

    /// Timeline time for a pointer x in the ruler, frame-snapped and clamped to the clip.
    public static func seekTime(atX x: CGFloat, width: CGFloat, clipStart: Time, duration: Time, frameDuration: Time) -> Time {
        clipStart + KeyframeLaneGeometry(width: width, duration: duration).time(at: x, frameDuration: frameDuration)
    }
}

/// Top of the keyframe area (Premiere): timecode ruler, the clip bar below it, and the playhead head. Pressing or dragging
/// anywhere moves the session playhead, stops playback and scrubs like the timeline ruler; Shift snaps to keyframes.
public final class KeyframeRulerView: NSView {
    public let model: EffectControlsModel
    public static let rulerHeight: CGFloat = 24
    public static let clipBarHeight: CGFloat = 16
    public static let height: CGFloat = rulerHeight + clipBarHeight
    private var dragging = false

    public init(model: EffectControlsModel) {
        self.model = model
        super.init(frame: .zero)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Keyframe ruler")
    }
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var geometry: KeyframeLaneGeometry { model.laneGeometry(width: bounds.width) }
    private var timecode: TimecodeFormat { TimecodeFormat(frameDuration: model.frameDuration) }

    private static let labelAttributes: [NSAttributedString.Key: Any] = [
        .font: Theme.Fonts.mini, .foregroundColor: Theme.Colors.label2]
    private static let clipNameAttributes: [NSAttributedString.Key: Any] = [
        .font: Theme.Fonts.smallName, .foregroundColor: Theme.Colors.onClip]

    public override func draw(_ dirtyRect: NSRect) {
        Theme.Colors.lane.setFill(); bounds.fill()
        let rh = Self.rulerHeight
        if let clip = model.clip {
            let geo = geometry
            let path = NSBezierPath(); path.lineWidth = 1
            var labels: [(String, CGFloat)] = []
            let ticks = KeyframeRulerLayout.ticks(geometry: geo, frameDuration: model.frameDuration, nominalFPS: timecode.nominalFPS)
            for t in ticks {
                let x = geo.x(for: t.local).rounded() + 0.5
                let len: CGFloat = t.major ? 8 : 4
                path.move(to: NSPoint(x: x, y: rh - 1 - len)); path.line(to: NSPoint(x: x, y: rh - 1))
                if t.major { labels.append((timecode.string(for: clip.start + t.local, frameDuration: model.frameDuration), x)) }
            }
            Theme.Colors.label3.setStroke(); path.stroke()
            for (text, x) in labels { (text as NSString).draw(at: NSPoint(x: x + 3, y: 2), withAttributes: Self.labelAttributes) }
            drawClipBar(geo, clip: clip)
            drawHead(geo)
        }
        Theme.Colors.separator.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    /// The clip's extent with its name, like the clip bar in Premiere's Effect Controls.
    private func drawClipBar(_ geo: KeyframeLaneGeometry, clip: Clip) {
        let y = Self.rulerHeight, h = Self.clipBarHeight - 1
        let x0 = max(geo.x(for: .zero), 0), x1 = min(geo.x(for: model.duration), bounds.width)
        guard x1 > x0 else { return }
        let rect = NSRect(x: x0, y: y, width: x1 - x0, height: h)
        Theme.Colors.clipVideo.setFill(); rect.fill()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        // Keep the name in view while zoomed in.
        (clip.name as NSString).draw(at: NSPoint(x: x0 + 6, y: y + 1), withAttributes: Self.clipNameAttributes)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawHead(_ geo: KeyframeLaneGeometry) {
        guard model.playheadInClip else { return }
        let x = geo.x(for: model.localPlayhead)
        Theme.Colors.accent.setFill()
        let rh = Self.rulerHeight
        let head = NSBezierPath()
        head.move(to: NSPoint(x: x - 6, y: rh - 12)); head.line(to: NSPoint(x: x + 6, y: rh - 12))
        head.line(to: NSPoint(x: x + 6, y: rh - 5)); head.line(to: NSPoint(x: x, y: rh + 1))
        head.line(to: NSPoint(x: x - 6, y: rh - 5)); head.close()
        head.fill()
        NSRect(x: x.rounded() - 0.5, y: rh, width: 1, height: bounds.height - rh).fill()
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

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(superview)
        guard let t = target(event) else { return }
        dragging = true
        model.scrubDown(to: t)
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
