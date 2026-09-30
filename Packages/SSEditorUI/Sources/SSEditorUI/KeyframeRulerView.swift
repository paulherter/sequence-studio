import AppKit
import SSCore

/// Pure tick layout of the Effect Controls ruler (clip range, same x mapping as the keyframe lanes).
public enum KeyframeRulerLayout {
    public struct Tick: Equatable, Sendable {
        /// Clip-local time.
        public var local: Time
        public var major: Bool
    }

    /// Ticks over the clip range 0...duration for the given lane width.
    public static func ticks(width: CGFloat, duration: Time, frameDuration: Time, nominalFPS: Int) -> [Tick] {
        let geo = KeyframeLaneGeometry(width: width, duration: duration)
        let frames = duration.frameIndex(frameDuration: frameDuration)
        guard frames > 0 else { return [] }
        let ppf = Double(geo.x(for: duration) - geo.x(for: .zero)) / Double(frames)
        guard ppf > 0 else { return [] }
        let scale = RulerScale.scale(pointsPerFrame: ppf, nominalFPS: nominalFPS)
        var out: [Tick] = []
        var f: Int64 = 0
        while f <= frames {
            out.append(Tick(local: frameDuration * f, major: f % scale.majorFrames == 0))
            f += scale.minorFrames
        }
        return out
    }

    /// Timeline time for a pointer x in the ruler, frame-snapped and clamped to the clip.
    public static func seekTime(atX x: CGFloat, width: CGFloat, clipStart: Time, duration: Time, frameDuration: Time) -> Time {
        clipStart + KeyframeLaneGeometry(width: width, duration: duration).time(at: x, frameDuration: frameDuration)
    }
}

/// Ruler above the keyframe lanes: clip range with timecode labels, draggable playhead head. Dragging seeks the session.
public final class KeyframeRulerView: NSView {
    public let model: EffectControlsModel
    public static let height: CGFloat = 24
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

    var geometry: KeyframeLaneGeometry { KeyframeLaneGeometry(width: bounds.width, duration: model.duration) }
    private var timecode: TimecodeFormat { TimecodeFormat(frameDuration: model.frameDuration) }

    private static let labelAttributes: [NSAttributedString.Key: Any] = [
        .font: Theme.Fonts.mini, .foregroundColor: Theme.Colors.label3]

    public override func draw(_ dirtyRect: NSRect) {
        Theme.Colors.lane.setFill(); bounds.fill()
        let h = bounds.height
        if let clip = model.clip {
            let geo = geometry
            let path = NSBezierPath(); path.lineWidth = 1
            var labels: [(String, CGFloat)] = []
            let ticks = KeyframeRulerLayout.ticks(width: bounds.width, duration: model.duration,
                                                  frameDuration: model.frameDuration, nominalFPS: timecode.nominalFPS)
            for t in ticks {
                let x = geo.x(for: t.local).rounded() + 0.5
                let len: CGFloat = t.major ? 8 : 4
                path.move(to: NSPoint(x: x, y: h - 1 - len)); path.line(to: NSPoint(x: x, y: h - 1))
                if t.major { labels.append((timecode.string(for: clip.start + t.local, frameDuration: model.frameDuration), x)) }
            }
            Theme.Colors.label3.setStroke(); path.stroke()
            for (text, x) in labels { (text as NSString).draw(at: NSPoint(x: x + 3, y: 2), withAttributes: Self.labelAttributes) }
            drawHead(geo)
        }
        Theme.Colors.separator.setFill()
        NSRect(x: 0, y: h - 1, width: bounds.width, height: 1).fill()
    }

    private func drawHead(_ geo: KeyframeLaneGeometry) {
        guard model.playheadInClip else { return }
        let x = geo.x(for: model.localPlayhead)
        Theme.Colors.playhead.setFill()
        let head = NSBezierPath()
        head.move(to: NSPoint(x: x - 5, y: bounds.height - 9)); head.line(to: NSPoint(x: x + 5, y: bounds.height - 9))
        head.line(to: NSPoint(x: x, y: bounds.height - 2)); head.close()
        head.fill()
        NSRect(x: x.rounded() - 0.5, y: bounds.height - 9, width: 1, height: 9).fill()
    }

    // MARK: Mouse: click or drag anywhere on the ruler moves the session playhead

    private func seek(_ event: NSEvent) {
        guard let clip = model.clip else { return }
        let x = convert(event.locationInWindow, from: nil).x
        model.onSeek?(KeyframeRulerLayout.seekTime(atX: x, width: bounds.width, clipStart: clip.start,
                                                   duration: model.duration, frameDuration: model.frameDuration))
    }

    public override func mouseDown(with event: NSEvent) { dragging = true; seek(event) }
    public override func mouseDragged(with event: NSEvent) { if dragging { seek(event) } }
    public override func mouseUp(with event: NSEvent) { dragging = false }
}
