#if canImport(Metal)
import CoreGraphics
import CoreVideo
import Foundation
import SQCore
import Synchronization

/// Rasterizes shape clips (W5.2) with Core Graphics into the compositor's linear premultiplied half-float format, the same
/// input text layers use (`RenderLayer.Content.linearPremultiplied`). The picture is `ShapeStyle.rasterSize` px, one px per
/// sequence px at scale 1, and is centered on the clip position, so Motion (scale, rotation, anchor) and the clip's effects
/// apply as to any layer. Colors are display-encoded (BT.709 OETF) like the solid and Drop Shadow colors and linearised
/// with the same inverse OETF.
public enum ShapeRenderer {
    /// A drawn shape: the buffer and the size in sequence px it covers (the buffer's own aspect; larger than the buffer
    /// when a huge shape was drawn scaled down, the compositor scales it up).
    public struct Picture: @unchecked Sendable {
        public let buffer: CVPixelBuffer
        public let width: Double, height: Double
    }

    /// Longest side of a raster in px. A larger shape is drawn scaled down (same aspect) and shown scaled up, so one
    /// raster stays at most 4096 x 4096 x 8 bytes (128 MB) instead of up to 2 GB.
    public static let maxSide = 4096
    /// Byte budget of the raster cache (least recently used rasters go first).
    public static let cacheBudget = 256 << 20

    /// Drawn pictures by style: a shape without keys is drawn once and reused every frame; a keyed shape uses one slot
    /// per clip while it animates (`ShapeRasterCache`). The buffers are never written after drawing, so sharing them
    /// across threads is safe.
    private static let cache = Mutex(ShapeRasterCache<Picture>(budget: cacheBudget))

    /// `kCVPixelFormatType_64RGBAHalf`, linear light, premultiplied, IOSurface-backed; nil when nothing is visible.
    public static func raster(_ style: ShapeStyle) -> CVPixelBuffer? { picture(style)?.buffer }

    /// The picture of `style`, from the cache or drawn now. `clip` lets a keyed (animating) shape reuse one slot.
    public static func picture(_ style: ShapeStyle, clip: Clip.ID? = nil) -> Picture? {
        guard !style.isEmpty else { return nil }
        if let hit = cache.withLock({ $0.lookup(style, clip: clip) }) { return hit }
        guard let p = draw(style) else { return nil }
        let bytes = CVPixelBufferGetBytesPerRow(p.buffer) * CVPixelBufferGetHeight(p.buffer)
        cache.withLock { $0.store(style, clip: clip, p, bytes: bytes) }
        return p
    }

    /// The layer for a shape generator request (effects and blend mode are attached by the caller's `applying`). A shape
    /// with nothing to draw (Shape effect off, no fill and no stroke, zero size) is an invisible layer.
    public static func layer(for r: LayerRequest) -> RenderLayer {
        guard let s = r.shape, let p = picture(s, clip: r.clip) else {
            var tr = r.transform; tr.opacity = 0
            return RenderLayer(content: .placeholder(.loading), transform: tr)
        }
        return RenderLayer(content: .linearPremultiplied(p.buffer, width: p.width, height: p.height), transform: r.transform)
    }

    // MARK: Drawing

    static func linear(_ e: Double) -> Double {
        e < 0.081242858 ? e / 4.5 : pow((e + 0.09929682680944) / 1.09929682680944, 1 / 0.45)
    }

    private static func cg(_ c: EffectColor, _ space: CGColorSpace) -> CGColor {
        let k = c.clamped
        return CGColor(colorSpace: space, components: [linear(k.red), linear(k.green), linear(k.blue), k.alpha].map { CGFloat($0) })!
    }

    /// Fills `path` with `fill`, or with the gradient from `fill` to `s.gradientEnd` across the path's bounds. The context is
    /// y up, the angle is y down.
    private static func fillPath(_ ctx: CGContext, _ path: CGPath, _ fill: EffectColor, _ s: ShapeStyle, _ space: CGColorSpace) {
        guard let end = s.gradientEnd,
              let gradient = CGGradient(colorsSpace: space, colors: [cg(fill, space), cg(end, space)] as CFArray, locations: [0, 1])
        else {
            ctx.addPath(path)
            ctx.setFillColor(cg(fill, space))
            ctx.fillPath()
            return
        }
        let b = path.boundingBoxOfPath
        let a = s.gradientAngle * .pi / 180
        let dx = cos(a), dy = -sin(a)
        let half = (abs(b.width * dx) + abs(b.height * dy)) / 2
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.drawLinearGradient(gradient, start: CGPoint(x: b.midX - dx * half, y: b.midY - dy * half),
                               end: CGPoint(x: b.midX + dx * half, y: b.midY + dy * half),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    private static func draw(_ s: ShapeStyle) -> Picture? {
        let size = s.rasterSize
        guard size.width > 0, size.height > 0 else { return nil }
        // Pixels per sequence px: 1, or less so the longest side fits `maxSide`.
        let k = min(1, Double(maxSide) / max(size.width, size.height))
        let w = min(max(Int((size.width * k).rounded(.up)), 1), maxSide)
        let h = min(max(Int((size.height * k).rounded(.up)), 1), maxSide)
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
                                      kCVPixelBufferMetalCompatibilityKey: true]
        var pb: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_64RGBAHalf, attrs as CFDictionary, &pb)
                == kCVReturnSuccess, let buffer = pb else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!, stride = CVPixelBufferGetBytesPerRow(buffer)
        memset(base, 0, stride * h)
        let space = CGColorSpace(name: CGColorSpace.linearSRGB)!
        let info = CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 16, bytesPerRow: stride,
                                  space: space, bitmapInfo: info) else { return nil }
        ctx.setShouldAntialias(true)
        ctx.scaleBy(x: k, y: k)
        // The box (in sequence px) may be up to 1 buffer px larger than the shape (rounded up): center the shape in it.
        let boxW = Double(w) / k, boxH = Double(h) / k
        let ox = (boxW - size.width) / 2, oy = (boxH - size.height) / 2
        let picture = Picture(buffer: buffer, width: boxW, height: boxH)

        // GFX freeform path: points in 0...1 of the outline box; open paths are only stroked (round caps and joins).
        if let pts = s.path {
            guard pts.count >= 2 else { return nil }
            let half = s.stroke == nil ? 0 : s.strokeWidth / 2
            // The bitmap context is y up; the points are y down.
            let p = CGMutablePath()
            p.addLines(between: pts.map { CGPoint(x: ox + half + $0.x * s.width, y: boxH - (oy + half + $0.y * s.height)) })
            if s.pathClosed { p.closeSubpath() }
            if let fill = s.fill, s.pathClosed { fillPath(ctx, p, fill, s, space) }
            if let stroke = s.stroke, s.strokeWidth > 0 {
                ctx.addPath(p); ctx.setStrokeColor(cg(stroke, space)); ctx.setLineWidth(s.strokeWidth)
                ctx.setLineJoin(.round); ctx.setLineCap(.round); ctx.strokePath()
            }
            return picture
        }

        if s.kind == .line {
            guard let stroke = s.stroke else { return nil }
            ctx.setFillColor(cg(stroke, space))
            ctx.fill(CGRect(x: ox, y: oy, width: s.width, height: s.strokeWidth))
            return picture
        }

        let half = s.stroke == nil ? 0 : s.strokeWidth / 2
        let rect = CGRect(x: ox + half, y: oy + half, width: s.width, height: s.height)
        let path: CGPath = switch s.kind {
        case .ellipse: CGPath(ellipseIn: rect, transform: nil)
        case .arrow:
            {
                let pts = s.arrowPoints.map { CGPoint(x: rect.minX + $0.x, y: rect.minY + $0.y) }
                let p = CGMutablePath()
                p.addLines(between: pts)
                p.closeSubpath()
                return p
            }()
        default:
            s.cornerRadius > 0
                ? CGPath(roundedRect: rect, cornerWidth: s.cornerRadius, cornerHeight: s.cornerRadius, transform: nil)
                : CGPath(rect: rect, transform: nil)
        }
        if let fill = s.fill { fillPath(ctx, path, fill, s, space) }
        if let stroke = s.stroke, s.strokeWidth > 0 {
            ctx.addPath(path)
            ctx.setStrokeColor(cg(stroke, space))
            ctx.setLineWidth(s.strokeWidth)
            ctx.setLineJoin(.round)
            ctx.strokePath()
        }
        return picture
    }
}

/// The shape raster cache policy (pure, so it is testable without drawing). Still shapes are kept by style, least
/// recently used first out, within a byte budget. A clip whose style changed since its last store is animating: its
/// pictures go to one slot of that clip, replaced every frame, so playback of a keyed shape does not churn the cache;
/// when the style holds (playback stopped), a lookup promotes the slot into the cache.
struct ShapeRasterCache<Value> {
    private struct Item { var value: Value; var bytes: Int }
    private var items: [ShapeStyle: Item] = [:]
    private var order: [ShapeStyle] = []                      // least recently used first
    private var lastStyle: [UUID: ShapeStyle] = [:]
    private var slots: [UUID: (style: ShapeStyle, item: Item)] = [:]
    let budget: Int
    private(set) var bytes = 0

    init(budget: Int) { self.budget = budget }

    /// Cached still shapes (the per-clip animation slots are not counted).
    var count: Int { items.count }

    mutating func lookup(_ style: ShapeStyle, clip: UUID?) -> Value? {
        if let hit = items[style] {
            touch(style)
            return hit.value
        }
        if let clip, let slot = slots[clip], slot.style == style {
            slots[clip] = nil
            bytes -= slot.item.bytes
            insert(style, slot.item)
            return slot.item.value
        }
        return nil
    }

    mutating func store(_ style: ShapeStyle, clip: UUID?, _ value: Value, bytes n: Int) {
        let item = Item(value: value, bytes: n)
        guard let clip else { insert(style, item); return }
        defer { lastStyle[clip] = style }
        if lastStyle.count > 1_024 { lastStyle.removeAll() }
        guard let last = lastStyle[clip], last != style else { insert(style, item); return }
        if let old = slots[clip] { bytes -= old.item.bytes }
        if slots.count >= 16, slots[clip] == nil { dropSlots() }
        slots[clip] = (style, item)
        bytes += n
        evict()
    }

    private mutating func touch(_ style: ShapeStyle) {
        if let i = order.firstIndex(of: style) { order.remove(at: i) }
        order.append(style)
    }

    private mutating func insert(_ style: ShapeStyle, _ item: Item) {
        guard item.bytes <= budget else { return }
        if let old = items[style] { bytes -= old.bytes }
        items[style] = item
        bytes += item.bytes
        touch(style)
        evict()
    }

    private mutating func dropSlots() {
        for s in slots.values { bytes -= s.item.bytes }
        slots.removeAll()
    }

    /// Oldest still shapes first; the animation slots only when nothing else is left.
    private mutating func evict() {
        while bytes > budget, !order.isEmpty {
            let s = order.removeFirst()
            if let it = items.removeValue(forKey: s) { bytes -= it.bytes }
        }
        if bytes > budget { dropSlots() }
    }
}
#endif
