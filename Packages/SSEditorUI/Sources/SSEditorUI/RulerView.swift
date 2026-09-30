import AppKit
import SSCore

/// Timeline ruler: adaptive timecode ticks, In/Out band, marker flags, playhead head.
/// Spans the full timeline width (same x coordinates as `TimelineGeometry`); only the part right of the headers draws ticks.
@MainActor
public final class RulerView: NSView {
    public private(set) var geometry: TimelineGeometry
    public private(set) var timecode: TimecodeFormat
    public private(set) var inOut: TimeRange?
    public private(set) var markers: [Marker] = []
    public private(set) var playhead: Time = .zero
    public var preferDropFrame = true { didSet { refreshFormat() } }

    private static let labelAttributes: [NSAttributedString.Key: Any] =
        [.font: Theme.Fonts.mini, .foregroundColor: Theme.Colors.label2]

    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { true }

    public init(geometry: TimelineGeometry) {
        self.geometry = geometry
        self.timecode = TimecodeFormat(frameDuration: geometry.frameDuration)
        super.init(frame: .zero)
        wantsLayer = true
    }
    public required init?(coder: NSCoder) { fatalError("not used") }

    private func refreshFormat() {
        timecode = TimecodeFormat(frameDuration: geometry.frameDuration, preferDropFrame: preferDropFrame)
        needsDisplay = true
    }

    public func update(geometry: TimelineGeometry, inOut: TimeRange?, markers: [Marker], playhead: Time) {
        let rateChanged = geometry.frameDuration != self.geometry.frameDuration
        self.geometry = geometry
        self.inOut = inOut
        self.markers = markers
        self.playhead = playhead
        if rateChanged { timecode = TimecodeFormat(frameDuration: geometry.frameDuration, preferDropFrame: preferDropFrame) }
        needsDisplay = true
    }

    /// Only the playhead moved: invalidate the old and new head, not the whole ruler.
    public func movePlayhead(to time: Time) {
        let old = geometry.x(for: playhead), new = geometry.x(for: time)
        playhead = time
        for x in [old, new] { setNeedsDisplay(CGRect(x: x - 7, y: 0, width: 14, height: bounds.height)) }
    }

    /// Ticks as (frame index, isMajor) for the visible span.
    func ticks(visibleMinX: CGFloat, visibleMaxX: CGFloat) -> (scale: RulerScale, frames: [(frame: Int64, major: Bool)]) {
        let fdSec = Double(geometry.frameDuration.value) / Double(geometry.frameDuration.timescale)
        let ppf = geometry.pointsPerSecond * fdSec
        let scale = RulerScale.scale(pointsPerFrame: ppf, nominalFPS: timecode.nominalFPS)
        let firstFrame = Int64(((Double(visibleMinX - TimelineGeometry.contentOriginX + geometry.scrollX)) / ppf).rounded(.down))
        let lastFrame = Int64(((Double(visibleMaxX - TimelineGeometry.contentOriginX + geometry.scrollX)) / ppf).rounded(.up))
        var f = max(0, (firstFrame / scale.minorFrames) * scale.minorFrames)
        var out: [(Int64, Bool)] = []
        while f <= lastFrame {
            out.append((f, f % scale.majorFrames == 0))
            f += scale.minorFrames
        }
        return (scale, out)
    }

    public override func draw(_ dirtyRect: NSRect) {
        Theme.Colors.lane.setFill()
        dirtyRect.fill()
        let h = bounds.height
        let origin = TimelineGeometry.contentOriginX
        let content = CGRect(x: origin, y: 0, width: max(bounds.width - origin, 0), height: h)
        let clip = dirtyRect.intersection(content)

        if !clip.isEmpty {
            NSGraphicsContext.saveGraphicsState()
            clip.clip()
            drawInOut(in: clip)
            drawTicks(in: clip)
            drawMarkers(in: clip)
            NSGraphicsContext.restoreGraphicsState()
        }
        // Bottom hairline and the divider above the header column.
        Theme.Colors.separator.setFill()
        CGRect(x: dirtyRect.minX, y: h - 1, width: dirtyRect.width, height: 1).fill()
        drawPlayheadHead(dirty: dirtyRect)
    }

    private func drawInOut(in clip: CGRect) {
        guard let io = inOut, !io.isEmpty else { return }
        let x0 = geometry.x(for: io.start), x1 = geometry.x(for: io.end)
        guard x1 > clip.minX, x0 < clip.maxX else { return }
        Theme.Colors.range.setFill()
        CGRect(x: x0, y: 0, width: x1 - x0, height: bounds.height - 1).fill()
        Theme.Colors.rangeEdge.setFill()
        if x0 >= clip.minX - 1 { CGRect(x: x0, y: 0, width: 1, height: bounds.height - 1).fill() }
        if x1 <= clip.maxX + 1 { CGRect(x: x1 - 1, y: 0, width: 1, height: bounds.height - 1).fill() }
    }

    private func drawTicks(in clip: CGRect) {
        let (_, ticks) = ticks(visibleMinX: clip.minX - 80, visibleMaxX: clip.maxX)
        let h = bounds.height
        let fd = geometry.frameDuration
        let tickPath = NSBezierPath()
        tickPath.lineWidth = 1
        var labels: [(String, CGFloat)] = []
        for (frame, major) in ticks {
            let x = (geometry.x(for: fd * frame)).rounded() + 0.5
            let len: CGFloat = major ? 8 : 4
            tickPath.move(to: CGPoint(x: x, y: h - 1 - len))
            tickPath.line(to: CGPoint(x: x, y: h - 1))
            if major { labels.append((timecode.string(forFrame: frame), x)) }
        }
        Theme.Colors.label3.setStroke()
        tickPath.stroke()
        for (text, x) in labels {
            (text as NSString).draw(at: CGPoint(x: x + 3, y: 2), withAttributes: Self.labelAttributes)
        }
    }

    private func drawMarkers(in clip: CGRect) {
        Theme.Colors.marker.setFill()
        for m in markers {
            let x = geometry.x(for: m.time).rounded()
            guard x >= clip.minX - 8, x <= clip.maxX + 8 else { continue }
            // Small flag: pole plus a pennant.
            let flag = NSBezierPath()
            flag.move(to: CGPoint(x: x, y: 3))
            flag.line(to: CGPoint(x: x + 7, y: 3))
            flag.line(to: CGPoint(x: x + 5, y: 6.5))
            flag.line(to: CGPoint(x: x + 7, y: 10))
            flag.line(to: CGPoint(x: x, y: 10))
            flag.close()
            flag.fill()
            CGRect(x: x, y: 3, width: 1, height: bounds.height - 4).fill()
        }
    }

    private func drawPlayheadHead(dirty: CGRect) {
        let x = geometry.x(for: playhead)
        guard CGRect(x: x - 6, y: 0, width: 12, height: bounds.height).intersects(dirty) else { return }
        Theme.Colors.playhead.setFill()
        let head = NSBezierPath()
        head.move(to: CGPoint(x: x - 5, y: bounds.height - 9))
        head.line(to: CGPoint(x: x + 5, y: bounds.height - 9))
        head.line(to: CGPoint(x: x, y: bounds.height - 2))
        head.close()
        NSGraphicsContext.saveGraphicsState()
        CGRect(x: TimelineGeometry.contentOriginX, y: 0, width: bounds.width, height: bounds.height).clip()
        head.fill()
        CGRect(x: x.rounded() - 0.5, y: bounds.height - 9, width: 1, height: 9).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}
