import AppKit
import CoreText
import SQCore
import SQMedia

/// One muted colour per clip type (docs/DESIGN.md). The model only knows video and audio clips today;
/// nest / title / caption arrive with their slices, the colours are ready.
public enum ClipStyle: Sendable, Hashable {
    case video, audio, nest, title, caption
    /// Clip drawn in a label colour (Project panel labels). The type cases above stay for captions.
    case label(LabelColor)

    public init(kind: TrackKind) { self = kind == .audio ? .audio : .video }

    public var fill: NSColor {
        switch self {
        case .video: Theme.Colors.clipVideo
        case .audio: Theme.Colors.clipAudio
        case .nest: Theme.Colors.clipNest
        case .title: Theme.Colors.clipTitle
        case .caption: Theme.Colors.clipCaption
        case .label(let l): Theme.hex(l.rgb)
        }
    }
    public var edge: NSColor {
        switch self {
        case .video: Theme.Colors.clipVideoEdge
        case .audio: Theme.Colors.clipAudioEdge
        case .nest: Theme.Colors.clipNestEdge
        case .title: Theme.Colors.clipTitleEdge
        case .caption: Theme.Colors.clipCaptionEdge
        case .label(let l): Theme.hex(l.rgb).blended(withFraction: 0.3, of: .white) ?? Theme.hex(l.rgb)
        }
    }
}

/// Draws one clip into the current graphics context. View coordinates, y down (flipped view).
@MainActor
public enum ClipDrawing {
    nonisolated public static let nameStripHeight: CGFloat = 14
    /// Tracks at least this tall show the darker body under the name strip.
    nonisolated public static let bodyMinHeight: CGFloat = 26
    static let offlineFill = Theme.hex(0x6B2A26)

    private static let textAttributes: [NSAttributedString.Key: Any] =
        [.font: Theme.Fonts.clip, .foregroundColor: Theme.Colors.onClip]

    /// Shaped text lines by clip name: shaping dominates the cost of drawing a few hundred names.
    private static var lineCache: [String: CTLine] = [:]

    private static func line(for name: String) -> CTLine {
        if let l = lineCache[name] { return l }
        if lineCache.count > 4000 { lineCache.removeAll() }
        let l = CTLineCreateWithAttributedString(NSAttributedString(string: name, attributes: textAttributes))
        lineCache[name] = l
        return l
    }

    private struct Colors {
        let fill: CGColor, shaded: CGColor, edge: CGColor
        init(fill f: NSColor, edge e: NSColor) {
            fill = f.cgColor; edge = e.cgColor
            shaded = f.blended(withFraction: Theme.Colors.clipShade.alphaComponent, of: .black)?.cgColor ?? f.cgColor
        }
    }
    private static let colorCache: [ClipStyle: Colors] = {
        var d: [ClipStyle: Colors] = [:]
        for s in [ClipStyle.video, .audio, .nest, .title, .caption] + LabelColor.allCases.map({ ClipStyle.label($0) }) {
            d[s] = Colors(fill: s.fill, edge: s.edge)
        }
        return d
    }()
    private static let offlineColors = Colors(fill: offlineFill, edge: Theme.Colors.red)
    private static let selectCG = Theme.Colors.clipSelect.cgColor

    /// - Parameters:
    ///   - rect: the clip's full row-space rectangle (may extend far past `visible` when zoomed in).
    ///   - visible: the horizontal range being drawn; geometry outside it is skipped.
    public static func draw(name: String, rect: CGRect, visible: CGRect, style: ClipStyle,
                            isSelected: Bool, isOffline: Bool) {
        let body = rect.insetBy(dx: 0, dy: 1)
        guard body.width > 0, body.height > 0, let cg = NSGraphicsContext.current?.cgContext else { return }
        // Clamp horizontally (8 pt margin hides the rounded corners) so a clip thousands of points wide costs the same.
        let minX = max(body.minX, visible.minX - 8), maxX = min(body.maxX, visible.maxX + 8)
        guard maxX > minX else { return }
        let drawn = CGRect(x: minX, y: body.minY, width: maxX - minX, height: body.height)
        let radius = min(Theme.Radius.clip, body.height / 2)
        let colors = isOffline ? offlineColors : (colorCache[style] ?? offlineColors)
        let strip = min(nameStripHeight, drawn.height)
        let tall = drawn.height >= bodyMinHeight

        let outline = CGPath(roundedRect: drawn, cornerWidth: radius, cornerHeight: radius, transform: nil)
        // Body (shaded when tall), then the name strip on top with only its top corners rounded.
        cg.setFillColor(tall ? colors.shaded : colors.fill)
        cg.addPath(outline); cg.fillPath()
        if tall {
            cg.setFillColor(colors.fill)
            let p = CGMutablePath()
            p.move(to: CGPoint(x: drawn.minX, y: drawn.minY + strip))
            p.addLine(to: CGPoint(x: drawn.minX, y: drawn.minY + radius))
            p.addArc(tangent1End: CGPoint(x: drawn.minX, y: drawn.minY), tangent2End: CGPoint(x: drawn.minX + radius, y: drawn.minY), radius: radius)
            p.addLine(to: CGPoint(x: drawn.maxX - radius, y: drawn.minY))
            p.addArc(tangent1End: CGPoint(x: drawn.maxX, y: drawn.minY), tangent2End: CGPoint(x: drawn.maxX, y: drawn.minY + radius), radius: radius)
            p.addLine(to: CGPoint(x: drawn.maxX, y: drawn.minY + strip))
            p.closeSubpath()
            cg.addPath(p); cg.fillPath()
        }
        if isSelected { drawTrimHints(cg: cg, body: body, drawn: drawn) }

        // Edge line, then the 2 pt selection border on top.
        cg.setStrokeColor(colors.edge)
        cg.setLineWidth(1)
        cg.addPath(CGPath(roundedRect: drawn.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil))
        cg.strokePath()
        if isSelected {
            cg.setStrokeColor(selectCG)
            cg.setLineWidth(2)
            let r = max(radius - 1, 0)
            cg.addPath(CGPath(roundedRect: drawn.insetBy(dx: 1, dy: 1), cornerWidth: r, cornerHeight: r, transform: nil))
            cg.strokePath()
        }

        // Name on the strip, kept on screen while the clip head is scrolled out. Clipped, not re-shaped, when too long.
        let textLeft = max(body.minX, visible.minX) + 5
        let textWidth = min(body.maxX, visible.maxX) - textLeft - 4
        if textWidth >= 14 {
            cg.saveGState()
            cg.clip(to: CGRect(x: textLeft, y: body.minY, width: textWidth, height: strip))
            cg.textMatrix = CGAffineTransform(scaleX: 1, y: -1)        // flipped view: glyphs upright
            cg.textPosition = CGPoint(x: textLeft, y: body.minY + (strip + 7) / 2)
            CTLineDraw(line(for: name), cg)
            cg.restoreGState()
        }
    }

    /// The waveform area inside a clip's full rectangle (also where the volume line moves).
    nonisolated public static func waveformRect(in rect: CGRect) -> CGRect {
        let body = rect.insetBy(dx: 0, dy: 1)
        let top = body.height >= bodyMinHeight ? body.minY + nameStripHeight : body.minY
        return CGRect(x: body.minX, y: top + 1, width: body.width, height: body.maxY - top - 2)
    }

    /// Waveform of an audio clip over its body (below the name strip when the clip is tall).
    /// `rect` is the clip's full rectangle, `visible` the horizontal range being drawn, `source` the clip's source range.
    /// `volumeDB`: level in dB at source seconds since the clip's source start (Volume line plus Audio Gain), so the waveform shows
    /// what will be heard; nil draws the source as it is.
    public static func drawWaveform(data: WaveformData, media: UUID, source: TimeRange, rect: CGRect, visible: CGRect,
                                    cache: WaveformCache?, volumeDB: (@Sendable (Double) -> Double)? = nil, reversed: Bool = false,
                                    sourceMap: (@Sendable (Double) -> Double)? = nil) {
        guard let cg = NSGraphicsContext.current?.cgContext, rect.width >= 1 else { return }
        let wave = waveformRect(in: rect)
        guard wave.height >= 4 else { return }
        let from = max(Int((visible.minX - wave.minX).rounded(.down)), 0)
        let to = min(Int((visible.maxX - wave.minX).rounded(.up)), Int(wave.width.rounded()))
        guard to > from else { return }
        let style = WaveformStyle()
        var input = WaveformPath.Input(data: data, source: source, clipWidth: wave.width, visibleColumns: from..<to,
                                       style: style, volumeDB: volumeDB ?? { _ in 0 }, cache: cache.map { ($0, media) })
        input.reversed = reversed
        input.sourceMap = sourceMap
        let columns = WaveformPath.columns(input)
        cg.setFillColor(Theme.white(0.55).cgColor)
        cg.addPath(WaveformPath.path(columns: columns, rect: wave, style: style, firstColumn: from))
        cg.fillPath()
    }

    /// "Out of sync" badge: frames the linked partner has drifted ("+3" / "-3"), red on the clip's left edge.
    public static func drawSyncBadge(frames: Int64, rect: CGRect, visible: CGRect) {
        guard let cg = NSGraphicsContext.current?.cgContext, frames != 0, rect.width >= 24 else { return }
        let text = (frames > 0 ? "+" : "\u{2212}") + String(abs(frames))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold), .foregroundColor: NSColor.white]))
        let w = CTLineGetTypographicBounds(line, nil, nil, nil) + 8
        let x = max(rect.minX, visible.minX) + 3
        let y = rect.minY + (rect.height >= bodyMinHeight ? nameStripHeight + 3 : 2)
        let pill = CGRect(x: x, y: y, width: w, height: 12)
        guard pill.maxX < rect.maxX else { return }
        cg.saveGState()
        cg.setFillColor(NSColor(srgbRed: 0.86, green: 0.2, blue: 0.2, alpha: 1).cgColor)
        cg.addPath(CGPath(roundedRect: pill, cornerWidth: 3, cornerHeight: 3, transform: nil)); cg.fillPath()
        cg.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        cg.textPosition = CGPoint(x: pill.minX + 4, y: pill.minY + 9)
        CTLineDraw(line, cg)
        cg.restoreGState()
    }

    /// The volume rubber band over the waveform: a thin line with a diamond on every key.
    public static func drawVolumeLine(clip: Clip, rect: CGRect, visible: CGRect, selected: Bool) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        let pts = VolumeLine.points(clip: clip, clipRect: rect, visible: visible)
        guard pts.count >= 2 else { return }
        cg.saveGState()
        cg.clip(to: visible.intersection(rect))
        cg.setLineWidth(1)
        cg.setStrokeColor(Theme.black(0.45).cgColor)
        cg.addLines(between: pts.map { CGPoint(x: $0.x, y: $0.y + 1) }); cg.strokePath()
        cg.setStrokeColor(Theme.white(selected ? 0.95 : 0.75).cgColor)
        cg.addLines(between: pts); cg.strokePath()
        cg.setFillColor(Theme.white(0.95).cgColor)
        cg.setStrokeColor(Theme.black(0.6).cgColor)
        for k in VolumeLine.keyPoints(clip: clip, clipRect: rect) where k.x >= visible.minX - 4 && k.x <= visible.maxX + 4 {
            let d = CGMutablePath()
            d.move(to: CGPoint(x: k.x, y: k.y - 4)); d.addLine(to: CGPoint(x: k.x + 4, y: k.y))
            d.addLine(to: CGPoint(x: k.x, y: k.y + 4)); d.addLine(to: CGPoint(x: k.x - 4, y: k.y)); d.closeSubpath()
            cg.addPath(d); cg.fillPath()
            cg.addPath(d); cg.strokePath()
        }
        // Fade handles (head and tail): small squares near the top corners.
        let h = VolumeLine.fadeHandlePoints(clip: clip, clipRect: rect)
        if rect.width >= 4 * VolumeLine.handleSize {
            let size = VolumeLine.handleSize
            for c in [h.head, h.tail] {
                let r = CGRect(x: c.x - size / 2, y: c.y - size / 2, width: size, height: size)
                let path = CGPath(roundedRect: r, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)
                cg.setFillColor(Theme.white(selected ? 0.95 : 0.7).cgColor)
                cg.addPath(path); cg.fillPath()
                cg.setStrokeColor(Theme.black(0.6).cgColor)
                cg.addPath(path); cg.strokePath()
            }
        }
        cg.restoreGState()
    }

    /// Dark bars with a grip line at both ends: where trimming will grab (T-04).
    private static func drawTrimHints(cg: CGContext, body: CGRect, drawn: CGRect) {
        let w = TimelineGeometry.trimHandleWidth(forClipWidth: body.width)
        guard w >= 3 else { return }
        let bars = [CGRect(x: body.minX, y: body.minY, width: w, height: body.height),
                    CGRect(x: body.maxX - w, y: body.minY, width: w, height: body.height)]
        for bar in bars where bar.maxX > drawn.minX && bar.minX < drawn.maxX {
            cg.setFillColor(Theme.black(0.28).cgColor)
            cg.fill(bar)
            let gripH = min(body.height - 6, 8)
            if gripH > 2 {
                cg.setFillColor(Theme.white(0.6).cgColor)
                cg.fill(CGRect(x: bar.midX - 0.5, y: bar.midY - gripH / 2, width: 1, height: gripH))
            }
        }
    }
}
