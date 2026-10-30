import AppKit
import SQCore
import SQUIKit
import SQPlayback

/// Timeline ruler: adaptive timecode ticks, In/Out band, marker flags, playhead head.
/// Spans the full timeline width (same x coordinates as `TimelineGeometry`); only the part right of the headers draws ticks.
@MainActor
public final class RulerView: NSView, NSViewToolTipOwner {
    public private(set) var geometry: TimelineGeometry
    public private(set) var timecode: TimecodeFormat
    public private(set) var inOut: TimeRange?
    public private(set) var markers: [Marker] = []
    public private(set) var playhead: Time = .zero
    /// Timeline spans whose frames are cached (a thin strip along the top edge); only repainted when they change.
    public private(set) var cachedRanges: [TimeRange] = []
    public var preferDropFrame = true { didSet { refreshFormat() } }
    /// Sequence Settings: timecode of time zero and the frame-count display.
    public var timecodeStart: Time = .zero { didSet { if timecodeStart != oldValue { refreshFormat() } } }
    public var framesOnly = false { didSet { if framesOnly != oldValue { refreshFormat() } } }

    private func makeFormat() -> TimecodeFormat {
        var f = TimecodeFormat(frameDuration: geometry.frameDuration, preferDropFrame: preferDropFrame)
        f.startFrame = timecodeStart.frameIndex(frameDuration: geometry.frameDuration)
        f.framesOnly = framesOnly
        return f
    }

    private static let labelAttributes: [NSAttributedString.Key: Any] =
        [.font: Theme.Typography.caption, .foregroundColor: Theme.Colors.label3]

    public nonisolated override var isFlipped: Bool { true }
    public override var isOpaque: Bool { true }

    public init(geometry: TimelineGeometry) {
        self.geometry = geometry
        self.timecode = TimecodeFormat(frameDuration: geometry.frameDuration)
        super.init(frame: .zero)
        wantsLayer = true
        // macOS 14+: views do not clip by default, so an opaque `dirtyRect.fill()` would paint over its siblings.
        clipsToBounds = true
        addToolTip(NSRect(x: 0, y: 0, width: 100_000, height: 100_000), owner: self, userData: nil)
    }

    nonisolated public func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        MainActor.assumeIsolated { inOutTipText(at: point) }
    }

    /// Tooltip only over the In/Out band.
    func inOutTipText(at p: NSPoint) -> String {
        guard let io = inOut, !io.isEmpty else { return "" }
        let x0 = geometry.x(for: io.start), x1 = geometry.x(for: io.end)
        return p.x >= x0 && p.x <= x1 ? Self.inOutTip() : ""
    }
    public required init?(coder: NSCoder) { fatalError("not used") }

    private func refreshFormat() {
        timecode = makeFormat()
        needsDisplay = true
    }

    static let cacheStripHeight: CGFloat = 2

    public func setCachedRanges(_ r: [TimeRange]) {
        guard r != cachedRanges else { return }
        cachedRanges = r
        setNeedsDisplay(NSRect(x: 0, y: 0, width: bounds.width, height: Self.cacheStripHeight))
    }

    public func update(geometry: TimelineGeometry, inOut: TimeRange?, markers: [Marker], playhead: Time) {
        let rateChanged = geometry.frameDuration != self.geometry.frameDuration
        self.geometry = geometry
        self.inOut = inOut
        self.markers = markers
        self.playhead = playhead
        if rateChanged { timecode = makeFormat() }
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

    /// Board tooltip of the In/Out band, keys read from the live key map.
    static func inOutTip(map: CommandMap = .current) -> String {
        func key(_ c: EditorCommand) -> String { map.binding(for: c).map { KeyboardListing.text(for: $0) } ?? "" }
        let i = key(.markIn), o = key(.markOut), x = key(.clearInOut)
        let keys = [i.isEmpty || o.isEmpty ? nil : "\(i) / \(o)", x.isEmpty ? nil : SQL10n.format("Remove In and Out: %@", x)].compactMap { $0 }
        return keys.isEmpty ? SQL10n.string("In/Out range") : SQL10n.format("In/Out range (%@)", keys.joined(separator: ", "))
    }

    public override func draw(_ dirtyRect: NSRect) {
        PlayProbe.timed("ruler.draw dirty \(Int(dirtyRect.width))") { drawRuler(dirtyRect) }
    }

    private func drawRuler(_ dirtyRect: NSRect) {
        Theme.Colors.timeline.setFill()                 // design v9: the ruler sits on the timeline color
        dirtyRect.intersection(bounds).fill()
        let h = bounds.height
        let origin = TimelineGeometry.contentOriginX
        let content = CGRect(x: origin, y: 0, width: max(bounds.width - origin, 0), height: h)
        let clip = dirtyRect.intersection(content)

        if !clip.isEmpty {
            NSGraphicsContext.saveGraphicsState()
            clip.clip()
            drawInOut(in: clip)
            drawCacheStrip(in: clip)
            drawTicks(in: clip)
            drawMarkers(in: clip)
            NSGraphicsContext.restoreGraphicsState()
        }
        drawTracksCorner(dirty: dirtyRect)
        // Bottom hairline and the divider above the header column.
        Theme.Colors.trackRowLine.setFill()
        CGRect(x: dirtyRect.minX, y: h - 1, width: dirtyRect.width, height: 1).fill()
        drawPlayheadHead(dirty: dirtyRect)
    }

    /// Board `.trk .th` in the ruler row: panel fill over the header column (no caption) and the
    /// column's right-hand separator.
    private func drawTracksCorner(dirty: CGRect) {
        let r = CGRect(x: TimelineGeometry.toolColumnWidth, y: 0, width: TimelineGeometry.headerWidth, height: bounds.height)
        guard r.intersects(dirty) else { return }
        Theme.Colors.panel.setFill()
        r.fill()
        Theme.Colors.separator.setFill()
        CGRect(x: r.maxX - 1, y: 0, width: 1, height: r.height).fill()
        // Design v9 corner: "Tracks", 11 pt, third label color, 8 pt in.
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.Typography.body, .foregroundColor: Theme.Colors.label3]
        let text = "Tracks" as NSString
        let size = text.size(withAttributes: attrs)
        text.draw(at: CGPoint(x: r.minX + Theme.Spacing.sm, y: ((r.height - size.height) / 2).rounded()), withAttributes: attrs)
    }

    /// The cached spans as x ranges: spans less than `cacheMergeGap` apart join and runs under `cacheMinWidth` are dropped, so
    /// the strip reads as a few clear bars, never as scattered specks along the top edge.
    static let cacheMergeGap: CGFloat = 6
    static let cacheMinWidth: CGFloat = 3
    static func cacheBars(_ ranges: [TimeRange], geometry: TimelineGeometry) -> [ClosedRange<CGFloat>] {
        var bars: [ClosedRange<CGFloat>] = []
        for r in ranges.sorted(by: { $0.start < $1.start }) {
            let a = geometry.x(for: r.start), b = geometry.x(for: r.end)
            guard b >= a else { continue }
            if let last = bars.last, a - last.upperBound < cacheMergeGap {
                bars[bars.count - 1] = last.lowerBound...max(last.upperBound, b)
            } else { bars.append(a...b) }
        }
        return bars.filter { $0.upperBound - $0.lowerBound >= cacheMinWidth }
    }

    private func drawCacheStrip(in clip: CGRect) {
        guard !cachedRanges.isEmpty else { return }
        Theme.TimelineSkin.cacheStrip.setFill()
        for bar in Self.cacheBars(cachedRanges, geometry: geometry) {
            let x0 = max(bar.lowerBound, clip.minX), x1 = min(bar.upperBound, clip.maxX)
            if x1 > x0 { CGRect(x: x0, y: 0, width: x1 - x0, height: Self.cacheStripHeight).fill() }
        }
    }

    /// Design v9 `.ruler .io`: a 4 pt accent-tint bar along the bottom; its two ends carry a 2 pt accent grip (drag to move them).
    private func drawInOut(in clip: CGRect) {
        guard let io = inOut, !io.isEmpty else { return }
        let x0 = geometry.x(for: io.start), x1 = geometry.x(for: io.end)
        guard x1 > clip.minX, x0 < clip.maxX else { return }
        let h = bounds.height
        Theme.Colors.accentTint.setFill()
        NSBezierPath(roundedRect: CGRect(x: x0, y: h - 4, width: x1 - x0, height: 4),
                     xRadius: Theme.Radius.small / 2, yRadius: Theme.Radius.small / 2).fill()
        Theme.Colors.accent.setFill()
        if x0 >= clip.minX - 2 { CGRect(x: x0, y: h - 8, width: 2, height: 8).fill() }
        if x1 <= clip.maxX + 2 { CGRect(x: x1 - 2, y: h - 8, width: 2, height: 8).fill() }
    }

    /// Design v9 `.ruler .lbl`: the label 4 pt right of an 8 pt tick at the bottom; 4 pt ticks between the labels.
    private func drawTicks(in clip: CGRect) {
        let (_, ticks) = ticks(visibleMinX: clip.minX - 80, visibleMaxX: clip.maxX)
        let h = bounds.height
        let fd = geometry.frameDuration
        let minor = NSBezierPath(), major = NSBezierPath()
        minor.lineWidth = 1; major.lineWidth = 1
        var labels: [(String, CGFloat)] = []
        for (frame, isMajor) in ticks {
            let x = (geometry.x(for: fd * frame)).rounded() + 0.5
            if isMajor {
                major.move(to: CGPoint(x: x, y: h - 8)); major.line(to: CGPoint(x: x, y: h))
                labels.append((timecode.string(forFrame: frame), x))
            } else {
                minor.move(to: CGPoint(x: x, y: h - 4)); minor.line(to: CGPoint(x: x, y: h))
            }
        }
        Theme.Colors.rulerMinor.setStroke()
        minor.stroke()
        Theme.Colors.rulerLine.setStroke()
        major.stroke()
        let lineHeight = ("0" as NSString).size(withAttributes: Self.labelAttributes).height
        for (text, x) in labels {
            (text as NSString).draw(at: CGPoint(x: x + 3.5, y: ((h - lineHeight) / 2).rounded()), withAttributes: Self.labelAttributes)
        }
    }

    static func color(of c: MarkerColor) -> NSColor { Theme.Palette.marker(c) }

    /// Design v9 `.ruler .mk`: a 7 pt dot, 4 pt above the ruler's bottom edge, in the marker color;
    /// a marker with a duration also gets a 4 pt bar to its end (`MarkerRange`).
    private func drawMarkers(in clip: CGRect) {
        for m in markers {
            let x = geometry.x(for: m.time).rounded()
            guard x <= clip.maxX + 8, max(x, geometry.x(for: m.time + m.duration)) >= clip.minX - 8 else { continue }
            Self.color(of: m.color).setFill()
            if let bar = MarkerRange.barRect(m, geometry: geometry, rulerHeight: bounds.height), bar.maxX >= clip.minX {
                Self.color(of: m.color).withAlphaComponent(0.55).setFill()
                bar.fill()
                Self.color(of: m.color).setFill()
                CGRect(x: bar.maxX - 1, y: bar.minY - 3, width: 2, height: bar.height + 3).fill()   // end handle
            }
            NSBezierPath(ovalIn: CGRect(x: x - 3.5, y: bounds.height - 4 - 7, width: 7, height: 7)).fill()
        }
    }

    /// Design v9 `.playhead`: a 2 pt line with the K1 head (`Theme.PlayheadSkin`).
    private func drawPlayheadHead(dirty: CGRect) {
        let x = geometry.x(for: playhead)
        guard CGRect(x: x - 7, y: 0, width: 14, height: bounds.height).intersects(dirty) else { return }
        NSGraphicsContext.saveGraphicsState()
        CGRect(x: TimelineGeometry.contentOriginX, y: 0, width: bounds.width, height: bounds.height).clip()
        let c = x.rounded()
        Theme.Colors.playhead.setFill()
        PlayheadLineView.frame(centerX: c, height: bounds.height).fill()
        Theme.PlayheadSkin.drawHead(centerX: c)
        NSGraphicsContext.restoreGraphicsState()
    }
}
