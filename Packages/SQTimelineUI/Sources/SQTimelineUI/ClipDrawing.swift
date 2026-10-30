import AppKit
import CoreText
import SQCore
import SQMedia

/// One muted color per clip type (docs/DESIGN.md). The model only knows video and audio clips today;
/// nest / title / caption arrive with their slices, the colors are ready.
public enum ClipStyle: Sendable, Hashable {
    case video, audio, nest, title, caption
    /// Clip drawn in a label color (Project panel labels). The type cases above stay for captions.
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
    /// Board `.clip`: `inset 0 0 0 .5px` white at 22 % for every type (an alpha over the fill, not a pre-lifted color).
    public var edge: NSColor { Theme.TimelineSkin.clipEdge }
    /// Text color of the clip name on `fill`: white, or black on the light label fills (`LabelColor.onFill`, 4.5:1 or better).
    public var onFill: NSColor {
        if case .label(let l) = self { return l.onFill }
        return Theme.Colors.onClip
    }
    /// True when the name is drawn black (light label fills).
    var darkText: Bool { onFill != Theme.Colors.onClip }
}

/// A tile of the thumbnail modes with its picture (nil = empty well while it loads).
public struct ClipThumbnailPicture {
    public var tile: ThumbnailTile
    public var image: CGImage?
    public init(tile: ThumbnailTile, image: CGImage?) { self.tile = tile; self.image = image }
}

/// Draws one clip into the current graphics context. View coordinates, y down (flipped view).
@MainActor
public enum ClipDrawing {
    nonisolated public static let nameStripHeight = ClipBodyMetrics.nameStripHeight
    /// Tracks at least this tall put the name in a top band and keep waveform / thumbnails below it (one fill, no second tone).
    nonisolated public static let bodyMinHeight = ClipBodyMetrics.bodyMinHeight
    /// Board `.clip`: a 0.5 px white line at 22 % (one device pixel at 2x).
    nonisolated static let edgeLineWidth: CGFloat = 0.5
    /// The edge line never gets thinner than one device pixel: 0.5 pt at 2x, 1 pt when the timeline draws at 1x while zooming.
    nonisolated static func edgeWidth(_ cg: CGContext) -> CGFloat { edgeWidth(scale: abs(cg.userSpaceToDeviceSpaceTransform.a)) }
    nonisolated static func edgeWidth(scale: CGFloat) -> CGFloat { max(edgeLineWidth, 1 / max(scale, 1)) }
    static let offlineFill = Theme.OnPicture.offlineClip

    private static func textAttributes(dark: Bool) -> [NSAttributedString.Key: Any] {
        [.font: Theme.Typography.clipName, .foregroundColor: dark ? Theme.TimelineSkin.nameOnLight : Theme.Colors.onClip]
    }

    /// Shaped text lines by clip name: shaping dominates the cost of drawing a few hundred names.
    private static var lineCache: [String: CTLine] = [:]

    /// Drawn width of a clip name (the part of a clip whose picture depends on where the viewport's left edge is).
    static func nameWidth(_ name: String) -> CGFloat { CGFloat(CTLineGetTypographicBounds(line(for: name), nil, nil, nil)) }

    private static func line(for name: String, dark: Bool = false) -> CTLine {
        let key = dark ? name + "\u{1}" : name
        if let l = lineCache[key] { return l }
        if lineCache.count > 4000 { lineCache.removeAll() }
        let l = CTLineCreateWithAttributedString(NSAttributedString(string: name, attributes: textAttributes(dark: dark)))
        lineCache[key] = l
        return l
    }

    /// Board "Clip badges": an offline clip is flat and says "Media offline" in a light red.
    static let offlineLabel = "Media offline"
    private static let offlineLine = CTLineCreateWithAttributedString(NSAttributedString(
        string: offlineLabel, attributes: [.font: Theme.Typography.clipName, .foregroundColor: Theme.Colors.offlineText]))
    /// Board `.thh`: the thumbnail column of a media video clip, 25 pt wide, a 1 px dark rule on its right.
    public nonisolated static let thumbnailWidth = ClipBodyMetrics.thumbnailWidth

    private struct Colors {
        /// One fill for the whole clip (feedback 2026-10-05: no two-tone name bar over a darker body).
        let fill: CGColor, edge: CGColor
        init(fill f: NSColor, edge e: NSColor) { fill = f.cgColor; edge = e.cgColor }
    }
    private static let colorCache: [ClipStyle: Colors] = {
        var d: [ClipStyle: Colors] = [:]
        for s in [ClipStyle.video, .audio, .nest, .title, .caption] + LabelColor.allCases.map({ ClipStyle.label($0) }) {
            d[s] = Colors(fill: s.fill, edge: s.edge)
        }
        return d
    }()
    private static let offlineColors = Colors(fill: offlineFill, edge: Theme.TimelineSkin.clipEdge)
    private static let selectCG = Theme.Colors.yellow.cgColor      // board `selc`: 2 pt yellow inset ring
    /// Thumbnail well and its right rule (made once: `.cgColor` builds a new CGColor per call).
    private static let thumbWellCG = Theme.Colors.thumbWell.cgColor
    private static let thumbRuleCG = Theme.TimelineSkin.thumbRule.cgColor

    /// The thumbnail column a clip that is not flat (and not offline) gets in a row of `rowHeight`: `width`, or 0 when the
    /// row is too low or the clip too narrow for it.
    public static func thumbnailColumn(clipWidth: CGFloat, rowHeight: CGFloat, width: CGFloat) -> CGFloat {
        ClipBodyMetrics.thumbnailColumn(clipWidth: clipWidth, rowHeight: rowHeight, width: width)
    }

    /// - Parameters:
    ///   - rect: the clip's full row-space rectangle (may extend far past `visible` when zoomed in).
    ///   - visible: the horizontal range being drawn; geometry outside it is skipped.
    ///   - flat: board `.clip` without name bar and body (title, adjustment, nested, caption clips; offline clips).
    ///   - trailingReserve: width at the clip's right end the name must not reach (the fx badge); the name truncates before it.
    ///   - thumbnailWidth: width of the thumbnail column at the clip's left (0 = none); `thumbnail` is its picture (nil = empty well).
    ///   - leadingReserve: how far the name moves right for a control in front of it (the item lanes arrow).
    /// Level of detail (the design notes 2026-10-11): a clip narrower than this many points is a plain filled rect.
    public nonisolated static let simpleWidth: CGFloat = 3
    /// Off: every clip takes the full draw (tests and A/B measurement; env SQ_NO_LOD).
    nonisolated(unsafe) static var lodEnabled = ProcessInfo.processInfo.environment["SQ_NO_LOD"] == nil
    public static func isSimple(width: CGFloat) -> Bool { lodEnabled && width < simpleWidth }

    /// The simple draw of a clip under `simpleWidth`: its body rect in the clip color (yellow when selected), nothing else.
    public static func drawSimple(rect: CGRect, style: ClipStyle, isSelected: Bool, isOffline: Bool) {
        let body = rect.insetBy(dx: 0, dy: 1)
        guard body.width > 0, body.height > 0, let cg = NSGraphicsContext.current?.cgContext else { return }
        let colors = isOffline ? offlineColors : (colorCache[style] ?? offlineColors)
        cg.setFillColor(isSelected ? selectCG : colors.fill)
        cg.fill(body)
    }

    public static func draw(name: String, rect: CGRect, visible: CGRect, style: ClipStyle,
                            isSelected: Bool, isOffline: Bool, flat: Bool = false,
                            thumbnailWidth thumbW: CGFloat = 0, thumbnail: CGImage? = nil, trailingReserve: CGFloat = 0,
                            leadingReserve: CGFloat = 0, thumbnailTiles: [ClipThumbnailPicture]? = nil) {
        let body = rect.insetBy(dx: 0, dy: 1)
        guard body.width > 0, body.height > 0, let cg = NSGraphicsContext.current?.cgContext else { return }
        // Clamp horizontally (8 pt margin hides the rounded corners) so a clip thousands of points wide costs the same.
        let minX = max(body.minX, visible.minX - 8), maxX = min(body.maxX, visible.maxX + 8)
        guard maxX > minX else { return }
        let drawn = CGRect(x: minX, y: body.minY, width: maxX - minX, height: body.height)
        let radius = min(Theme.Radius.small, body.height / 2)
        let colors = isOffline ? offlineColors : (colorCache[style] ?? offlineColors)
        let strip = min(nameStripHeight, drawn.height)
        let flat = flat || isOffline
        let tall = !flat && drawn.height >= bodyMinHeight

        let cut = usePixelCuts ? PixelCuts(cg.ctm, drawn: drawn, radius: radius, strip: tall ? strip : nil) : nil
        if cut?.draw(cg, body: body, drawn: drawn, radius: radius, strip: strip, tall: tall, fill: colors.fill,
                     edge: colors.edge, isSelected: isSelected) != true {
            drawChrome(cg: cg, body: body, drawn: drawn, radius: radius, strip: strip, tall: tall, colors: colors, isSelected: isSelected)
        }

        var thumbW = tall ? Self.thumbnailColumn(clipWidth: body.width, rowHeight: rect.height, width: thumbW) : 0
        var tailW: CGFloat = 0
        if let pictures = thumbnailTiles, tall {
            // Thumbnail modes (ThumbnailMode): the caller laid the tiles out; the name keeps clear of a head and a tail column.
            thumbW = 0
            for p in pictures {
                drawThumbnailTile(cg: cg, body: body, drawn: drawn, strip: strip, tile: p.tile, radius: radius, image: p.image, isSelected: isSelected)
                if !p.tile.belowNameStrip {
                    if p.tile.anchor == .tail { tailW = p.tile.width } else { thumbW = p.tile.width }
                }
            }
        } else if thumbW > 0 {
            drawThumbnail(cg: cg, body: body, drawn: drawn, width: thumbW, radius: radius, image: thumbnail, isSelected: isSelected)
        }

        // Name on the strip, kept on screen while the clip head is scrolled out. Clipped, not re-shaped, when too long.
        let textLeft = max(body.minX + thumbW, visible.minX) + 6 + leadingReserve
        let textWidth = min(body.maxX, visible.maxX) - textLeft - 4 - trailingReserve - tailW
        if textWidth >= 14 {
            cg.saveGState()
            cg.clip(to: CGRect(x: textLeft, y: body.minY, width: textWidth, height: flat ? drawn.height : strip))
            cg.textMatrix = CGAffineTransform(scaleX: 1, y: -1)        // flipped view: glyphs upright
            let baseline = flat && drawn.height >= 18 ? body.minY + 12.5 : body.minY + (strip + 7) / 2
            cg.textPosition = CGPoint(x: textLeft + (flat ? 1 : 0), y: baseline)
            CTLineDraw(isOffline ? offlineLine : line(for: name, dark: style.darkText), cg)
            cg.restoreGState()
        }
    }

    /// Thumbnail column over the clip's left end, inside the edge line / selection ring.
    private static func drawThumbnail(cg: CGContext, body: CGRect, drawn: CGRect, width: CGFloat, radius: CGFloat,
                                      image: CGImage?, isSelected: Bool) {
        let inset: CGFloat = isSelected ? 2 : 0.5
        let r = CGRect(x: body.minX + inset, y: body.minY + inset, width: width - inset, height: body.height - 2 * inset)
        guard r.maxX > drawn.minX, r.minX < drawn.maxX else { return }
        cg.saveGState()
        let cr = max(radius - inset, 0)
        cg.addPath(CGPath(roundedRect: body.insetBy(dx: inset, dy: inset), cornerWidth: cr, cornerHeight: cr, transform: nil))
        cg.clip()
        cg.clip(to: r)
        fillPicture(cg: cg, in: r, image: image)
        cg.restoreGState()
        cg.setFillColor(thumbRuleCG)
        cg.fill(CGRect(x: r.maxX - 1, y: r.minY, width: 1, height: r.height))
    }

    /// The well and the picture cropped to fill `r` (flipped view: the picture upright).
    private static func fillPicture(cg: CGContext, in r: CGRect, image: CGImage?) {
        cg.setFillColor(thumbWellCG)
        cg.fill(r)
        guard let image else { return }
        cg.saveGState()
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        let k = max(r.width / iw, r.height / ih)
        let w = iw * k, h = ih * k
        cg.translateBy(x: r.midX - w / 2, y: r.midY + h / 2)
        cg.scaleBy(x: 1, y: -1)
        cg.interpolationQuality = .medium
        cg.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        cg.restoreGState()
    }

    /// One tile of the thumbnail modes. A column tile (head, tail) spans the body height and is ruled on its inner side;
    /// a strip tile sits under the name strip and is ruled on its right.
    private static func drawThumbnailTile(cg: CGContext, body: CGRect, drawn: CGRect, strip: CGFloat, tile: ThumbnailTile,
                                          radius: CGFloat, image: CGImage?, isSelected: Bool) {
        let inset: CGFloat = isSelected ? 2 : 0.5
        let top = tile.belowNameStrip ? strip : inset
        let x0 = body.minX + tile.offset
        var r = CGRect(x: x0, y: body.minY + top, width: tile.width, height: body.height - top - inset)
        // Keep inside the edge line / selection ring at the clip's ends.
        if r.minX < body.minX + inset { r.size.width -= body.minX + inset - r.minX; r.origin.x = body.minX + inset }
        if r.maxX > body.maxX - inset { r.size.width = body.maxX - inset - r.minX }
        guard r.width > 0, r.height > 0, r.maxX > drawn.minX, r.minX < drawn.maxX else { return }
        cg.saveGState()
        let cr = max(radius - inset, 0)
        cg.addPath(CGPath(roundedRect: body.insetBy(dx: inset, dy: inset), cornerWidth: cr, cornerHeight: cr, transform: nil))
        cg.clip()
        cg.clip(to: r)
        fillPicture(cg: cg, in: r, image: image)
        cg.restoreGState()
        cg.setFillColor(thumbRuleCG)
        let ruleX = tile.anchor == .tail && !tile.belowNameStrip ? r.minX : r.maxX - 1
        cg.fill(CGRect(x: ruleX, y: r.minY, width: 1, height: r.height))
    }

    /// The x range (user space) where `draw` fills the whole body height opaquely, past the rounded ends with 1 pt to
    /// spare (antialiased curve), and the body's y range: what lies under it there is never seen. Nil when there is none.
    static func opaqueMiddle(rect: CGRect, visible: CGRect) -> (x: (CGFloat, CGFloat), y: (CGFloat, CGFloat))? {
        let body = rect.insetBy(dx: 0, dy: 1)
        guard body.width > 0, body.height > 0 else { return nil }
        let minX = max(body.minX, visible.minX - 8), maxX = min(body.maxX, visible.maxX + 8)
        let radius = min(Theme.Radius.small, body.height / 2)
        let a = minX + radius + 1, b = maxX - radius - 1
        return b > a ? ((a, b), (body.minY, body.maxY)) : nil
    }

    /// Off: always the whole-path drawing (tests compare both).
    static var usePixelCuts = true

    /// Body, name strip, trim hints and edge lines as whole rounded-rect paths: any CTM.
    private static func drawChrome(cg: CGContext, body: CGRect, drawn: CGRect, radius: CGFloat, strip: CGFloat, tall: Bool,
                                   colors: Colors, isSelected: Bool) {
        cg.setFillColor(colors.fill)
        cg.addPath(outlinePath(drawn, radius: radius)); cg.fillPath()
        if isSelected { drawTrimHints(cg: cg, body: body, drawn: drawn) }

        // Edge line, then the 2 pt selection border on top.
        cg.setStrokeColor(colors.edge)
        let ew = edgeWidth(cg)
        cg.setLineWidth(ew)
        cg.addPath(edgePath(drawn, radius: radius, width: ew)); cg.strokePath()
        if isSelected {
            cg.setStrokeColor(selectCG)
            cg.setLineWidth(2)
            cg.addPath(selectPath(drawn, radius: radius)); cg.strokePath()
        }
    }

    static func outlinePath(_ drawn: CGRect, radius: CGFloat) -> CGPath {
        CGPath(roundedRect: drawn, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    static func stripPath(_ drawn: CGRect, radius: CGFloat, strip: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: drawn.minX, y: drawn.minY + strip))
        p.addLine(to: CGPoint(x: drawn.minX, y: drawn.minY + radius))
        p.addArc(tangent1End: CGPoint(x: drawn.minX, y: drawn.minY), tangent2End: CGPoint(x: drawn.minX + radius, y: drawn.minY), radius: radius)
        p.addLine(to: CGPoint(x: drawn.maxX - radius, y: drawn.minY))
        p.addArc(tangent1End: CGPoint(x: drawn.maxX, y: drawn.minY), tangent2End: CGPoint(x: drawn.maxX, y: drawn.minY + radius), radius: radius)
        p.addLine(to: CGPoint(x: drawn.maxX, y: drawn.minY + strip))
        p.closeSubpath()
        return p
    }

    static func edgePath(_ drawn: CGRect, radius: CGFloat, width: CGFloat = edgeLineWidth) -> CGPath {
        CGPath(roundedRect: drawn.insetBy(dx: width / 2, dy: width / 2), cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    static func selectPath(_ drawn: CGRect, radius: CGFloat) -> CGPath {
        let r = max(radius - 1, 0)
        return CGPath(roundedRect: drawn.insetBy(dx: 1, dy: 1), cornerWidth: r, cornerHeight: r, transform: nil)
    }

    /// The same chrome as `drawChrome`, cut at two vertical device-pixel boundaries `left`/`right` past the rounded ends: the
    /// two ends are small paths, the long middle is plain rects. CoreGraphics' antialiased fill costs per pixel of a path's
    /// bounding box (a clip does not shrink that), so a whole-clip rounded rect cost 4x a rect fill at 2x. The ends are the
    /// whole path's own segments (same curves) up to the cut and the pieces never share a pixel, so each pixel gets the
    /// whole path's coverage up to a few levels of antialiasing at the corners (TimelineFastDrawTests: at most 3 of 255).
    /// Horizontal edges may lie off the pixel grid (rows of a fitted track height sit at quarter points): the middle rects
    /// are filled by `fillRect`, which gives their partly covered rows the path fill's coverage.
    /// Nil or false (use `drawChrome`) for a rotated CTM, a fractional scale or a clip too short to cut.
    @MainActor struct PixelCuts {
        let left: CGFloat, right: CGFloat
        /// Device row = `rowScale * y + rowOrigin`.
        let rowScale: CGFloat, rowOrigin: CGFloat

        init?(_ t: CGAffineTransform, drawn: CGRect, radius: CGFloat, strip: CGFloat?) {
            guard t.b == 0, t.c == 0, t.a > 0, t.d != 0, abs(abs(t.a) - abs(t.d)) < 1e-9 else { return nil }
            guard abs(t.a - t.a.rounded()) < 1e-9 else { return nil }
            let l = ((t.a * (drawn.minX + radius + 0.5) + t.tx).rounded(.up) - t.tx) / t.a
            let r = ((t.a * (drawn.maxX - radius - 0.5) + t.tx).rounded(.down) - t.tx) / t.a
            guard r > l else { return nil }
            left = l; right = r
            rowScale = t.d; rowOrigin = t.ty
        }

        /// `rect` filled as the antialiased path fill fills it: the whole device rows inside it by a plain rect fill, the
        /// partly covered rows at its top and bottom as thin path fills. CoreGraphics' rect fill rounds an edge a hair off
        /// the pixel grid to the whole row, where the path fill (and so the whole-path drawing) leaves it almost empty.
        func fillRect(_ cg: CGContext, _ rect: CGRect) {
            guard !rect.isEmpty else { return }
            func y(_ row: CGFloat) -> CGFloat { (row - rowOrigin) / rowScale }
            let ra = rowScale * rect.minY + rowOrigin, rb = rowScale * rect.maxY + rowOrigin
            let lo = min(ra, rb), hi = max(ra, rb)
            func integral(_ v: CGFloat) -> Bool { abs(v - v.rounded()) < 1e-6 }
            if integral(lo), integral(hi) { cg.fill(rect); return }
            let inLo = integral(lo) ? lo.rounded() : lo.rounded(.up), inHi = integral(hi) ? hi.rounded() : hi.rounded(.down)
            guard inHi > inLo else { cg.addRect(rect); cg.fillPath(); return }
            let ya = y(inLo), yb = y(inHi)
            let inner = CGRect(x: rect.minX, y: min(ya, yb), width: rect.width, height: abs(yb - ya))
            cg.fill(inner)
            if inner.minY > rect.minY { cg.addRect(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: inner.minY - rect.minY)); cg.fillPath() }
            if rect.maxY > inner.maxY { cg.addRect(CGRect(x: rect.minX, y: inner.maxY, width: rect.width, height: rect.maxY - inner.maxY)); cg.fillPath() }
        }

        /// One path segment. Nonisolated, like the cutting below: pure geometry, called a few times per clip per frame
        /// (main-actor isolation made every call and every path-element callback check the executor).
        nonisolated enum Seg {
            case line(CGPoint, CGPoint), quad(CGPoint, CGPoint, CGPoint), cubic(CGPoint, CGPoint, CGPoint, CGPoint)
            var start: CGPoint {
                switch self {
                case let .line(a, _): a
                case let .quad(a, _, _): a
                case let .cubic(a, _, _, _): a
                }
            }
            /// How many of the segment's points satisfy `f`, and how many points it has.
            func count(_ f: (CGFloat) -> Bool) -> (inside: Int, of: Int) {
                func n(_ p: CGPoint) -> Int { f(p.x) ? 1 : 0 }
                switch self {
                case let .line(a, b): return (n(a) + n(b), 2)
                case let .quad(a, b, c): return (n(a) + n(b) + n(c), 3)
                case let .cubic(a, b, c, d): return (n(a) + n(b) + n(c) + n(d), 4)
                }
            }
        }

        /// `path`'s one subpath as segments, the closing line included.
        nonisolated static func segments(_ path: CGPath) -> [Seg] {
            var out: [Seg] = []
            out.reserveCapacity(12)
            var cur = CGPoint.zero, first = CGPoint.zero
            path.applyWithBlock { e in
                let p = e.pointee.points
                switch e.pointee.type {
                case .moveToPoint: cur = p[0]; first = p[0]
                case .addLineToPoint: out.append(.line(cur, p[0])); cur = p[0]
                case .addQuadCurveToPoint: out.append(.quad(cur, p[0], p[1])); cur = p[1]
                case .addCurveToPoint: out.append(.cubic(cur, p[0], p[1], p[2])); cur = p[2]
                case .closeSubpath: if cur != first { out.append(.line(cur, first)) }; cur = first
                @unknown default: break
                }
            }
            return out
        }

        /// The part of a path (its `segments`) on one side of x = `cut` (`leftSide`: x <= cut) as one open run of the
        /// path's own segments (lines crossing the cut are cut there), closed along the cut for a fill. Nil when a curve
        /// crosses the cut or the part is not one run.
        nonisolated static func end(_ segs: [Seg], cut: CGFloat, leftSide: Bool, close: Bool) -> CGPath? {
            func inside(_ x: CGFloat) -> Bool { leftSide ? x <= cut + 1e-9 : x >= cut - 1e-9 }
            let n = segs.count
            guard n > 0 else { return nil }
            // `Seg?` is a trivial type (points only): the buffer needs no deinitialization.
            return withUnsafeTemporaryAllocation(of: Seg?.self, capacity: n) { kept -> CGPath? in
                for (i, s) in segs.enumerated() {
                    let k = s.count(inside)
                    if k.inside == k.of { kept.initializeElement(at: i, to: s); continue }
                    if k.inside == 0 { kept.initializeElement(at: i, to: nil); continue }
                    guard case let .line(a, b) = s, a.x != b.x else { return nil }
                    let c = CGPoint(x: cut, y: a.y + (b.y - a.y) * (cut - a.x) / (b.x - a.x))
                    kept.initializeElement(at: i, to: inside(a.x) ? .line(a, c) : .line(c, b))
                }
                guard let begin = (0..<n).first(where: { kept[$0] != nil && kept[($0 + n - 1) % n] == nil }) else { return nil }
                var count = 0
                while count < n, kept[(begin + count) % n] != nil { count += 1 }
                for j in count..<n where kept[(begin + j) % n] != nil { return nil }
                guard let first = kept[begin] else { return nil }
                let p = CGMutablePath()
                p.move(to: first.start)
                for j in 0..<count {
                    switch kept[(begin + j) % n]! {
                    case let .line(_, b): p.addLine(to: b)
                    case let .quad(_, b, c): p.addQuadCurve(to: c, control: b)
                    case let .cubic(_, b, c, d): p.addCurve(to: d, control1: b, control2: c)
                    }
                }
                if close { p.closeSubpath() }
                return p
            }
        }

        /// Both ends of `path` (parsed once), or nil when it cannot be cut.
        private func ends(_ path: CGPath?, close: Bool) -> (CGPath, CGPath)? {
            guard let path else { return nil }
            let segs = Self.segments(path)
            guard let a = Self.end(segs, cut: left, leftSide: true, close: close),
                  let b = Self.end(segs, cut: right, leftSide: false, close: close) else { return nil }
            return (a, b)
        }

        /// The whole chrome as `drawChrome` draws it; false (nothing drawn) when a shape cannot be cut.
        func draw(_ cg: CGContext, body: CGRect, drawn: CGRect, radius: CGFloat, strip: CGFloat, tall: Bool, fill: CGColor,
                  edge: CGColor, isSelected: Bool) -> Bool {
            let ew = ClipDrawing.edgeWidth(cg)
            guard let outline = ends(ClipDrawing.outlinePath(drawn, radius: radius), close: true),
                  let edgeEnds = ends(ClipDrawing.edgePath(drawn, radius: radius, width: ew), close: false) else { return false }
            let selectEnds = isSelected ? ends(ClipDrawing.selectPath(drawn, radius: radius), close: false) : nil
            guard !isSelected || selectEnds != nil else { return false }
            let w = right - left
            // Separate fills and strokes per end: one path of both ends costs their joint bounding box.
            func fillEnds(_ e: (CGPath, CGPath), middle: CGRect, color: CGColor) {
                cg.setFillColor(color)
                cg.addPath(e.0); cg.fillPath()
                cg.addPath(e.1); cg.fillPath()
                fillRect(cg, middle)
            }
            // Open ends with butt caps at the cuts; the straight top and bottom runs between them as rect fills.
            func strokeEnds(_ e: (CGPath, CGPath), inset: CGFloat, lineWidth lw: CGFloat, color: CGColor) {
                let d = drawn.insetBy(dx: inset, dy: inset)
                cg.saveGState()                          // the fill color and line cap stay as `drawChrome` leaves them
                cg.setStrokeColor(color)
                cg.setLineWidth(lw)
                cg.setLineCap(.butt)
                cg.addPath(e.0); cg.strokePath()
                cg.addPath(e.1); cg.strokePath()
                cg.setFillColor(color)
                fillRect(cg, CGRect(x: left, y: d.minY - lw / 2, width: w, height: lw))
                fillRect(cg, CGRect(x: left, y: d.maxY - lw / 2, width: w, height: lw))
                cg.restoreGState()
                cg.setStrokeColor(color)
                cg.setLineWidth(lw)
            }
            fillEnds(outline, middle: CGRect(x: left, y: drawn.minY, width: w, height: drawn.height), color: fill)
            if isSelected { ClipDrawing.drawTrimHints(cg: cg, body: body, drawn: drawn) }
            strokeEnds(edgeEnds, inset: ew / 2, lineWidth: ew, color: edge)
            if let selectEnds { strokeEnds(selectEnds, inset: 1, lineWidth: 2, color: ClipDrawing.selectCG) }
            return true
        }
    }

    /// Touches the lazily built statics (colors, clip font, shaping) so the first draw after opening a project does not pay for them.
    @MainActor public static func prewarm() {
        _ = colorCache[.video]; _ = offlineColors; _ = selectCG
        _ = line(for: "Clip")
    }

    /// The waveform area inside a clip's full rectangle (also where the volume line moves).
    nonisolated public static func waveformRect(in rect: CGRect) -> CGRect { ClipBodyMetrics.waveformRect(in: rect) }

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
        cg.setFillColor(Theme.TimelineSkin.waveform.cgColor)
        var snapped = wave
        snapped.origin.x = WaveformMask.snappedX(wave.minX, ctm: cg.ctm)    // columns on whole device pixels, as everywhere
        cg.addPath(WaveformPath.path(columns: columns, rect: snapped, style: style, firstColumn: from))
        cg.fillPath()
    }

    /// "Out of sync" badge: frames the linked partner has drifted ("+3" / "-3"), red on the clip's left edge.
    public static func drawSyncBadge(frames: Int64, rect: CGRect, visible: CGRect) {
        guard let cg = NSGraphicsContext.current?.cgContext, frames != 0, rect.width >= 24 else { return }
        let text = (frames > 0 ? "+" : "\u{2212}") + String(abs(frames))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: Theme.Typography.captionStrong, .foregroundColor: Theme.Colors.onClip]))
        let w = CTLineGetTypographicBounds(line, nil, nil, nil) + 8
        let x = max(rect.minX, visible.minX) + 3
        let y = rect.minY + (rect.height >= bodyMinHeight ? nameStripHeight + 3 : 2)
        let pill = CGRect(x: x, y: y, width: w, height: 12)
        guard pill.maxX < rect.maxX else { return }
        cg.saveGState()
        cg.setFillColor(Theme.Colors.red.cgColor)
        cg.addPath(CGPath(roundedRect: pill, cornerWidth: Theme.Radius.small, cornerHeight: Theme.Radius.small, transform: nil)); cg.fillPath()
        cg.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        cg.textPosition = CGPoint(x: pill.minX + 4, y: pill.minY + 9)
        CTLineDraw(line, cg)
        cg.restoreGState()
    }

    /// The volume rubber band over the waveform: a thin line with a diamond on every key.
    public static func drawVolumeLine(clip: Clip, rect: CGRect, visible: CGRect, selected: Bool, hiddenHandles: Set<FadeHandle> = [],
                                      selectedKeys: Set<UUID> = []) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        let pts = VolumeLine.points(clip: clip, clipRect: rect, visible: visible)
        guard pts.count >= 2 else { return }
        cg.saveGState()
        cg.clip(to: visible.intersection(rect))
        cg.setLineWidth(1)
        cg.setStrokeColor(Theme.OnPicture.clipBadgeEdge.cgColor)
        cg.addLines(between: pts.map { CGPoint(x: $0.x, y: $0.y + 1) }); cg.strokePath()
        cg.setStrokeColor((selected ? Theme.OnPicture.clipBadgeFill : Theme.OnPicture.clipBadgeFill.withAlphaComponent(0.75)).cgColor)
        cg.addLines(between: pts); cg.strokePath()
        cg.setFillColor(Theme.OnPicture.clipBadgeFill.cgColor)
        cg.setStrokeColor(Theme.OnPicture.clipBadgeEdge.cgColor)
        let keyIDs = clip.animation.volume.track.keys.map(\.id)
        for (i, k) in VolumeLine.keyPoints(clip: clip, clipRect: rect).enumerated() where k.x >= visible.minX - 4 && k.x <= visible.maxX + 4 {
            cg.setFillColor((selectedKeys.contains(keyIDs[i]) ? Theme.Colors.keyframeSelected : Theme.OnPicture.clipBadgeFill).cgColor)
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
            for (which, c) in [(FadeHandle.head, h.head), (FadeHandle.tail, h.tail)] where !hiddenHandles.contains(which) {
                let r = CGRect(x: c.x - size / 2, y: c.y - size / 2, width: size, height: size)
                let path = CGPath(roundedRect: r, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)
                cg.setFillColor((selected ? Theme.OnPicture.clipBadgeFill : Theme.OnPicture.clipBadgeFill.withAlphaComponent(0.7)).cgColor)
                cg.addPath(path); cg.fillPath()
                cg.setStrokeColor(Theme.OnPicture.clipBadgeEdge.cgColor)
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
            cg.setFillColor(Theme.Colors.clipShade.cgColor)
            cg.fill(bar)
            let gripH = min(body.height - 6, 8)
            if gripH > 2 {
                cg.setFillColor(Theme.Colors.label2.cgColor)
                cg.fill(CGRect(x: bar.midX - 0.5, y: bar.midY - gripH / 2, width: 1, height: gripH))
            }
        }
    }
}
