import Accelerate
import CoreGraphics
import Foundation

/// FB-Q: waveforms of one track row composited as one 8-bit coverage mask instead of a CoreGraphics path fill. The CG fill of
/// a frame's ~50k outline points was 3.7 ms of a 7.5 ms zoom step at 1x (more at 2x); here every column is a few `memset`s,
/// the mask is turned upright by vImage and source-over blended by vImage straight into the bitmap the timeline's content
/// cache draws into (any other context: one CoreGraphics masked fill). No per-pixel Swift loop, so a Debug build is fast too.
///
/// Not Metal: the timeline content is a CPU bitmap (shifted on scroll, copied per frame); GPU waveforms would need the
/// whole content cache on the GPU first.
///
/// The mask is kept transposed while it is written (one device pixel column = one contiguous run of bytes), so a waveform
/// column is a `memset` plus its two antialiased edge bytes: the covered fraction of the top and bottom pixel, which is what an
/// antialiased fill of `WaveformPath.path` gives. Column edges snap to whole device pixels (`snappedX`), so neighboring
/// columns never share a pixel; every other drawing path snaps the same way.
final class WaveformMask {
    /// Device region of the current row: pixel columns `x0..<x0+width`, rows (top down) `row0..<row0+height`.
    private var x0 = 0, row0 = 0, width = 0, height = 0
    /// Device pixels per user unit; device x = `originX + scale * x`, row (top down) = `originRow + rowScale * y`.
    private var scale: CGFloat = 1, originX: CGFloat = 0, originRow: CGFloat = 0, rowScale: CGFloat = 1
    private var transposed: UnsafeMutablePointer<UInt8>?
    private var upright: UnsafeMutablePointer<UInt8>?
    private var capacity = 0
    private var active = false
    /// The row's color; the mask holds coverage times its alpha (premultiplied, so the bitmap blend is one plain pass).
    private var color = CGColor(gray: 1, alpha: 1)
    private var level: CGFloat = 1
    /// Rows (relative, top down) touched per strip of `strip` device columns: `top..<bottom`, empty when top >= bottom.
    private var stripTop: UnsafeMutablePointer<Int>?, stripBottom: UnsafeMutablePointer<Int>?
    private var stripCapacity = 0
    static let strip = 64
    /// Strips blended in one vImage call at most (wide enough for long rows of bitmap writes, narrow enough that the
    /// union of their touched rows stays tight).
    static let stripsPerBlend = 8
    private var drawn = false

    /// Largest mask (bytes) a row may use; a bigger region (absurd zoom of the view itself) falls back to the path fill.
    static let maxBytes = 64 << 20

    deinit {
        transposed?.deallocate()
        upright?.deallocate()
        stripTop?.deallocate()
        stripBottom?.deallocate()
        colorBuffer?.deallocate()
    }

    /// `x` moved onto the nearest device pixel edge (unchanged for a rotated or skewed CTM). A tie (half a pixel, e.g. a panel
    /// at a .25 pt origin on a 2x screen) always goes right, whatever rounding error the two ways to the same point carry
    /// (the content cache's bitmap and a direct draw must agree).
    static func snappedX(_ x: CGFloat, ctm t: CGAffineTransform) -> CGFloat {
        guard t.b == 0, t.c == 0, t.a > 0 else { return x }
        return ((t.a * x + t.tx + 0.5 + 1e-4).rounded(.down) - t.tx) / t.a
    }

    /// Starts a row: `band` is the area waveforms may cover (user space), `ctm` the context's. False (nothing started) for a
    /// rotated or skewed CTM or an empty or oversized region: the caller fills paths instead.
    func begin(band: CGRect, ctm t: CGAffineTransform, color: CGColor) -> Bool {
        active = false; drawn = false
        guard t.b == 0, t.c == 0, t.a > 0, abs(abs(t.a) - abs(t.d)) < 1e-9, !band.isEmpty, band.width.isFinite, band.height.isFinite
        else { return false }
        scale = t.a; originX = t.tx
        // Rows counted top down (in the direction user y grows when the space is flipped).
        rowScale = -t.d; originRow = -t.ty
        let xa = (originX + scale * band.minX).rounded(.down), xb = (originX + scale * band.maxX).rounded(.up)
        let ra = originRow + rowScale * band.minY, rb = originRow + rowScale * band.maxY
        let ya = min(ra, rb).rounded(.down), yb = max(ra, rb).rounded(.up)
        guard xb > xa, yb > ya, (xb - xa) * (yb - ya) <= CGFloat(Self.maxBytes) else { return false }
        x0 = Int(xa); width = Int(xb - xa); row0 = Int(ya); height = Int(yb - ya)
        let n = width * height
        if n > capacity {
            transposed?.deallocate(); upright?.deallocate()
            capacity = max(n, capacity * 3 / 2)
            transposed = .allocate(capacity: capacity)
            upright = .allocate(capacity: capacity)
        }
        transposed?.update(repeating: 0, count: n)
        let strips = (width + Self.strip - 1) / Self.strip
        if strips > stripCapacity {
            stripTop?.deallocate(); stripBottom?.deallocate()
            stripCapacity = strips
            stripTop = .allocate(capacity: strips)
            stripBottom = .allocate(capacity: strips)
        }
        stripTop?.update(repeating: height, count: strips)
        stripBottom?.update(repeating: 0, count: strips)
        self.color = color
        level = min(max(color.alpha, 0), 1)
        active = true
        return true
    }

    /// Adds `columns` (as laid out by `WaveformPath.path`: column `i` at `rect.minX + firstColumn + i`, 1 unit wide).
    func add(columns: [[WaveformColumn]], rect: CGRect, style: WaveformStyle, firstColumn: Int = 0) {
        guard active, let buf = transposed, let stripTop, let stripBottom else { return }
        let h = height, full = Self.byte(level), level = level
        for (lane, laneRect) in WaveformPath.laneRects(rect, lanes: columns.count).enumerated() where lane < columns.count {
            let laneCols = columns[lane]
            for i in laneCols.indices {
                let x = rect.minX + CGFloat(firstColumn + i)
                guard x >= rect.minX, x + 1 <= rect.maxX + 0.001 else { continue }
                let (top, bottom) = WaveformPath.yRange(laneCols[i], laneRect, style)
                if bottom - top < 0.5 { continue }
                let px0 = max(Int((originX + scale * x).rounded()) - x0, 0)
                let px1 = min(Int((originX + scale * (x + 1)).rounded()) - x0, width)
                guard px0 < px1 else { continue }
                let ra = originRow + rowScale * top - CGFloat(row0), rb = originRow + rowScale * bottom - CGFloat(row0)
                let lo = max(min(ra, rb), 0), hi = min(max(ra, rb), CGFloat(h))
                guard hi > lo else { continue }
                // Whole rows lo'..<hi' get 255; the partly covered rows at either end their covered fraction.
                let fullFrom = Int(lo.rounded(.up)), fullTo = Int(hi.rounded(.down))
                let topRow = Int(lo.rounded(.down)), bottomRow = Int(hi.rounded(.up)) - 1
                var topValue: UInt8 = 0, bottomValue: UInt8 = 0
                if topRow == bottomRow {
                    topValue = Self.byte((hi - lo) * level)
                } else {
                    if topRow < fullFrom { topValue = Self.byte((CGFloat(fullFrom) - lo) * level) }
                    if bottomRow >= fullTo { bottomValue = Self.byte((hi - CGFloat(fullTo)) * level) }
                }
                for k in (px0 / Self.strip)...((px1 - 1) / Self.strip) {
                    stripTop[k] = min(stripTop[k], topRow)
                    stripBottom[k] = max(stripBottom[k], bottomRow + 1)
                }
                for px in px0..<px1 {
                    // Rows are stored bottom up in the transposed buffer, so the vImage rotation lands them top down.
                    let col = buf + px * h
                    if fullTo > fullFrom { (col + (h - fullTo)).update(repeating: full, count: fullTo - fullFrom) }
                    if topRow == bottomRow {
                        col[h - 1 - topRow] = max(col[h - 1 - topRow], topValue)
                    } else {
                        if topRow < fullFrom { col[h - 1 - topRow] = max(col[h - 1 - topRow], topValue) }
                        if bottomRow >= fullTo { col[h - 1 - bottomRow] = max(col[h - 1 - bottomRow], bottomValue) }
                    }
                }
                drawn = true
            }
        }
    }

    private static func byte(_ cover: CGFloat) -> UInt8 { UInt8(min(max((cover * 255).rounded(), 0), 255)) }

    /// Blends the row's mask in `color` over `cg` (whose CTM is the one `begin` saw) and ends the row.
    func flush(in cg: CGContext) { finish(in: cg)?.run() }

    /// A row's bitmap blend, ready to run on any thread: it touches only the mask's own buffers and the bitmap rows of its
    /// band, so the rows of a frame (disjoint bands) blend at once while the context is not drawn into.
    struct Blend: @unchecked Sendable {
        fileprivate let mask: WaveformMask
        fileprivate let target: BitmapTarget
        func run() { mask.blendStrips(into: target) }
    }

    /// Ends the row. Into a bitmap in a layout the blend writes directly: returns the blend for the caller to `run` before
    /// anything else is drawn over the band. Any other context: drawn now through CoreGraphics, nil.
    func finish(in cg: CGContext) -> Blend? {
        defer { active = false; drawn = false }
        guard active, drawn, let dst = upright else { return nil }
        guard let target = BitmapTarget(cg, color: color, mask: self), stripTop != nil, stripBottom != nil else {
            // The CoreGraphics fallback needs the whole mask upright.
            let strips = (width + Self.strip - 1) / Self.strip
            for k in 0..<strips { guard rotate(strip: k, rows: 0..<height) else { return nil } }
            drawFallback(in: cg, color: color.copy(alpha: 1) ?? color, mask: dst)
            return nil
        }
        directBlends += 1
        return Blend(mask: self, target: target)
    }

    /// Turned upright in strips of device columns (one strip's source and destination stay in cache: a whole 2x row
    /// rotated at once was 10x slower per pixel than at 1x).
    private func rotate(strip k: Int, rows: Range<Int>) -> Bool {
        guard let src = transposed, let dst = upright else { return false }
        let c = k * Self.strip, n = min(Self.strip, width - c)
        // Upright rows a..<b are the transposed bytes height-b..<height-a of each column.
        var s = vImage_Buffer(data: src + c * height + (height - rows.upperBound), height: vImagePixelCount(n),
                              width: vImagePixelCount(rows.count), rowBytes: height)
        var d = vImage_Buffer(data: dst + rows.lowerBound * width + c, height: vImagePixelCount(rows.count),
                              width: vImagePixelCount(n), rowBytes: width)
        return vImageRotate90_Planar8(&s, &d, UInt8(kRotate90DegreesCounterClockwise), 0, vImage_Flags(kvImageDoNotTile)) == kvImageNoError
    }

    /// The bitmap blend: only runs of touched strips, over the rows they touch.
    private func blendStrips(into target: BitmapTarget) {
        guard let tops = stripTop, let bottoms = stripBottom else { return }
        let strips = (width + Self.strip - 1) / Self.strip
        var k = 0
        while k < strips {
            guard bottoms[k] > tops[k] else { k += 1; continue }
            var end = k, top = tops[k], bottom = bottoms[k]
            while end + 1 < strips, end + 1 - k < Self.stripsPerBlend, bottoms[end + 1] > tops[end + 1] {
                end += 1
                top = min(top, tops[end]); bottom = max(bottom, bottoms[end])
            }
            for j in k...end { guard rotate(strip: j, rows: top..<bottom) else { return } }
            guard blend(into: target, columns: (k * Self.strip)..<min((end + 1) * Self.strip, width), rows: top..<bottom) else { return }
            k = end + 1
        }
    }

    /// The mask filled in `color` through CoreGraphics (any context).
    private func drawFallback(in cg: CGContext, color: CGColor, mask dst: UnsafeMutablePointer<UInt8>) {
        guard let provider = CGDataProvider(dataInfo: nil, data: dst, size: width * height, releaseData: { _, _, _ in }),
              let mask = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                                 space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                 provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return }
        // The region back in user space; CoreGraphics puts an image's first row at the rect's max y, so a top-down user
        // space (flipped view) is flipped about the rect for the draw.
        let ux0 = (CGFloat(x0) - originX) / scale, ux1 = (CGFloat(x0 + width) - originX) / scale
        let uya = (CGFloat(row0) - originRow) / rowScale, uyb = (CGFloat(row0 + height) - originRow) / rowScale
        let r = CGRect(x: ux0, y: min(uya, uyb), width: ux1 - ux0, height: abs(uyb - uya))
        cg.saveGState()
        if rowScale > 0 {
            cg.translateBy(x: 0, y: r.minY + r.maxY)
            cg.scaleBy(x: 1, y: -1)
        }
        cg.interpolationQuality = .none
        cg.clip(to: r, mask: mask)
        cg.setFillColor(color)
        cg.fill(r)
        cg.restoreGState()
    }

    /// The fast path: when `cg` draws into an 8-bit premultiplied RGB bitmap (the timeline's content cache), the mask is
    /// turned into premultiplied color pixels and source-over blended straight into the bitmap's bytes by vImage
    /// (CoreGraphics' masked fill was 1.3 ms of a 1x zoom step and 4.7 ms at 2x). Only the clip's bounding box is written,
    /// so the clip must be a rect (the content cache clips to whole-pixel rects). Nil: draw through CoreGraphics.
    fileprivate struct BitmapTarget {
        var data: UnsafeMutableRawPointer
        var bytesPerRow: Int
        /// Device columns and rows (`row` = bitmap row - bitmap height) that may be written: the bitmap and the clip.
        var columns: Range<Int>, rows: Range<Int>, bitmapHeight: Int
        /// White: the mask bytes are premultiplied white pixels already. Otherwise `matrix` scales them to the color per
        /// memory channel.
        var white: Bool, matrix: [Int16]

        init?(_ cg: CGContext, color: CGColor, mask m: WaveformMask) {
            guard let data = cg.data, cg.bitsPerComponent == 8, cg.bitsPerPixel == 32,
                  let space = cg.colorSpace, space.model == .rgb else { return nil }
            let t = cg.ctm
            guard t.b == 0, t.c == 0, t.a == m.scale, t.tx == m.originX, -t.d == m.rowScale, -t.ty == m.originRow else { return nil }
            let alphaInfo = cg.alphaInfo, order = cg.bitmapInfo.intersection(.byteOrderMask)
            // Memory channel order; alpha is the last byte either way.
            let bgra: Bool
            if alphaInfo == .premultipliedFirst, order == .byteOrder32Little {
                bgra = true
            } else if alphaInfo == .premultipliedLast, order == [] || order == .byteOrder32Big {
                bgra = false
            } else {
                return nil
            }
            guard let c = color.converted(to: space, intent: .defaultIntent, options: nil), let comps = c.components, comps.count == 4
            else { return nil }
            func q(_ v: CGFloat) -> Int16 { Int16(min(max((v * 256).rounded(), 0), 256)) }
            // Device pixels; a bitmap's first row is the top, at device y = height - 1, so bitmap row = height + row.
            let clip = cg.boundingBoxOfClipPath.applying(t)
            self.data = data
            bytesPerRow = cg.bytesPerRow
            bitmapHeight = cg.height
            let cx0 = max(0, Int(clip.minX.rounded())), cx1 = min(cg.width, Int(clip.maxX.rounded()))
            let r0 = max(-cg.height, Int((-clip.maxY).rounded())), r1 = min(0, Int((-clip.minY).rounded()))
            columns = cx0..<max(cx0, cx1)
            rows = r0..<max(r0, r1)
            white = comps[0] >= 0.999 && comps[1] >= 0.999 && comps[2] >= 0.999
            let first = bgra ? comps[2] : comps[0], third = bgra ? comps[0] : comps[2]
            matrix = [q(first), 0, 0, 0,  0, q(comps[1]), 0, 0,  0, 0, q(third), 0,  0, 0, 0, 256]
        }
    }

    private var colorBuffer: UnsafeMutablePointer<UInt8>?
    private var colorCapacity = 0
    /// Rows blended straight into a bitmap (tests).
    private(set) var directBlends = 0

    /// Blends the upright mask's `columns` x `rows` (relative to the row's region) into `target`. False: vImage failed.
    private func blend(into target: BitmapTarget, columns: Range<Int>, rows: Range<Int>) -> Bool {
        let cols = (columns.lowerBound + x0)..<(columns.upperBound + x0)
        let rws = (rows.lowerBound + row0)..<(rows.upperBound + row0)
        let cx = cols.clamped(to: target.columns), rx = rws.clamped(to: target.rows)
        guard !cx.isEmpty, !rx.isEmpty else { return true }
        let w = cx.count, h = rx.count
        if w * h * 4 > colorCapacity {
            colorBuffer?.deallocate()
            colorCapacity = max(w * h * 4, colorCapacity * 3 / 2)
            colorBuffer = .allocate(capacity: colorCapacity)
        }
        guard let pixels = colorBuffer, let cov = upright else { return false }
        var plane = vImage_Buffer(data: cov + (rx.lowerBound - row0) * width + (cx.lowerBound - x0), height: vImagePixelCount(h),
                                  width: vImagePixelCount(w), rowBytes: width)
        var px = vImage_Buffer(data: pixels, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
        var dest = vImage_Buffer(data: target.data + (target.bitmapHeight + rx.lowerBound) * target.bytesPerRow + cx.lowerBound * 4,
                                 height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: target.bytesPerRow)
        let none = vImage_Flags(kvImageDoNotTile)
        guard vImageConvert_Planar8toARGB8888(&plane, &plane, &plane, &plane, &px, none) == kvImageNoError else { return false }
        if !target.white {
            let bias: [Int32] = [128, 128, 128, 128]
            guard vImageMatrixMultiply_ARGB8888(&px, &px, target.matrix, 256, nil, bias, none) == kvImageNoError else { return false }
        }
        // Alpha is the last byte in both layouts; the color channels are blended alike.
        return vImagePremultipliedAlphaBlend_BGRA8888(&px, &dest, &dest, none) == kvImageNoError
    }
}
