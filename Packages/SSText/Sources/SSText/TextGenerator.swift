import Foundation
import CoreVideo
import SSCore

public enum TextGeneratorError: Error, Equatable, CustomStringConvertible {
    case wrongKind(String)
    /// Payload written by a newer app version.
    case unsupportedPayloadVersion(found: Int, supported: Int)
    case invalidPayload(String)

    public var description: String {
        switch self {
        case let .wrongKind(k): "Not a text generator: \(k)"
        case let .unsupportedPayloadVersion(f, s): "Text payload version \(f) is newer than the supported version \(s)."
        case let .invalidPayload(why): "Invalid text payload: \(why)"
        }
    }
}

/// One rendered text frame. `buffer` is linear half-float premultiplied RGBA (shared with the cache, read only).
/// Placement is the raster's top-left in sequence pixels (y down) for the untransformed, un-animated block
/// (block centered on the canvas); `width`/`height` are the raster size in sequence pixels (buffer size / scale).
/// The caller folds the animation factors into the compositor layer transform: scale and rotation (degrees)
/// about the block center, `offsetX/Y` in sequence pixels added to the position, `opacity` multiplies alpha.
public struct TextFrame: @unchecked Sendable {
    public let buffer: CVPixelBuffer
    public let x: Double, y: Double
    public let width: Double, height: Double
    public let opacity: Double
    public let scale: Double
    public let offsetX: Double, offsetY: Double
    public let rotation: Double
}

/// Bridge between a generator clip (`GeneratorRef` kind "text") and the text renderer.
public enum TextGenerator {
    public static let payloadVersion = 1

    private struct Payload: Codable {
        var template: TextTemplate
        var animations: AnimationSet?
    }

    public static func makeRef(template: TextTemplate, animations: AnimationSet?) throws -> GeneratorRef {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        let data = try e.encode(Payload(template: template, animations: animations))
        return GeneratorRef(kind: GeneratorRef.text, payload: data, payloadVersion: payloadVersion)
    }

    public static func decode(_ ref: GeneratorRef) throws -> (TextTemplate, AnimationSet?) {
        guard ref.kind == GeneratorRef.text else { throw TextGeneratorError.wrongKind(ref.kind) }
        guard ref.payloadVersion <= payloadVersion else {
            throw TextGeneratorError.unsupportedPayloadVersion(found: ref.payloadVersion, supported: payloadVersion)
        }
        guard ref.payloadVersion >= 1 else { throw TextGeneratorError.invalidPayload("version \(ref.payloadVersion)") }
        do {
            let p = try JSONDecoder().decode(Payload.self, from: ref.payload)
            return (p.template, p.animations)
        } catch { throw TextGeneratorError.invalidPayload(String(describing: error)) }
    }

    /// Nil for empty text. `localTime` is clip-local (0 = clip start). If the payload has no `AnimationSet`, the
    /// template's own single animation is used (by its anchor).
    public static func frame(ref: GeneratorRef, localTime: Time, clipDuration: Time, canvas: SequenceFormat,
                             scale: Double) throws -> TextFrame? {
        let (template, set) = try decode(ref)
        guard let raster = try cache.raster(text: template.text, style: template.style, scale: scale) else { return nil }

        let anims: AnimationSet? = set ?? template.animation.map {
            $0.anchor == .start ? AnimationSet(in: $0, out: nil) : AnimationSet(in: nil, out: $0)
        }
        func v(_ p: String, _ d: Double) -> Double {
            anims?.value(of: p, clipTime: localTime, clipDuration: clipDuration) ?? d
        }
        let s = raster.scale
        let b = raster.layout.bounds
        // Block (text bounds) centered on the canvas; the raster starts at the ink origin.
        let x = (Double(canvas.width) - b.width) / 2 + (raster.originX - b.x)
        let y = (Double(canvas.height) - b.height) / 2 + (raster.originY - b.y)
        return TextFrame(buffer: raster.linearBuffer, x: x, y: y,
                         width: Double(raster.pixelWidth) / s, height: Double(raster.pixelHeight) / s,
                         opacity: min(1, max(0, v("opacity", 1))), scale: v("scale", 1),
                         offsetX: v("positionX", 0), offsetY: v("positionY", 0), rotation: v("rotation", 0))
    }

    /// Byte cap of the raster cache (linear half-float, 8 bytes per pixel).
    public static let cacheByteLimit = 128 * 1024 * 1024
    private static let cache = RasterCache(limit: cacheByteLimit)

    /// Drops all cached rasters (memory pressure, tests).
    public static func clearCache() { cache.clear() }

    private final class RasterCache: @unchecked Sendable {
        struct Key: Hashable { let text: String; let style: TextStyle; let scale: Double }
        private let lock = NSLock()
        private var entries: [Key: (raster: TextRaster?, bytes: Int, tick: UInt64)] = [:]
        private var total = 0, tick: UInt64 = 0
        private let limit: Int
        init(limit: Int) { self.limit = limit }

        func clear() { lock.lock(); entries = [:]; total = 0; lock.unlock() }

        func raster(text: String, style: TextStyle, scale: Double) throws -> TextRaster? {
            let key = Key(text: text, style: style, scale: max(0.01, scale))
            lock.lock()
            if let e = entries[key] {
                tick += 1; entries[key]?.tick = tick
                lock.unlock(); return e.raster
            }
            lock.unlock()
            let r = try TextRenderer.render(text: text, style: style, maxWidth: nil, scale: scale)
            let bytes = r.map { $0.pixelWidth * $0.pixelHeight * 8 } ?? 0
            lock.lock(); defer { lock.unlock() }
            if let e = entries[key] { return e.raster }   // raced: keep the first
            tick += 1
            entries[key] = (r, bytes, tick); total += bytes
            while total > limit, entries.count > 1,
                  let oldest = entries.filter({ $0.key != key }).min(by: { $0.value.tick < $1.value.tick }) {
                total -= oldest.value.bytes; entries[oldest.key] = nil
            }
            return r
        }
    }
}
