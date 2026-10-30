import AppKit

/// Pixels of the timeline's content area (lanes, clips, waveforms, transitions; no playhead or gesture overlays) kept in
/// an offscreen bitmap at the destination's device resolution. A scroll by whole device pixels (horizontal, vertical or
/// both) moves the pixels (`memmove` per row) and re-renders only the exposed strips and the items whose picture depends on
/// the viewport's edges (clip names and badges stick to the left/right edge, ghost strips show only when they fit); the
/// frame is then one image copy. Anything else that changes the content invalidates it through `setNeedsDisplay` (a rect)
/// or `needsDisplay` (everything), and zoom re-renders it whole.
@MainActor
final class TimelineContentCache {
    /// Off for comparisons in tests (direct drawing, as before the cache).
    var isEnabled = true

    /// What the pixels were rendered for; any change but the scroll position re-renders everything.
    private struct Key: Equatable {
        var content: CGRect          // view space
        var device: CGRect           // destination device space
        var scale: CGFloat
        var colorSpace: String
        var bitmapInfo: UInt32
        var pointsPerSecond: Double
    }

    private var key: Key?
    private var scrollX: CGFloat = 0
    private var scrollY: CGFloat = 0
    private var buffer: PixelBuffer?
    private var context: CGContext?
    /// Pixel layout of the bitmap: the destination's when it is an 8-bit RGBA/BGRA bitmap (then a frame is a row copy),
    /// otherwise BGRA.
    private var bitmapInfo = TimelineContentCache.defaultBitmapInfo
    static let defaultBitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    /// Frames copied straight into the destination's bytes (tests).
    private(set) var directCopies = 0
    /// Zoom frames rendered straight into the destination (tests).
    private(set) var directRenders = 0
    /// Off: the bitmap stays BGRA and frames go out by an image draw (tests compare both).
    var fastOutput = true
    /// How the last frame went out (tests and diagnostics).
    private(set) var lastPath = ""
    private var loggedPath = false
    private var dirty: [CGRect] = []
    private var allDirty = true

    /// Content-area area re-rendered so far, in points² (tests).
    private(set) var renderedArea: CGFloat = 0
    /// Frames composed from the cache with a pixel shift (tests).
    private(set) var shifts = 0
    private var loggedRefusal = false

    static let maxDirtyRects = 128

    /// Sharp redraw after a zoom in motion, spread over frames: the 1x bitmap of the motion stays on screen, scaled up, and
    /// the full-scale bitmap fills in `sharpenStrips` vertical strips, one per frame. Off: one full redraw (as before).
    var sharpensProgressively = ProcessInfo.processInfo.environment["SQ_NO_PROGRESSIVE_SHARPEN"] == nil
    var sharpenStrips = 4
    /// True while the full-scale bitmap is still filling in; the view asks for the next frame.
    var isSharpening: Bool { sharpening != nil }
    /// Strips rendered by the progressive sharpening so far (tests).
    private(set) var sharpenedStrips = 0

    /// The soft bitmap shown until its strip is replaced, and what is left to render at full scale (content space).
    private struct Sharpening {
        var soft: Bitmap
        var pending: [CGRect]
        var done: [CGRect] = []
    }
    private struct Bitmap {
        var buffer: PixelBuffer
        var context: CGContext
        var bitmapInfo: UInt32
        var space: CGColorSpace
    }
    private var sharpening: Sharpening?

    /// Vertical strips of `content`, edges on whole device pixels.
    static func strips(of content: CGRect, scale: CGFloat, count: Int) -> [CGRect] {
        let total = (content.width * scale).rounded()
        let edges = (0...count).map { content.minX + (total * CGFloat($0) / CGFloat(count)).rounded() / scale }
        return (0..<count).map { CGRect(x: edges[$0], y: content.minY, width: edges[$0 + 1] - edges[$0], height: content.height) }
            .filter { $0.width > 0 }
    }

    func invalidateAll() { allDirty = true; dirty.removeAll(); sharpening = nil }

    func invalidate(_ rect: CGRect) {
        if sharpening != nil { invalidateAll(); return }          // strips already drawn would be stale: draw all at once
        guard !allDirty, !rect.isEmpty else { return }
        if dirty.contains(where: { $0.contains(rect) }) { return }
        if dirty.count >= Self.maxDirtyRects { allDirty = true; dirty.removeAll(); return }
        dirty.append(rect)
    }

    /// Brings the pixels up to date for `content` at `scrollX`/`scrollY`/`pointsPerSecond` and copies the part inside
    /// `clip` into `dest`. Returns false (nothing drawn) when the destination cannot be cached (rotated, fractional
    /// pixel grid); the caller then draws directly.
    ///
    /// - `canShift`: false while something drawn into the content depends on view coordinates (a drop target, a drag).
    /// - `edgeItems`: rects (view space) of everything whose picture depends on where the given viewports' edges are
    ///   (clip names and badges kept on screen, text clipped at the edge).
    /// - `render`: draws the content clipped to the given rect, into `NSGraphicsContext.current`, covering every pixel of it
    ///   (the stale pixels there are not cleared first).
    func draw(in dest: CGContext, content: CGRect, clip: CGRect, scrollX newScrollX: CGFloat, scrollY newScrollY: CGFloat,
              pointsPerSecond: Double, canShift: Bool, drawnRects: [CGRect] = [], edgeItems: ([CGRect]) -> [CGRect],
              scaleLimit: CGFloat? = nil, render: (CGRect) -> Void) -> Bool {
        guard isEnabled, content.width >= 1, content.height >= 1 else { return false }
        var t = dest.userSpaceToDeviceSpaceTransform
        // Zoom in motion: render into a bitmap of at most `scaleLimit` pixels per point and let the destination scale it up
        // (fewer pixels to fill). The direct-render and direct-copy shortcuts need the destination's own scale.
        var capped = false
        if let limit = scaleLimit, t.b == 0, t.c == 0, t.a > limit {
            let k = limit / t.a
            t = t.concatenating(CGAffineTransform(scaleX: k, y: k))
            capped = true
        }
        let fastOutput = self.fastOutput && !capped
        guard t.b == 0, t.c == 0, abs(abs(t.a) - abs(t.d)) < 1e-9, t.a > 0 else {
            if TimelinePerf.envEnabled, !loggedRefusal {
                loggedRefusal = true
                NSLog("TimelineContentCache: off for this context (CTM %@)", "\(t)")
            }
            return false
        }
        let scale = t.a
        // The bitmap covers `content` grown to whole device pixels (a fractional panel origin or width); the fringe outside
        // `content` is never copied out (`clip` lies inside `content`).
        let viewport = content
        let snappedDevice = content.applying(t).standardized
        let device = CGRect(x: snappedDevice.minX.rounded(.down), y: snappedDevice.minY.rounded(.down),
                            width: 0, height: 0)
            .union(CGRect(x: snappedDevice.maxX.rounded(.up), y: snappedDevice.maxY.rounded(.up), width: 0, height: 0))
        let content = device.applying(t.inverted()).standardized
        func integral(_ v: CGFloat) -> Bool { abs(v - v.rounded()) < 1e-6 }
        let space = dest.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let info = (fastOutput ? Self.matchingBitmapInfo(dest) : nil) ?? Self.defaultBitmapInfo
        let k = Key(content: content, device: device, scale: scale,
                    colorSpace: (space.name as String?) ?? "\(space)", bitmapInfo: info, pointsPerSecond: pointsPerSecond)

        // The end of a zoom in motion (only the scale grew, nothing else changed): keep the 1x bitmap on screen and fill the
        // full-scale one strip by strip. Any other change meanwhile (`invalidate*`, scroll, a new key) drops the strips.
        if sharpensProgressively, fastOutput, sharpening == nil, key != k, let old = key, let oldCtx = context, let oldBuf = buffer,
           !allDirty, dirty.isEmpty, old.scale < k.scale, old.pointsPerSecond == k.pointsPerSecond, old.content == k.content,
           old.colorSpace == k.colorSpace, scrollX == newScrollX, scrollY == newScrollY, sharpenStrips > 1,
           let oldSpace = oldCtx.colorSpace {
            let soft = Bitmap(buffer: oldBuf, context: oldCtx, bitmapInfo: bitmapInfo, space: oldSpace)
            if makeContext(width: Int(device.width.rounded()), height: Int(device.height.rounded()), space: space, bitmapInfo: info) {
                key = k
                sharpening = Sharpening(soft: soft, pending: Self.strips(of: content, scale: scale, count: sharpenStrips))
            }
        }
        if sharpening != nil, key != k { sharpening = nil }
        if sharpening == nil, key != k || context == nil {
            // A zoom step (only the zoom changed): the next frame re-renders everything again, so render straight into the
            // destination when its bytes take a row copy, instead of into the bitmap and copying it out. The bitmap stays
            // stale until a frame that does not zoom.
            var zoomOnly = key
            zoomOnly?.pointsPerSecond = k.pointsPerSecond
            if fastOutput, context != nil, zoomOnly == k, bitmapInfo == info, let cs = context?.colorSpace, dest.colorSpace == cs,
               let region = singleDirectRegion(dest: dest, device: device, clip: clip, drawnRects: drawnRects, transform: t) {
                key = k
                invalidateAll()
                scrollX = newScrollX
                scrollY = newScrollY
                let sp = TimelineSignpost.log.beginInterval("contentRender")
                defer { TimelineSignpost.log.endInterval("contentRender", sp) }
                dest.saveGState()
                dest.clip(to: region)
                render(region)
                dest.restoreGState()
                directRenders += 1
                logPath("direct render (zoom)")
                return true
            }
            if key?.device.size != k.device.size || key?.colorSpace != k.colorSpace || key?.bitmapInfo != k.bitmapInfo || context == nil {
                guard makeContext(width: Int(device.width.rounded()), height: Int(device.height.rounded()), space: space, bitmapInfo: info)
                else { return false }
            }
            key = k
            invalidateAll()
        } else if newScrollX != scrollX || newScrollY != scrollY, !allDirty {
            let dx = scrollX - newScrollX                        // content moves right by dx
            let dy = scrollY - newScrollY                        // content moves down by dy
            let px = dx * scale, py = dy * scale
            if sharpening == nil, canShift, integral(px), integral(py), abs(dx) < content.width, abs(dy) < content.height {
                shift(dx: Int(px.rounded()), dy: Int(py.rounded()))
                shifts += 1
                TimelineSignpost.log.emitEvent("contentShift")
                // Pending stale regions moved with the pixels (kept where they were too).
                for r in dirty { invalidate(r.offsetBy(dx: dx, dy: dy)) }
                let margin: CGFloat = 8
                if dx != 0 {
                    invalidate(dx > 0 ? CGRect(x: content.minX, y: content.minY, width: dx + margin, height: content.height)
                                      : CGRect(x: content.maxX + dx - margin, y: content.minY, width: -dx + margin, height: content.height))
                }
                if dy != 0 {
                    invalidate(dy > 0 ? CGRect(x: content.minX, y: content.minY, width: content.width, height: dy + margin)
                                      : CGRect(x: content.minX, y: content.maxY + dy - margin, width: content.width, height: -dy + margin))
                }
                // Items laid out against the old viewport (where it is now, in the new coordinates) or the new one.
                for r in edgeItems([viewport.offsetBy(dx: dx, dy: dy), viewport]) {
                    invalidate(r.intersection(content))
                }
            } else {
                invalidateAll()
            }
        }
        scrollX = newScrollX
        scrollY = newScrollY

        guard let cg = context, let buffer else { return false }
        let regions = sharpening.map { [$0.pending[0]] }
            ?? (allDirty ? [content] : Self.merged(dirty.map { snap($0.intersection(content), content: content, scale: scale) }))
        if !regions.isEmpty {
            let sp = TimelineSignpost.log.beginInterval("contentRender")
            defer { TimelineSignpost.log.endInterval("contentRender", sp) }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
            // View space (flipped, points) to the bitmap (first row = top of the content area).
            let toPixels = CGAffineTransform(translationX: 0, y: CGFloat(cg.height))
                .scaledBy(x: scale, y: -scale)
                .translatedBy(x: -content.minX, y: -content.minY)
            for r in regions {
                let snapped = snap(r, content: content, scale: scale)
                renderedArea += snapped.width * snapped.height
                cg.saveGState()
                cg.concatenate(toPixels)
                cg.clip(to: snapped)
                render(snapped)                              // paints every pixel of `snapped` (background included)
                cg.restoreGState()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        allDirty = false
        dirty.removeAll()
        if var s = sharpening {
            s.done.append(s.pending.removeFirst())
            sharpenedStrips += 1
            sharpening = s.pending.isEmpty ? nil : s
            if let s = sharpening {
                // The soft picture everywhere, the finished strips at full scale on top.
                guard drawImage(of: s.soft, into: dest, content: content, clip: clip, quality: .low) else { sharpening = nil; return false }
                let sharp = Bitmap(buffer: buffer, context: cg, bitmapInfo: bitmapInfo, space: space)
                for strip in s.done {
                    let part = clip.intersection(strip)
                    guard !part.isEmpty else { continue }
                    if !copyDirect(into: dest, from: cg, device: device, clip: part, drawnRects: drawnRects, transform: t) {
                        _ = drawImage(of: sharp, into: dest, content: content, clip: part, quality: .none)
                    }
                }
                return true
            }
        }

        if fastOutput, copyDirect(into: dest, from: cg, device: device, clip: clip, drawnRects: drawnRects, transform: t) {
            directCopies += 1
            return true
        }
        return drawImage(of: Bitmap(buffer: buffer, context: cg, bitmapInfo: bitmapInfo, space: space), into: dest, content: content,
                         clip: clip, quality: capped ? .low : .none)
    }

    /// The bitmap as an image over `content` (its first row is the top of the content area), clipped to `clip`.
    private func drawImage(of bitmap: Bitmap, into dest: CGContext, content: CGRect, clip: CGRect, quality: CGInterpolationQuality) -> Bool {
        let cg = bitmap.context
        guard let image = bitmap.buffer.image(width: cg.width, height: cg.height, bytesPerRow: cg.bytesPerRow, space: bitmap.space,
                                              bitmapInfo: bitmap.bitmapInfo)
        else { return false }
        dest.saveGState()
        dest.clip(to: clip)
        dest.interpolationQuality = quality
        dest.setBlendMode(.copy)
        // `content.minY` in the flipped view space; `draw` puts an image's first row at the rect's max y, hence the flip.
        dest.translateBy(x: content.minX, y: content.maxY)
        dest.scaleBy(x: 1, y: -1)
        dest.draw(image, in: CGRect(origin: .zero, size: content.size))
        dest.restoreGState()
        return true
    }

    /// Overlapping rects joined where the union costs no more than drawing both (old and new edge regions of a small
    /// scroll nearly coincide).
    static func merged(_ rects: [CGRect]) -> [CGRect] {
        var out = rects.filter { !$0.isEmpty }
        var changed = true
        while changed {
            changed = false
            outer: for i in out.indices {
                for j in out.indices where j > i {
                    // Only overlapping rects join (non-empty: containing implies overlapping); the cheap test first.
                    let a = out[i], b = out[j]
                    guard a.intersects(b) else { continue }
                    let u = a.union(b)
                    let overlap = a.intersection(b)
                    let cost = a.width * a.height + b.width * b.height - (overlap.isNull ? 0 : overlap.width * overlap.height)
                    if u.width * u.height <= cost * 1.05 + 1 {
                        out[i] = u
                        out.remove(at: j)
                        changed = true
                        break outer
                    }
                }
            }
        }
        return out
    }

    /// `r` grown to whole device pixels (the content origin is on the pixel grid).
    private func snap(_ r: CGRect, content: CGRect, scale: CGFloat) -> CGRect {
        let x0 = ((r.minX - content.minX) * scale).rounded(.down) / scale + content.minX
        let y0 = ((r.minY - content.minY) * scale).rounded(.down) / scale + content.minY
        let x1 = ((r.maxX - content.minX) * scale).rounded(.up) / scale + content.minX
        let y1 = ((r.maxY - content.minY) * scale).rounded(.up) / scale + content.minY
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0).intersection(content)
    }

    /// `dest`'s layout when it is an 8-bit, 32-bit-pixel premultiplied RGB bitmap the cache can render in too.
    static func matchingBitmapInfo(_ dest: CGContext) -> UInt32? {
        guard dest.data != nil, dest.bitsPerComponent == 8, dest.bitsPerPixel == 32, dest.colorSpace?.model == .rgb else { return nil }
        let alpha = dest.alphaInfo, order = dest.bitmapInfo.intersection(.byteOrderMask)
        if alpha == .premultipliedFirst, order == .byteOrder32Little { return alpha.rawValue | order.rawValue }
        if alpha == .premultipliedLast, order == [] || order == .byteOrder32Big { return alpha.rawValue | order.rawValue }
        return nil
    }

    /// The frame as plain row copies into `dest`'s bytes: same layout, color space and pixel grid, so the bytes are what
    /// the `.copy` image draw writes, without CoreGraphics' per-frame image decode (two copies, plus a color conversion
    /// when the layouts differ: a quarter of a 2x zoom step). Copies `clip` within each rect AppKit is drawing (`drawnRects`,
    /// empty: the clip is `clip` itself) and within the context's clip box. False: draw the image.
    private func copyDirect(into dest: CGContext, from cg: CGContext, device: CGRect, clip: CGRect, drawnRects: [CGRect],
                            transform t: CGAffineTransform) -> Bool {
        guard let dst = dest.data, let src = cg.data else { logPath("image draw (no bytes)"); return false }
        guard Self.matchingBitmapInfo(dest) == bitmapInfo else { logPath("image draw (layout \(dest.bitmapInfo.rawValue) vs \(bitmapInfo))"); return false }
        guard let ds = dest.colorSpace, let cs = cg.colorSpace, ds == cs else { logPath("image draw (color space)"); return false }
        guard let regions = Self.deviceRegions(dest: dest, device: device, clip: clip, drawnRects: drawnRects, transform: t) else {
            logPath("image draw (clip off the pixel grid)")
            return false
        }
        // Cache row 0 is the top of the content. A bitmap's device space runs top-down from its first row (t.d > 0: a
        // flipped view); bottom-up device rows (t.d < 0) count from the last row.
        let srcRow = cg.bytesPerRow, dstRow = dest.bytesPerRow
        let down = t.d > 0, top = Int(device.minY.rounded()), bottom = Int(device.maxY.rounded())
        for d in regions {
            let x0 = Int(d.minX.rounded()), x1 = Int(d.maxX.rounded()), y0 = Int(d.minY.rounded()), y1 = Int(d.maxY.rounded())
            let sx = (x0 - Int(device.minX.rounded())) * 4, n = (x1 - x0) * 4
            for y in y0..<y1 {
                let to = down ? y : dest.height - 1 - y, from = down ? y - top : bottom - 1 - y
                memcpy(dst + to * dstRow + x0 * 4, src + from * srcRow + sx, n)
            }
        }
        logPath("direct row copy")
        return true
    }

    /// The device rects (whole pixels, inside `device` and the bitmap) a frame writes: `clip` within each rect AppKit is
    /// drawing and within `dest`'s clip box. Nil when one is off the pixel grid.
    private static func deviceRegions(dest: CGContext, device: CGRect, clip: CGRect, drawnRects: [CGRect],
                                      transform t: CGAffineTransform) -> [CGRect]? {
        let box = dest.boundingBoxOfClipPath
        let bounds = CGRect(x: 0, y: 0, width: dest.width, height: dest.height)
        func integral(_ v: CGFloat) -> Bool { abs(v - v.rounded()) < 1e-6 }
        var regions: [CGRect] = []
        for r in drawnRects.isEmpty ? [clip] : drawnRects {
            let d = r.intersection(clip).intersection(box).applying(t).standardized.intersection(device).intersection(bounds)
            if d.isNull || d.isEmpty { continue }
            guard integral(d.minX), integral(d.minY), integral(d.maxX), integral(d.maxY) else { return nil }
            regions.append(d)
        }
        return regions
    }

    /// For a direct render: the one user-space rect a frame writes, when `dest` is a bitmap in the cache's layout and the
    /// frame is a single whole-pixel rect (the waveform blend writes the clip's bounding box, so it must be the clip).
    private func singleDirectRegion(dest: CGContext, device: CGRect, clip: CGRect, drawnRects: [CGRect],
                                    transform t: CGAffineTransform) -> CGRect? {
        guard dest.data != nil, Self.matchingBitmapInfo(dest) == bitmapInfo,
              let regions = Self.deviceRegions(dest: dest, device: device, clip: clip, drawnRects: drawnRects, transform: t),
              regions.count == 1 else { return nil }
        return regions[0].applying(t.inverted()).standardized
    }

    private func logPath(_ what: String) {
        lastPath = what
        guard TimelinePerf.envEnabled, !loggedPath else { return }
        loggedPath = true
        NSLog("TimelineContentCache: frames go out by %@", what)
    }

    private func makeContext(width: Int, height: Int, space: CGColorSpace, bitmapInfo info: UInt32) -> Bool {
        let bytesPerRow = width * 4
        let buf = PixelBuffer(count: bytesPerRow * height)
        guard let cg = CGContext(data: buf.bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: space,
                                 bitmapInfo: info)
        else { return false }
        bitmapInfo = info
        buffer = buf
        context = cg
        return true
    }

    /// Moves the pixels `px` to the right and `py` down (negative: left / up). Uncovered pixels keep stale data; they are
    /// dirty. Rows are copied in the order that never reads a row already overwritten.
    private func shift(dx px: Int, dy py: Int) {
        guard px != 0 || py != 0, let cg = context, let buffer else { return }
        let w = cg.width, h = cg.height, rowBytes = cg.bytesPerRow, n = (w - abs(px)) * 4
        guard n > 0, abs(py) < h else { return }
        let base = buffer.bytes
        let src = px > 0 ? 0 : -px * 4, dst = px > 0 ? px * 4 : 0
        func move(_ y: Int) { memmove(base + y * rowBytes + dst, base + (y - py) * rowBytes + src, n) }
        if py > 0 {
            for y in stride(from: h - 1, through: py, by: -1) { move(y) }
        } else {
            for y in 0..<(h + py) { move(y) }
        }
    }
}

/// The cache's pixels; the bitmap context draws into them and each frame's image reads them without a copy.
private final class PixelBuffer {
    let bytes: UnsafeMutableRawPointer
    let count: Int
    init(count: Int) {
        self.count = count
        bytes = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 64)
        bytes.initializeMemory(as: UInt8.self, repeating: 0, count: count)
    }
    deinit { bytes.deallocate() }

    func image(width: Int, height: Int, bytesPerRow: Int, space: CGColorSpace, bitmapInfo: UInt32) -> CGImage? {
        guard let provider = CGDataProvider(dataInfo: nil, data: bytes, size: count, releaseData: { _, _, _ in }) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
