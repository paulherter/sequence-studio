#if canImport(CoreVideo)
import CoreVideo
import Foundation
import SQCore
import SQRender
import Synchronization

/// The Mac side of the Lottie renderer (LottieDocument.swift): frames as CoreVideo buffers in the compositor's linear
/// premultiplied half-float format (`RenderLayer.Content.linearPremultiplied`, the input text and shape layers use).
/// Playback and export both call `layer(for:canvas:)`, so a frame is bit-identical in both: the animation frame is a pure
/// function of the clip time (`LottieTiming`), the raster size a pure function of the canvas, and ThorVG runs
/// single-threaded without SIMD. Rendered frames are cached (LRU by bytes), so a looping sticker or a scrub back over the
/// same frames costs one render each.
extension LottieRenderer {
    /// The layer for a Lottie generator request (effects and blend mode are attached by the caller's `applying`).
    /// An unreadable animation is the offline slate; a failed draw is invisible.
    public static func layer(for r: LayerRequest, canvas: SequenceFormat) -> RenderLayer {
        guard let g = r.generator, let doc = document(for: g, clip: r.clip) else {
            return RenderLayer(content: .placeholder(.offline), transform: r.transform, cornerRadius: r.cornerRadius)
        }
        let (frame, w, h) = placement(doc, r, canvas)
        guard let buffer = frameBuffer(doc, frame: frame, width: w, height: h) else {
            var tr = r.transform; tr.opacity = 0
            return RenderLayer(content: .placeholder(.loading), transform: tr)
        }
        return RenderLayer(content: .linearPremultiplied(buffer, width: Double(w), height: Double(h)),
                           transform: r.transform)
    }

    // MARK: Frames

    /// Pixel buffers are never written after drawing, so sharing them across threads is safe.
    private struct Buf: @unchecked Sendable { let pb: CVPixelBuffer }

    private struct FrameCache {
        var budget: Int
        var entries: [FrameKey: (buffer: Buf, bytes: Int, used: UInt64)] = [:]
        var bytes = 0, tick: UInt64 = 0
        init(budget: Int) { self.budget = budget }
        mutating func lookup(_ k: FrameKey) -> CVPixelBuffer? {
            guard var e = entries[k] else { return nil }
            tick += 1; e.used = tick; entries[k] = e
            return e.buffer.pb
        }
        mutating func store(_ k: FrameKey, _ b: Buf, bytes n: Int) {
            tick += 1
            if let old = entries.updateValue((b, n, tick), forKey: k) { bytes -= old.bytes }
            bytes += n
            while bytes > budget, entries.count > 1, let oldest = entries.min(by: { $0.value.used < $1.value.used }) {
                if oldest.key == k { break }
                bytes -= oldest.value.bytes; entries[oldest.key] = nil
            }
        }
    }

    private static let frames = Mutex(FrameCache(budget: cacheBudget))
    static func clearFrameCache() { frames.withLock { $0 = FrameCache(budget: cacheBudget) } }

    private static func frameBuffer(_ doc: Document, frame: Float, width: Int, height: Int) -> CVPixelBuffer? {
        let key = FrameKey(doc: doc.id, frame: frame.bitPattern, width: width, height: height)
        if let hit = frames.withLock({ $0.lookup(key) }) { return hit }
        guard let rgba = doc.render(frame: frame, width: width, height: height),
              let pb = linearBuffer(rgba, width: width, height: height) else { return nil }
        let box = Buf(pb: pb)
        frames.withLock { $0.store(key, box, bytes: width * height * 8) }
        return pb
    }

    // MARK: Pixels

    /// Straight display-encoded RGBA8 -> `kCVPixelFormatType_64RGBAHalf`, linear, premultiplied, IOSurface-backed.
    static func linearBuffer(_ rgba: [UInt8], width: Int, height: Int) -> CVPixelBuffer? {
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
                                      kCVPixelBufferMetalCompatibilityKey: true]
        var pb: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_64RGBAHalf, attrs as CFDictionary, &pb)
                == kCVReturnSuccess, let buffer = pb else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let lut = linearLUT
        rgba.withUnsafeBufferPointer { src in
            for y in 0..<height {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: Float16.self)
                var s = y * width * 4
                for x in 0..<width {
                    let a = src[s + 3]
                    if a == 0 {
                        row[x * 4] = 0; row[x * 4 + 1] = 0; row[x * 4 + 2] = 0; row[x * 4 + 3] = 0
                    } else {
                        let af = Float(a) / 255
                        row[x * 4] = Float16(lut[Int(src[s])] * af)
                        row[x * 4 + 1] = Float16(lut[Int(src[s + 1])] * af)
                        row[x * 4 + 2] = Float16(lut[Int(src[s + 2])] * af)
                        row[x * 4 + 3] = Float16(af)
                    }
                    s += 4
                }
            }
        }
        return buffer
    }
}
#endif
